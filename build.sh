#!/bin/sh
set -eu
cd "$(dirname "$0")"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/Siftmark.app"
export MACOSX_DEPLOYMENT_TARGET=14.0
identity=-
if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 1 ] || [ "$1" != "--release" ]; then
        echo "Usage: ./build.sh [--release]" >&2
        exit 2
    fi
    identity=${DEVELOPER_ID_APPLICATION:?Set this to your Developer ID Application identity}
    : "${NOTARY_PROFILE:?Set this to your notarytool keychain profile}"
fi
cargo build --locked --release
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp target/release/siftmark-scan "$app/Contents/MacOS/"
swiftc -target "$(uname -m)-apple-macos14.0" -parse-as-library -O Window.swift -o "$app/Contents/MacOS/Siftmark"
cp Info.plist "$app/Contents/"
cp art/Siftmark.icns LICENSE "$app/Contents/Resources/"
sign() {
    if [ "$identity" = "-" ]; then
        codesign --force --sign - "$@"
    else
        codesign --force --options runtime --timestamp --sign "$identity" "$@"
    fi
}
sign "$app/Contents/MacOS/siftmark-scan"
sign --entitlements Siftmark.entitlements "$app"
codesign --verify --deep --strict "$app"
if [ "$#" -eq 1 ]; then
    ditto -c -k --keepParent "$app" "$stage/submission.zip"
    xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl -a -vv -t execute "$app"
    archive="Siftmark-$(plutil -extract CFBundleShortVersionString raw Info.plist)-$(uname -m).zip"
else
    archive="Siftmark-local.zip"
fi
ditto -c -k --keepParent "$app" "$stage/$archive"
mv "$stage/$archive" "dist/$archive"
ditto "$app" "dist/Siftmark.app"
