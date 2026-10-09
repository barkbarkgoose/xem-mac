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
- Text zoom (View menu, ⌘+ / ⌘- / ⌘0) is text-only: `MarkdownWebView` stores the scale in `UserDefaults` and calls `window.xem.setTextScale`, which sets `--text-scale` on `<html>`. `theme.css` sizes everything in rem/em, so keep new CSS in those units or it won't zoom.
- `scripts/xem` is the CLI launcher: resolves `Xem.app` (`$XEM_APP`, next to the script/Cellar, then `/Applications`), writes stdin to a temp file if piped, and calls `open -a`.
- `Formula/xem.rb` is the Homebrew formula; it is mirrored by hand into a separate `homebrew-tap` repo. The repo is private, so the formula's `head` uses SSH and `brew install --HEAD` is required until the repo is public and the stable `sha256` is filled in. `making-brew-work.md` (untracked) is a scratch troubleshooting log.

## Gotchas (already solved; don't regress)

- **Atomic saves:** editors `rename()` a temp file over the target, leaving a plain `.write` watcher on a dead inode. `FileWatcher` watches `.delete`/`.rename`, re-opens and re-arms, and also watches the parent directory as a backstop.
- **Relative images:** the page is loaded from the bundle, so `app.js` rewrites image `src` against the document's directory, and the web view is granted file read access at `/`.
- **Titlebar:** the window must not use `.fullSizeContentView`; the `WKWebView` would cover the titlebar and swallow drag events.

## Releasing

Bump `VERSION` in the `Makefile`, tag `vX.Y.Z` and push tags, update `url` and `sha256` in `Formula/xem.rb`, then copy the formula into the tap repo.
