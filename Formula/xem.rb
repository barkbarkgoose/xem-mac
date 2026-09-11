class Xem < Formula
  desc "Native macOS markdown viewer with live reload, Mermaid and math"
  homepage "https://github.com/barkbarkgoose/xem-mac"
  url "https://github.com/barkbarkgoose/xem-mac/archive/refs/tags/v0.1.0.tar.gz"
  # PLACEHOLDER -- the repo is private, so this tarball 404s for an
  # unauthenticated fetch. Regenerate once the repo is public:
  #   curl -sL <url above> | shasum -a 256
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  # SSH: the repo is private, so an HTTPS clone has no credential to offer.
  # Installing needs repo access and a working SSH key.
  head "ssh://git@github.com/barkbarkgoose/xem-mac.git", branch: "main", using: :git

  depends_on macos: :sonoma

  def install
    # --disable-sandbox: SwiftPM's own sandbox conflicts with Homebrew's.
    system "make", "bundle", "SWIFT_FLAGS=--disable-sandbox"

    # Ad-hoc signature. Locally built code is never quarantined, so this is
    # purely to give LaunchServices a stable bundle identity.
    system "codesign", "--force", "--sign", "-", "--timestamp=none",
           "build/Xem.app"

    prefix.install "build/Xem.app"
    bin.install "scripts/xem"
    doc.install "README.md", "THIRD-PARTY.md"
  end

  def caveats
    <<~EOS
      The `xem` command is ready to use.

      To open .md files from Finder, link the app into /Applications:
        ln -sfn #{opt_prefix}/Xem.app /Applications/Xem.app

      Then set it as the default handler:
        right-click any .md -> Get Info -> Open With -> Xem -> Change All
    EOS
  end

  # Deliberately headless: a --snapshot test would need a WindowServer, which
  # the test sandbox and CI runners do not have.
  test do
    assert_path_exists prefix/"Xem.app/Contents/MacOS/xem"

    bundle_id = shell_output(
      "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' " \
      "#{prefix}/Xem.app/Contents/Info.plist",
    ).strip
    assert_equal "com.barkbarkgoose.xem", bundle_id

    # Reaching the "no such file" check proves the launcher located the app
    # bundle next to itself in the Cellar.
    assert_match "no such file", shell_output("#{bin}/xem /nonexistent.md 2>&1", 1)
  end
end
