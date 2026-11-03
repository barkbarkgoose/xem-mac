# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Xem: a small native macOS markdown viewer (Swift + `WKWebView`) that live-reloads on save. Swift 6 toolchain, macOS 14+, built with SwiftPM in Swift 5 language mode (see `Package.swift`). There are no tests and no linter.

## Build constraints

- Command Line Tools only. **Do not add an `.xcodeproj` and do not use `xcodebuild`.** The `.app` bundle is assembled by hand in the `Makefile`.
- There is no `.app` from `swift build` alone; `make bundle` copies the binary and `Resources/web` into `build/Xem.app` and generates `Info.plist` via `scripts/make-plist.sh` (which also declares the UTI/`.md` claims).

## Commands

```sh
swift build -c release   # compile only
make bundle              # build + assemble build/Xem.app
make sign                # + ad-hoc codesign (LaunchServices wants a signature)
make install             # + copy to /Applications and lsregister
make install-cli         # symlink scripts/xem -> ~/.local/bin/xem
make set-default         # opt-in: claim the .md association
make clean
```

Verifying a change without opening a window (needs a WindowServer, so not CI):

```sh
make bundle
./build/Xem.app/Contents/MacOS/xem --snapshot some.md /tmp/out.png
XEM_SNAPSHOT_LIGHT=1 ./build/Xem.app/Contents/MacOS/xem --snapshot some.md /tmp/light.png
```

`--snapshot` renders through the real WebKit pipeline (Mermaid, KaTeX, layout included). It is handled in `main.swift` and implemented in `Snapshot.swift`.

## Architecture

- `Sources/xem/` is the native shell: `AppDelegate` (opening files, dedupes so reopening a file focuses its window), `DocumentWindowController` (one window per document), `MarkdownWebView` (`WKWebView` host and JS bridge), `FileWatcher` (live reload). `main.swift` is a plain top-level script, not `@main`, because the two can't coexist in a SwiftPM executable.
- `Resources/web/` is the renderer, loaded from the app bundle: `app.js` (markdown-it pipeline, Mermaid, KaTeX, highlight.js, scroll restore), `theme.css` (palette, follows system light/dark), and `vendor/` (all third-party JS/CSS/fonts, committed; the app must stay fully offline, nothing fetched at runtime; see `THIRD-PARTY.md`).
- Text zoom (View menu, ⌘+ / ⌘- / ⌘0) is text-only: `MarkdownWebView` stores the scale in `UserDefaults` and calls `window.xem.setTextScale`, which sets `--text-scale` on `<html>`. `theme.css` sizes everything in rem/em, so keep new CSS in those units or it won't zoom. The text column's cap is `--content-width` (View > Wider/Narrower Column, `ContentWidth` in `Settings.swift`), also in rem so it zooms with the text.
- Native <-> page bridge: the page posts `{type:'openLink', path, fragment}` to the `xem` script message handler (`MarkdownWebView`, via a weak `ScriptBridge`). `app.js` intercepts relative-link clicks itself because the page lives in the bundle, so a relative `href` would otherwise resolve against it. Markdown targets open as tabs; non-viewable files are only revealed in Finder, never launched.
- Find is implemented in `app.js` (`window.xem.find`), not with `WKWebView.find`/`NSTextFinder`: WKWebView on macOS has no find UI and only selects one match. Matches are `<mark class="xem-find">`; colors are `--find-bg`/`--find-active-bg`, overridable per appearance from the Settings window (`Settings.swift`). `FindBarViewController` is a titlebar accessory.
- Every markdown-it block carries `data-line="start:end"` (source lines). All-tabs search (`GlobalSearchWindowController`, Cmd-Shift-F) searches each document's source natively, then `window.xem.findAtSourceLine` maps a source line to the rendered match using those attributes.
- The outline sidebar is HTML inside the page (`#outline`, toggled by `body.outline-open`), not a native split view, so the web view stays the window's content view. It is app chrome: sized in px times `--ui-scale` (Settings > Interface text size, `UIFontSize`), deliberately not rem, so it does not follow the document's Cmd +/- zoom. Native panels read `UIFontSize` and re-apply on `UIFontSize.didChange`.
- Printing/PDF use `WKWebView.printOperation` with `@media print` in `theme.css` (always light; `hljs-dark.css` is `screen`-only). The print view needs an explicit frame or output is blank.
- Terminal viewer (`TerminalViewer.swift`, `xem --term file.md`): an offscreen `MarkdownWebView` sized to the terminal's text area in points (cell size and scale come from iTerm2's `OSC 1337;ReportCellSize`), scrolled with `window.scrollBy` and drawn with iTerm2's `OSC 1337;File=` inline-image protocol over all rows but the status line. Small scrolls move in whole rows: the terminal shifts what it already shows (scroll region + `CSI S`/`CSI T`, which carries iTerm2's image cells) and only the exposed rows are snapshotted and sent; full-view repaints (hundreds of KB each) per wheel tick made iTerm2 stutter. Jumps, reloads, resizes and clamped scrolls at either end repaint fully (`XEM_TERM_FULL_FRAMES=1` forces that; `XEM_TERM_TRACE=<path>` logs frame timing). It redraws when `app.js` posts `{type:'rendered'}` (from `afterRender`, so after Mermaid) and coalesces key repeat so only one snapshot is in flight. `scripts/xem --attach` opens an iTerm2 tab (AppleScript) running `--term`.
- `scripts/xem` is the CLI launcher: resolves `Xem.app` (`$XEM_APP`, then `/Applications`), writes stdin to a temp file if piped, and calls `open -a`.

## Gotchas (already solved; don't regress)

- **Atomic saves:** editors `rename()` a temp file over the target, leaving a plain `.write` watcher on a dead inode. `FileWatcher` watches `.delete`/`.rename`, re-opens and re-arms, and also watches the parent directory as a backstop.
- **Relative images:** the page is loaded from the bundle, so `app.js` rewrites image `src` against the document's directory, and the web view is granted file read access at `/`.
- **Titlebar:** the window must not use `.fullSizeContentView`; the `WKWebView` would cover the titlebar and swallow drag events.
- **Cmd-F belongs to Find:** Full Screen is Ctrl-Cmd-F. Two items sharing Cmd-F made Find appear to do nothing.
- **Cmd-Shift-\ is Xem's own tab switcher** (`TabSwitcherWindowController`), not AppKit's tab overview, which can't be filtered or driven with arrow keys. The key monitor in `AppDelegate` owns that key and Ctrl-Tab (which steps the switcher's selection while it is open).
- **Settings/search windows set `tabbingMode = .disallowed`;** otherwise document windows (`.preferred`) open as tabs of them.

## Releasing

Bump `VERSION` in the `Makefile`, tag `vX.Y.Z` and push tags. Installation is `make install` only; Homebrew distribution was dropped.
