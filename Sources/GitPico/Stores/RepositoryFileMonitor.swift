import CoreServices
import Foundation

private final class FileEventCallback: @unchecked Sendable {
    let changed: @Sendable () -> Void
    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
}

/// Watches both working files and real Git storage, including linked worktrees.
final class RepositoryFileMonitor {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.willsuo.GitPico.repository-events")
    init(paths: [String], changed: @escaping @Sendable () -> Void) {
        let callback = FileEventCallback(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: { info in
            guard let info else { return nil }
            _ = Unmanaged<FileEventCallback>.fromOpaque(info).retain()
            return UnsafeRawPointer(info)
        }, release: { info in
            if let info { Unmanaged<FileEventCallback>.fromOpaque(info).release() }
        }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileEventCallback>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    var isRunning: Bool { stream != nil }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
