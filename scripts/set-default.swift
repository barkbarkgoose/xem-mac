// Makes Geenyan the default handler for markdown files. Run via `make set-default`.
import AppKit
import UniformTypeIdentifiers

let app = URL(fileURLWithPath: "/Applications/Geenyan.app")
guard FileManager.default.fileExists(atPath: app.path) else {
    print("Geenyan.app is not installed in /Applications -- run 'make install' first.")
    exit(1)
}
guard let markdown = UTType("net.daringfireball.markdown") else {
    print("markdown UTI unavailable")
    exit(1)
}

let done = DispatchSemaphore(value: 0)
var failure: Error?
NSWorkspace.shared.setDefaultApplication(at: app, toOpen: markdown) { error in
    failure = error
    done.signal()
}
done.wait()

if let failure {
    print("failed: \(failure.localizedDescription)")
    exit(1)
}
print("Geenyan is now the default application for markdown files.")
