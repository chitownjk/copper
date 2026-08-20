#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
rehearsal=0
if [[ "${1:-}" == "--rehearsal" ]]; then
    rehearsal=1
    shift
fi
output_dir="${1:-"$root/build/release"}"
archive="$output_dir/Copper.xcarchive"
stage="$(mktemp -d "${TMPDIR:-/tmp}/copper-release.XXXXXX")"
notary_profile="${NOTARYTOOL_PROFILE:-}"

# Sparkle 2 CLI (sign_update / generate_appcast / generate_keys).
# Private key file (Sparkle generate_keys -x format: base64 of the 32-byte seed):
#   ~/.config/copper/sparkle/ed25519-private
# Tools are downloaded to ~/.config/copper/sparkle/Sparkle-$SPARKLE_VERSION/bin
# if they are not already on PATH.
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.6}"
SPARKLE_KEY_DIR="${SPARKLE_KEY_DIR:-$HOME/.config/copper/sparkle}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-$SPARKLE_KEY_DIR/ed25519-private}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$SPARKLE_KEY_DIR/Sparkle-$SPARKLE_VERSION/bin}"

cleanup() {
    rm -rf "$stage"
}
trap cleanup EXIT

check_actionable_warnings() {
    local build_log="$1"
    local matches="$stage/actionable-warnings.txt"
    awk -v root="$root" '
        index($0, "warning:") &&
        (index($0, root "/App/") ||
         index($0, root "/CameraExtension/") ||
         index($0, root "/Packages/MeetingKit/Sources/")) {
            print
        }
    ' "$build_log" > "$matches"
    if [[ -s "$matches" ]]; then
        echo "Actionable project warnings found:" >&2
        while IFS= read -r warning; do
            echo "$warning" >&2
        done < "$matches"
        return 1
    fi
}

resolve_sparkle_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    if [[ -x "$SPARKLE_TOOLS_DIR/$name" ]]; then
        echo "$SPARKLE_TOOLS_DIR/$name"
        return 0
    fi
    return 1
}

ensure_sparkle_tools() {
    local missing=0
    local name
    for name in sign_update generate_appcast generate_keys; do
        if ! resolve_sparkle_tool "$name" >/dev/null; then
            missing=1
        fi
    done
    if [[ "$missing" == "0" ]]; then
        return 0
    fi
    echo "Sparkle $SPARKLE_VERSION CLI tools not on PATH; downloading to $SPARKLE_TOOLS_DIR"
    local tarball="$stage/Sparkle-${SPARKLE_VERSION}.tar.xz"
    local extract="$stage/sparkle-dist"
    mkdir -p "$extract" "$SPARKLE_TOOLS_DIR"
    curl -fsSL -o "$tarball" \
        "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    tar -xJf "$tarball" -C "$extract"
    local src
    src="$(find "$extract" -type f -name generate_appcast -path '*/bin/*' | head -n 1)"
    [[ -n "$src" ]] || { echo "Sparkle tarball did not contain bin/generate_appcast." >&2; exit 65; }
    cp "$(dirname "$src")/generate_keys" "$(dirname "$src")/sign_update" "$(dirname "$src")/generate_appcast" "$SPARKLE_TOOLS_DIR/"
    chmod 755 "$SPARKLE_TOOLS_DIR/generate_keys" "$SPARKLE_TOOLS_DIR/sign_update" "$SPARKLE_TOOLS_DIR/generate_appcast"
}

