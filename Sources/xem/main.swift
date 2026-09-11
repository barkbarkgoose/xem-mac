import AppKit

// A plain main.swift rather than @main: top-level code and @main cannot coexist
// in a SwiftPM executable target.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// Hidden verification mode: render a document offscreen and write a PNG.
let args = CommandLine.arguments
if let flag = args.firstIndex(of: "--snapshot") {
    guard args.count > flag + 2 else {
        FileHandle.standardError.write(Data("usage: xem --snapshot <in.md> <out.png>\n".utf8))
        exit(2)
    }
    app.setActivationPolicy(.accessory)
    let shot = Snapshotter(
        input: URL(fileURLWithPath: args[flag + 1]).standardizedFileURL,
        output: URL(fileURLWithPath: args[flag + 2]).standardizedFileURL
    )
    DispatchQueue.main.async { shot.run() }
    app.run()
}

// Paths passed straight on argv (the CLI shim uses `open`, but this keeps
// `Xem.app/Contents/MacOS/xem file.md` working for debugging).
let fileArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
if !fileArgs.isEmpty {
    DispatchQueue.main.async {
        for path in fileArgs {
            delegate.openDocument(URL(fileURLWithPath: path).standardizedFileURL)
        }
    }
}

app.run()
