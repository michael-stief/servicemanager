import Foundation

enum TaskStatus {
    case neverRun
    case success
    case failed(Int32)
    case running
}

@MainActor
final class ManagedTask {
    let entry: ScriptEntry
    let unit: ScheduleUnit
    var status: TaskStatus = .neverRun
    var nextRun: Date
    var timer: DispatchSourceTimer?
    var process: Process?
    var isRunning: Bool = false

    init(entry: ScriptEntry, unit: ScheduleUnit) {
        self.entry = entry
        self.unit = unit
        self.nextRun = ScriptEntry.nextFireDate(for: unit)
    }

    func schedule() {
        timer?.cancel()

        let delay = max(nextRun.timeIntervalSinceNow, 0.1)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            self?.fire()
        }
        t.resume()
        timer = t
    }

    func fire() {
        guard !isRunning else { return }
        execute()
    }

    func forceRun() {
        guard !isRunning else { return }
        execute()
    }

    private func execute() {
        isRunning = true
        status = .running
        ScheduledTaskRunner.shared.onStateChange?()

        let proc = Process()
        proc.executableURL = entry.url
        proc.currentDirectoryURL = entry.url.deletingLastPathComponent()

        // Log file
        let logPath = entry.logURL.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            isRunning = false
            status = .failed(-1)
            nextRun = ScriptEntry.nextFireDate(for: unit)
            schedule()
            ScheduledTaskRunner.shared.onStateChange?()
            return
        }
        let offsetBeforeTimestamp = handle.seekToEndOfFile()

        // Write a timestamp header (removed later if no output)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let headerData = "--- \(timestamp) ---\n".data(using: .utf8)!
        handle.write(headerData)
        let offsetAfterTimestamp = offsetBeforeTimestamp + UInt64(headerData.count)

        proc.standardOutput = handle
        proc.standardError = handle

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        proc.environment = env

        proc.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            DispatchQueue.main.async {
                // Perform FileHandle operations on main thread where we own the handle
                let finalOffset = handle.seekToEndOfFile()
                if finalOffset == offsetAfterTimestamp {
                    handle.truncateFile(atOffset: offsetBeforeTimestamp)
                }
                try? handle.close()

                guard let self else { return }
                self.process = nil
                self.isRunning = false
                self.status = code == 0 ? .success : .failed(code)
                // Schedule next run
                self.nextRun = ScriptEntry.nextFireDate(for: self.unit)
                self.schedule()
                ScheduledTaskRunner.shared.onStateChange?()
            }
        }

        do {
            try proc.run()
            let pid = proc.processIdentifier
            setpgid(pid, pid)
            self.process = proc
        } catch {
            isRunning = false
            status = .failed(-1)
            try? handle.close()
            // Schedule next run even on launch failure
            nextRun = ScriptEntry.nextFireDate(for: unit)
            schedule()
            ScheduledTaskRunner.shared.onStateChange?()
        }
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        if let proc = process, proc.isRunning {
            let pid = proc.processIdentifier
            kill(-pid, SIGTERM)
            proc.terminate()
        }
    }
}

@MainActor
final class ScheduledTaskRunner {
    static let shared = ScheduledTaskRunner()
    var tasks: [String: ManagedTask] = [:]
    var onStateChange: (@MainActor () -> Void)?

    func add(_ entry: ScriptEntry, unit: ScheduleUnit) {
        let task = ManagedTask(entry: entry, unit: unit)
        tasks[entry.filename] = task
        task.schedule()
    }

    func remove(_ filename: String) {
        if let task = tasks.removeValue(forKey: filename) {
            task.cancel()
        }
    }

    func forceRun(_ filename: String) {
        tasks[filename]?.forceRun()
    }

    func shutdownAll() {
        for (_, task) in tasks {
            task.cancel()
        }
    }
}
