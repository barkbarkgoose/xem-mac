import AppKit

// A plain main.swift rather than @main: top-level code and @main cannot coexist
// in a SwiftPM executable target.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let args = CommandLine.arguments
// Headless modes must never register as a regular app, even briefly: other
// Xem processes tell the GUI instance apart by its activation policy.
let headless = args.contains("--snapshot") || args.contains("--term")
app.setActivationPolicy(headless ? .accessory : .regular)

// Hidden verification mode: render a document offscreen and write a PNG.
if let flag = args.firstIndex(of: "--snapshot") {
    guard args.count > flag + 2 else {
        FileHandle.standardError.write(Data("usage: xem --snapshot <in.md> <out.png>\n".utf8))
        exit(2)
    }
    let shot = Snapshotter(
        input: URL(fileURLWithPath: args[flag + 1]).standardizedFileURL,
        output: URL(fileURLWithPath: args[flag + 2]).standardizedFileURL
    )
    DispatchQueue.main.async { shot.run() }
    app.run()
}

// Terminal viewer: page through the rendered document inside the terminal
// (iTerm2 inline images). `xem --attach` in the CLI opens a tab running this.
if let flag = args.firstIndex(of: "--term") {
    guard args.count > flag + 1 else {
        FileHandle.standardError.write(Data("usage: xem --term <file.md>\n".utf8))
        exit(2)
    }
    // Opens routed here by LaunchServices must reach a real Xem window, not
    // become one inside this process.
    let termDelegate = TerminalAppDelegate()
    app.delegate = termDelegate
    let viewer = TerminalViewer(file: URL(fileURLWithPath: args[flag + 1]).standardizedFileURL)
    DispatchQueue.main.async { viewer.run() }
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
