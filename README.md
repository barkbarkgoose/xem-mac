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

```sh
brew install --HEAD barkbarkgoose/tap/xem
```

`--HEAD` is required: `xem-mac` is a private repo, so the tagged source tarball
that the stable formula points at is not fetchable and its `sha256` is still a
placeholder. Installing therefore needs repo access and a working SSH key. Drop
the flag once the repo is public and the sha is filled in.

Homebrew compiles it locally, which means Gatekeeper is never involved — there is
no "unidentified developer" prompt to click through, because locally built code is
never quarantined.

To open `.md` files from Finder, link the app into `/Applications`:

```sh
ln -sfn "$(brew --prefix)/opt/xem/Xem.app" /Applications/Xem.app
```

Then right-click any `.md` → Get Info → Open With → Xem → Change All.

### From source

Requires Command Line Tools only. **Xcode is not needed**, and there is deliberately
no `.xcodeproj` — `xcodebuild` will not work here.

```sh
make install       # build, bundle, ad-hoc sign, copy to /Applications, register
make install-cli   # symlink the `xem` launcher into ~/.local/bin
make set-default   # optional: claim the .md association
```

## Usage

```sh
xem notes.md         # open a file
xem -                # read markdown from stdin
some-command | xem   # same
```

Reopening a file that is already open focuses its window instead of duplicating it.

## Layout

| Path | Purpose |
|------|---------|
| `Sources/xem/FileWatcher.swift` | Live reload. Re-arms across atomic saves. |
| `Sources/xem/MarkdownWebView.swift` | `WKWebView` host and the JS bridge. |
| `Sources/xem/DocumentWindowController.swift` | One window per document. |
| `Sources/xem/Snapshot.swift` | `--snapshot in.md out.png`, for verification. |
| `Resources/web/app.js` | markdown-it pipeline, mermaid, KaTeX, scroll restore. |
| `Resources/web/theme.css` | Palette and layout. |
| `scripts/make-plist.sh` | Generates `Info.plist`, including the UTI claims. |
| `Formula/xem.rb` | Homebrew formula, mirrored into the tap repo. |

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
WindowServer, so it is not usable from CI or a Homebrew sandbox.

## Releasing

1. Bump `VERSION` in the `Makefile` and tag: `git tag v0.1.1 && git push --tags`
2. Update `url` and `sha256` in `Formula/xem.rb`:
   ```sh
   curl -sL https://github.com/barkbarkgoose/xem-mac/archive/refs/tags/v0.1.1.tar.gz | shasum -a 256
   ```
3. Copy the formula into the `homebrew-tap` repo and push.

## Uninstall

```sh
brew uninstall xem           # if installed via brew
rm -f /Applications/Xem.app  # the symlink, if you made one
make uninstall               # if installed from source
```
