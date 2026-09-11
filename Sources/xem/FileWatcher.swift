import Foundation

/// Watches a single file for content changes.
///
/// Most editors (nvim included) save atomically: they write a temp file and
/// rename() it over the target. That unlinks the inode our descriptor points at,
/// so a source watching only `.write` goes permanently deaf after the first save.
/// We therefore also watch `.delete`/`.rename` and re-arm on a fresh descriptor.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "xem.filewatcher")

    private var source: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounceWork: DispatchWorkItem?
    private var stopped = false
    private var lastStamp: (Date, UInt64)?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in
            self?.arm(retriesLeft: 0)
            self?.armDirectory()
        }
    }

    deinit { stop() }

    func stop() {
        queue.sync {
            stopped = true
            debounceWork?.cancel()
            teardown()
            dirSource?.cancel()
            dirSource = nil
        }
    }

    // MARK: - private (all on `queue`)

    private func teardown() {
        source?.cancel()
        source = nil
        // The cancel handler owns closing the descriptor.
        descriptor = -1
    }

    private func arm(retriesLeft: Int) {
        guard !stopped else { return }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-rename the path can briefly not exist. Retry a few times.
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.arm(retriesLeft: retriesLeft - 1)
                }
            }
            return
        }

        descriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            let flags = current.data

            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // Atomic save (or a real deletion). Rebuild on a fresh descriptor.
                self.teardown()
                self.arm(retriesLeft: 20)
            }
            self.scheduleNotify()
        }

        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    /// Fallback for editors that recreate the file after a gap longer than our
    /// re-arm retry window. Watching the containing directory always survives,
    /// because the directory's inode is never replaced.
    private func armDirectory() {
        guard !stopped else { return }
        let dir = url.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if self.source == nil { self.arm(retriesLeft: 5) }
            self.scheduleNotify()
        }
        src.setCancelHandler { close(fd) }
        dirSource = src
        src.resume()
    }

    /// (modification date, size) -- enough to tell a real edit from a sibling's.
    private func stamp() -> (Date, UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? UInt64
        else { return nil }
        return (date, size)
    }

    private func scheduleNotify() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            // Only report once the path is readable again, and only if the file
            // actually changed -- the directory watcher fires for siblings too.
            guard let stamp = self.stamp() else { return }
            if let last = self.lastStamp, last == stamp { return }
            self.lastStamp = stamp
            DispatchQueue.main.async { self.onChange() }
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.06, execute: work)
    }
}
