import Foundation
import CoreServices

@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: @MainActor () -> Void
    private var knownFiles: Set<String> = []

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        // Snapshot current files
        knownFiles = currentFiles()

        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                watcher.handleChange()
            }
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1 second debounce
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Balance the passRetained from start()
            Unmanaged.passUnretained(self).release()
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func handleChange() {
        // Always trigger rescan — catches permission changes, content changes,
        // not just filename additions/removals
        onChange()
        knownFiles = currentFiles()
    }

    private func currentFiles() -> Set<String> {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(contents.map(\.lastPathComponent))
    }
}
