#!/bin/bash
# Emits Info.plist for the app bundle. Args: name bundle-id version binary
set -euo pipefail
NAME="$1"; ID="$2"; VERSION="$3"; BIN="$4"

cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${ID}</string>
    <key>CFBundleExecutable</key><string>${BIN}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Plain Text</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
    <!-- Claim the extensions themselves too: .md files with no UTI mapping
         (and .mdx / .markdown) otherwise never reach us. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown Document</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>md</string>
                    <string>markdown</string>
                    <string>mdown</string>
                    <string>mkd</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
