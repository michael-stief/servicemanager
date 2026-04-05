import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBar = StatusBarController()
    private var directoryWatcher: DirectoryWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar.setup()

        // Ensure directories exist
        let fm = FileManager.default
        _ = ScriptEntry.logDirectory // triggers lazy creation

        let servicesDir = ScriptEntry.servicesDirectory
        if !fm.fileExists(atPath: servicesDir.path) {
            try? fm.createDirectory(at: servicesDir, withIntermediateDirectories: true)
        }

        // State change callback — rebuild the panel if it's open
        let rebuildCallback: @MainActor () -> Void = { [weak self] in
            self?.statusBar.rebuildIfVisible()
        }
        ServiceSupervisor.shared.onStateChange = rebuildCallback
        ScheduledTaskRunner.shared.onStateChange = rebuildCallback

        // Initial scan
        loadEntries()

        // Watch for changes
        directoryWatcher = DirectoryWatcher(path: servicesDir.path) { [weak self] in
            self?.rescanDirectory()
        }
        directoryWatcher?.start()

        // Signal handling
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        directoryWatcher?.stop()
        ScheduledTaskRunner.shared.shutdownAll()

        let supervisor = ServiceSupervisor.shared
        // Prevent restart loops during shutdown
        for (_, service) in supervisor.services {
            service.state = .stopped
            service.restartTimer?.cancel()
            service.stabilityTimer?.cancel()
        }

        // Escalating shutdown: SIGTERM → SIGQUIT → SIGKILL
        let signals: [(sig: Int32, wait: TimeInterval)] = [
            (SIGTERM, 2.0),
            (SIGQUIT, 2.0),
            (SIGKILL, 0),
        ]

        for (sig, wait) in signals {
            let alive = supervisor.services.values.filter { $0.process?.isRunning == true }
            if alive.isEmpty { break }

            for service in alive {
                if let proc = service.process, proc.isRunning {
                    let pid = proc.processIdentifier
                    kill(-pid, sig)
                    if sig == SIGTERM { proc.terminate() }
                }
            }

            if wait > 0 {
                let deadline = Date().addingTimeInterval(wait)
                while Date() < deadline {
                    let anyAlive = supervisor.services.values.contains { $0.process?.isRunning == true }
                    if !anyAlive { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            }
        }
    }

    private func loadEntries() {
        let entries = ScriptEntry.scan()
        for entry in entries {
            switch entry.type {
            case .service:
                ServiceSupervisor.shared.add(entry)
            case .scheduled(let unit):
                ScheduledTaskRunner.shared.add(entry, unit: unit)
            }
        }
    }

    private func rescanDirectory() {
        let entries = ScriptEntry.scan()
        let newFilenames = Set(entries.map(\.filename))
        let supervisor = ServiceSupervisor.shared
        let runner = ScheduledTaskRunner.shared

        // Remove entries no longer on disk
        let currentServiceNames = Set(supervisor.services.keys)
        let currentTaskNames = Set(runner.tasks.keys)

        for name in currentServiceNames where !newFilenames.contains(name) {
            supervisor.remove(name)
        }
        for name in currentTaskNames where !newFilenames.contains(name) {
            runner.remove(name)
        }

        // Add new entries
        let allKnown = currentServiceNames.union(currentTaskNames)
        for entry in entries where !allKnown.contains(entry.filename) {
            switch entry.type {
            case .service:
                supervisor.add(entry)
            case .scheduled(let unit):
                runner.add(entry, unit: unit)
            }
        }
    }

    private func installSignalHandlers() {
        // Ignore default handling so our DispatchSource gets the signal
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            // Keep a strong reference by storing in a static
            AppDelegate.signalSources.append(source)
        }
    }

    private static var signalSources: [DispatchSourceSignal] = []
}