write_minimal_appcast() {
    local zip_path="$1"
    local dest="$2"
    local enclosure_url="$3"
    local version="$4"
    local build="$5"
    local sign_update_bin="$6"
    local attrs
    attrs="$("$sign_update_bin" --ed-key-file "$SPARKLE_PRIVATE_KEY" "$zip_path")"
    local signature length
    signature="$(printf '%s\n' "$attrs" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    length="$(printf '%s\n' "$attrs" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
    [[ -n "$signature" && -n "$length" ]] || {
        echo "sign_update did not return edSignature/length." >&2
        exit 65
    }
    local pub_date
    pub_date="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
    cat > "$dest" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Copper</title>
        <link>https://github.com/chitownjk/copper/releases</link>
        <description>Copper updates</description>
        <language>en</language>
        <item>
            <title>Copper $version</title>
            <pubDate>$pub_date</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$enclosure_url"
                sparkle:edSignature="$signature"
                length="$length"
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
EOF
}

# appcast.xml is a signed release artifact uploaded to GitHub Releases.
# It is not the git source of truth (enclosure signatures are one-off).
emit_sparkle_update() {
    local app="$1"
    local version="$2"
    local build="$3"
    local app_zip="$4"
    ensure_sparkle_tools
    local sign_update_bin generate_appcast_bin
    sign_update_bin="$(resolve_sparkle_tool sign_update)"
    generate_appcast_bin="$(resolve_sparkle_tool generate_appcast)"
    [[ -f "$SPARKLE_PRIVATE_KEY" ]] || {
        echo "Sparkle private key not found at $SPARKLE_PRIVATE_KEY" >&2
        echo "Expected filename: ed25519-private (Sparkle generate_keys -x / 32-byte seed, base64)." >&2
        exit 65
    }

    # Re-zip the stapled app so the Sparkle archive includes the notarization ticket.
    rm -f "$app_zip"
    ditto -c -k --keepParent "$app" "$app_zip"

    local enclosure_url="https://github.com/chitownjk/copper/releases/download/v${version}/Copper-${version}-${build}.zip"
    local appcast="$output_dir/appcast.xml"
    local sparkle_dir="$stage/sparkle-updates"
    mkdir -p "$sparkle_dir"
    cp "$app_zip" "$sparkle_dir/$(basename "$app_zip")"

    echo "Signing Sparkle update with $sign_update_bin --ed-key-file $SPARKLE_PRIVATE_KEY"
    "$sign_update_bin" --ed-key-file "$SPARKLE_PRIVATE_KEY" "$app_zip"

    if "$generate_appcast_bin" \
        --ed-key-file "$SPARKLE_PRIVATE_KEY" \
        --download-url-prefix "https://github.com/chitownjk/copper/releases/download/v${version}/" \
        --link "https://github.com/chitownjk/copper/releases/tag/v${version}" \
        --maximum-deltas 0 \
        -o "$appcast" \
        "$sparkle_dir"
    then
        echo "Wrote appcast with generate_appcast: $appcast"
    else
        echo "generate_appcast failed; writing a minimal signed appcast instead."
        write_minimal_appcast "$app_zip" "$appcast" "$enclosure_url" "$version" "$build" "$sign_update_bin"
    fi

    echo "Sparkle enclosure URL: $enclosure_url"
    echo "gh release upload extra files:"
    echo "  $dmg"
    echo "  $app_zip"
    echo "  $appcast"
}

if [[ "$rehearsal" != "1" && -n "$(git -C "$root" status --porcelain)" && "${ALLOW_DIRTY:-0}" != "1" ]]; then
    echo "Refusing to package a dirty working tree. Commit first or set ALLOW_DIRTY=1 for a local rehearsal." >&2
    exit 65
fi
if [[ "$rehearsal" != "1" && -z "$notary_profile" ]]; then
    echo "Set NOTARYTOOL_PROFILE to a Keychain profile created with 'xcrun notarytool store-credentials'." >&2
    exit 64
fi
for notice in LICENSE PRIVACY.md THIRD_PARTY_NOTICES.md; do
    [[ -f "$root/$notice" ]] || { echo "Required release notice is missing: $notice" >&2; exit 65; }
done

mkdir -p "$output_dir"
if [[ "$rehearsal" == "1" ]]; then
    derived_data="$output_dir/DerivedData"
    build_log="$stage/xcodebuild.log"
    rm -rf "$derived_data"
    xcodebuild clean build \
        -project "$root/MeetingCompanion.xcodeproj" \
        -scheme MeetingNotes \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$derived_data" \
        ARCHS=arm64 \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$build_log"
    check_actionable_warnings "$build_log"
    app="$derived_data/Build/Products/Release/Copper.app"
    "$root/Scripts/verify-release.sh" --rehearsal "$app"
else
    build_log="$stage/xcodebuild.log"
    rm -rf "$archive"
    xcodebuild clean archive \
        -project "$root/MeetingCompanion.xcodeproj" \
        -scheme MeetingNotes \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        ARCHS=arm64 \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_IDENTITY="Developer ID Application" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" 2>&1 | tee "$build_log"
    check_actionable_warnings "$build_log"
    app="$archive/Products/Applications/Copper.app"
    [[ -d "$app" ]] || { echo "Archive did not contain Copper.app." >&2; exit 65; }
    codesign --verify --deep --strict --verbose=2 "$app"
fi

[[ -d "$app" ]] || { echo "Build did not contain Copper.app." >&2; exit 65; }

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")"
suffix=""
if [[ "$rehearsal" == "1" ]]; then
    suffix="-rehearsal"
fi
dmg="$output_dir/Copper-${version}-${build}${suffix}.dmg"
app_zip="$output_dir/Copper-${version}-${build}.zip"

if [[ "$rehearsal" != "1" ]]; then
    rm -f "$app_zip"
    ditto -c -k --keepParent "$app" "$app_zip"
    xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
fi

cp -R "$app" "$stage/Copper.app"
ln -s /Applications "$stage/Applications"
cp "$root/LICENSE" "$root/PRIVACY.md" "$root/THIRD_PARTY_NOTICES.md" "$stage/"
rm -f "$dmg"
hdiutil create \
    -volname "Copper" \
    -srcfolder "$stage" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$dmg"

if [[ "$rehearsal" == "1" ]]; then
    "$root/Scripts/verify-release.sh" --rehearsal "$dmg"
    echo "Release rehearsal ready (not signed or notarized): $dmg"
    exit 0
fi

xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
"$root/Scripts/verify-release.sh" "$dmg"
emit_sparkle_update "$app" "$version" "$build" "$app_zip"
echo "Release artifact ready: $dmg"
