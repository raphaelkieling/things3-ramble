#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

configuration=release
app="dist/Things 3 Ramble.app"
if [[ "${1:-}" == "--demo" ]]; then
    configuration=debug
    app="dist/Things 3 Ramble Demo.app"
    shift
fi

swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p dist
scratch="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/$(basename "$app")"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/Info.plist"
cp "$binary_dir/Ramble" "$bundle/Contents/MacOS/Ramble"

if [[ "$configuration" == debug ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.raphaelkieling.things3ramble.demo' \
        -c 'Set :CFBundleName Things 3 Ramble Demo' \
        -c 'Set :CFBundleDisplayName Things 3 Ramble Demo' -c 'Delete :CFBundleURLTypes' "$bundle/Contents/Info.plist"
fi

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
if [[ -d "$app" ]]; then mv "$app" "$scratch/previous.app"; fi
mv "$bundle" "$app"
printf '%s\n' "$PWD/$app"

if [[ "$configuration" == debug ]]; then
    fixture=--fixture-capture
    if [[ "${1:-}" == "--settings" ]]; then
        fixture=--fixture-settings
        shift
    fi
    open -n "$app" --args "$fixture" "$@"
fi
