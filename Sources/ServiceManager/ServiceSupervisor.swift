import Foundation

enum ServiceState {
    case stopped
    case running
    case restarting
}

@MainActor
final class ManagedService {
    let entry: ScriptEntry
    var state: ServiceState = .stopped
    var process: Process?
    var startedAt: Date?
    var restartCount: Int = 0
    var restartTimer: DispatchSourceTimer?
    var stabilityTimer: DispatchSourceTimer?
    private var logHandle: FileHandle?

    init(entry: ScriptEntry) {
        self.entry = entry
    }

    func start() {
        guard state != .running else { return }
        state = .running

        let proc = Process()
        proc.executableURL = entry.url
        proc.currentDirectoryURL = entry.url.deletingLastPathComponent()

        // Ensure log file exists and open for append
        let logPath = entry.logURL.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            state = .restarting
            scheduleRestart()
            ServiceSupervisor.shared.onStateChange?()
            return
        }
        handle.seekToEndOfFile()
        self.logHandle = handle

        proc.standardOutput = handle
        proc.standardError = handle

        // Inherit a minimal environment
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        proc.environment = env

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.handleTermination(exitCode: process.terminationStatus)
            }
        }

        do {
            try proc.run()
            // Make the child its own process group leader so we can kill its entire tree
            let pid = proc.processIdentifier
            setpgid(pid, pid)
            self.process = proc
            self.startedAt = Date()
            scheduleStabilityReset()
            ServiceSupervisor.shared.onStateChange?()
        } catch {
            state = .restarting
            closeLog()
            scheduleRestart()
            ServiceSupervisor.shared.onStateChange?()
        }
    }

    func stop() {
        state = .stopped
        restartTimer?.cancel()
        restartTimer = nil
        stabilityTimer?.cancel()
        stabilityTimer = nil
        restartCount = 0

        if let proc = process, proc.isRunning {
            let pid = proc.processIdentifier
            // SIGTERM the process group first
            kill(-pid, SIGTERM)
            proc.terminate()
            let p = proc
            // Escalate: SIGQUIT after 3s, SIGKILL after 6s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(-pid, SIGQUIT) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if p.isRunning {
                    kill(-pid, SIGKILL)
                    kill(pid, SIGKILL)
                }
            }
        } else {
            // Only close log immediately if process isn't running;
            // otherwise handleTermination will close it after exit
            closeLog()
        }
        ServiceSupervisor.shared.onStateChange?()
    }

    private func handleTermination(exitCode: Int32) {
        closeLog()
        process = nil
        startedAt = nil
        guard state != .stopped else { return }
        state = .restarting
        scheduleRestart()
        ServiceSupervisor.shared.onStateChange?()
    }

    private func scheduleRestart() {
        let delay = min(Double(1 << restartCount), 30.0) // 1, 2, 4, 8, 16, 30
        restartCount += 1

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.start()
        }
        timer.resume()
        restartTimer = timer
    }

    private func scheduleStabilityReset() {
        stabilityTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler { [weak self] in
            self?.restartCount = 0
        }
        timer.resume()
        stabilityTimer = timer
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }
}

@MainActor
final class ServiceSupervisor {
    static let shared = ServiceSupervisor()
    var services: [String: ManagedService] = [:]
    var onStateChange: (@MainActor () -> Void)?

    func add(_ entry: ScriptEntry) {
        let service = ManagedService(entry: entry)
        services[entry.filename] = service
        service.start()
    }

    func remove(_ filename: String) {
        if let service = services.removeValue(forKey: filename) {
            service.stop()
        }
    }

    func toggle(_ filename: String) {
        guard let service = services[filename] else { return }
        if service.state == .running {
            service.stop()
        } else {
            service.start()
        }
    }

    func shutdownAll() {
        for (_, service) in services {
            service.stop()
        }
    }
}
