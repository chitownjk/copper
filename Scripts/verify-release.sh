#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--rehearsal] /path/to/Copper.dmg|/path/to/Copper.app" >&2
    exit 64
}

rehearsal=0
if [[ "${1:-}" == "--rehearsal" ]]; then
    rehearsal=1
    shift
fi
[[ $# -eq 1 ]] || usage
artifact="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -e "$artifact" ]] || { echo "Artifact not found: $artifact" >&2; exit 66; }

mount_point=""
cleanup() {
    if [[ -n "$mount_point" ]]; then
        hdiutil detach "$mount_point" -quiet || true
        rmdir "$mount_point" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ "$artifact" == *.dmg ]]; then
    if [[ "$rehearsal" == "1" ]]; then
        hdiutil verify "$artifact"
        echo "Verified rehearsal disk image structure: $artifact"
        exit 0
    fi
    xcrun stapler validate "$artifact"
    mount_point="$(mktemp -d "${TMPDIR:-/tmp}/copper-verify.XXXXXX")"
    hdiutil attach "$artifact" -nobrowse -readonly -mountpoint "$mount_point" -quiet
    apps=("$mount_point"/*.app)
    app="${apps[0]:-}"
    for notice in LICENSE PRIVACY.md THIRD_PARTY_NOTICES.md; do
        [[ -f "$mount_point/$notice" ]] || {
            echo "Disk image is missing $notice." >&2
            exit 65
        }
    done
else
    app="$artifact"
fi

[[ -d "${app:-}" ]] || { echo "No app bundle found in $artifact" >&2; exit 65; }
extension="$app/Contents/Library/SystemExtensions/com.strongrise.meetingcompanion.cameraextension.systemextension"
[[ -d "$extension" ]] || { echo "Embedded camera extension is missing." >&2; exit 65; }

if [[ "$rehearsal" != "1" ]]; then
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign --verify --strict --verbose=2 "$extension"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

app_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")"
app_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")"
extension_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$extension/Contents/Info.plist")"
executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")"
executable="$app/Contents/MacOS/$executable_name"
[[ -x "$executable" ]] || { echo "App executable is missing: $executable" >&2; exit 65; }
architectures="$(lipo -archs "$executable")"

[[ "$app_id" == "com.strongrise.meetingcompanion" ]] || {
    echo "Unexpected app bundle identifier: $app_id" >&2
    exit 65
}
[[ "$extension_id" == "com.strongrise.meetingcompanion.cameraextension" ]] || {
    echo "Unexpected extension bundle identifier: $extension_id" >&2
    exit 65
}
[[ -n "$app_version" && -n "$app_build" ]] || {
    echo "App version or build number is empty." >&2
    exit 65
}
[[ "$architectures" == "arm64" ]] || {
    echo "Expected Apple Silicon-only app; found: $architectures" >&2
    exit 65
}

if [[ "$rehearsal" != "1" ]]; then
    entitlements="$(mktemp "${TMPDIR:-/tmp}/copper-entitlements.XXXXXX")"
    codesign -d --entitlements :- "$app" > "$entitlements"
    trap 'rm -f "$entitlements"; cleanup' EXIT
    install_entitlement="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.system-extension.install" "$entitlements")"
    [[ "$install_entitlement" == "true" ]] || {
        echo "System-extension install entitlement is missing." >&2
        exit 65
    }
fi

if [[ "$rehearsal" == "1" ]]; then
    echo "Verified Copper $app_version ($app_build) rehearsal: architecture, bundle IDs, and camera extension."
else
    echo "Verified Copper $app_version ($app_build): signature, Gatekeeper, architecture, entitlements, and camera extension."
fi
