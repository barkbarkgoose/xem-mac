# Xem

A small native macOS markdown viewer. Open a `.md` file, keep editing it in your
editor, and the window re-renders on every save.

*Xem* is Vietnamese for "to look at" — which is all this does.

- Native Swift + `WKWebView`, ~3.7 MB installed, launches instantly
- GitHub-flavored markdown, syntax highlighting, tables, task lists
- Mermaid diagrams and KaTeX math
- Live reload that survives atomic saves (`:w` in nvim), preserving scroll position
- Follows the system light/dark appearance; palette matches `ayu-jake`
- Fully offline — every asset is vendored, nothing is fetched at runtime

## Install

Requires Command Line Tools only. **Xcode is not needed**, and there is deliberately
no `.xcodeproj` — `xcodebuild` will not work here.

```sh
make install       # build, bundle, ad-hoc sign, copy to /Applications, register
make install-cli   # symlink the `xem` launcher into ~/.local/bin
make set-default   # optional: claim the .md association
```

Re-run `make install` after pulling changes. Because the app is built locally, it is
never quarantined, so Gatekeeper doesn't prompt about an unidentified developer.

## Usage

```sh
xem notes.md         # open a file
xem -                # read markdown from stdin
some-command | xem   # same
xem --attach notes.md   # view in a new iTerm2 tab (e.g. `:!xem --attach %` from nvim)
xem --term notes.md     # view in the current terminal
```

Reopening a file that is already open focuses its window instead of duplicating it.

`--attach` and `--term` render through the same WebKit pipeline offscreen and show it
with iTerm2's inline images, one screenful at a time, still live-reloading on save.
Keys: `j`/`k`/arrows/wheel scroll, `space`/`b` page, `d`/`u` half page, `g`/`G` top/end,
`r` repaint, `o` open in a Xem window, `q` quit. It's a picture, so there's no text
selection, links or find.

## Layout

| Path | Purpose |
|------|---------|
| `Sources/xem/FileWatcher.swift` | Live reload. Re-arms across atomic saves. |
| `Sources/xem/MarkdownWebView.swift` | `WKWebView` host and the JS bridge. |
| `Sources/xem/DocumentWindowController.swift` | One window per document. |
| `Sources/xem/Snapshot.swift` | `--snapshot in.md out.png`, for verification. |
| `Sources/xem/TerminalViewer.swift` | `--term`: page through the render in iTerm2. |
| `Resources/web/app.js` | markdown-it pipeline, mermaid, KaTeX, scroll restore. |
| `Resources/web/theme.css` | Palette and layout. |
| `scripts/make-plist.sh` | Generates `Info.plist`, including the UTI claims. |

## Notes on three things that are easy to get wrong

**Atomic saves.** nvim and most editors save by writing a temp file and `rename()`ing
it over the target. A `DispatchSource` watching only `.write` on the original
descriptor goes permanently deaf after the first save, because that descriptor now
points at an unlinked inode — live reload appears to work once and then silently
stops. `FileWatcher` also watches `.delete`/`.rename`, re-opens the path and re-arms,
and keeps a watch on the parent directory as a backstop.

**Relative image paths.** The page is loaded from the app bundle, so a document's
`./img/foo.png` would resolve against the bundle's web root. `app.js` rewrites image
sources against the document's own directory, and the web view is granted file read
access at `/` so those paths are actually loadable.

**The titlebar.** The window deliberately does *not* use `.fullSizeContentView`. With
it, the `WKWebView` covers the titlebar strip and swallows the mouse events that drag
the window, leaving no way to move it.

## Verifying a change

```sh
make bundle
./build/Xem.app/Contents/MacOS/xem --snapshot some.md /tmp/out.png
XEM_SNAPSHOT_LIGHT=1 ./build/Xem.app/Contents/MacOS/xem --snapshot some.md /tmp/light.png
```

`--snapshot` renders offscreen through the real WebKit pipeline and writes a PNG, so
Mermaid, KaTeX and layout can be checked without opening a window. It needs a
WindowServer, so it is not usable from CI.

## Releasing

Bump `VERSION` in the `Makefile` and tag: `git tag v0.1.1 && git push --tags`

## Uninstall

```sh
make uninstall   # removes /Applications/Xem.app and the ~/.local/bin/xem link
```
