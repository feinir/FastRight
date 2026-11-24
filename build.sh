#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

output_dir="${FASTRIGHT_OUTPUT_DIR:-$PWD/dist}"
release="${FASTRIGHT_RELEASE:-0}"
sign_identity="${SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
    developer_ids="$(/usr/bin/security find-identity -v -p codesigning |
        awk '/"Developer ID Application: / { print $2 }')"
    if [[ "$developer_ids" == *$'\n'* ]]; then
        printf 'Multiple Developer ID Application certificates found. Set SIGN_IDENTITY for this build.\n' >&2
        exit 1
    fi
    sign_identity="${developer_ids:--}"
    if [[ "$sign_identity" == - ]]; then
        if [[ -d "$output_dir/FastRight.app" ]] && /usr/bin/codesign -dvv "$output_dir/FastRight.app" 2>&1 | grep '^Authority=' >/dev/null; then
            printf 'The Developer ID certificate is unavailable. The existing signed FastRight.app was preserved.\n' >&2
            exit 1
        fi
        printf 'No Developer ID certificate available. An ad hoc build may require reauthorizing Accessibility.\n' >&2
    fi
fi

sign_args=(--force --sign "$sign_identity" --options runtime --timestamp=none)
if [[ "$release" == 1 ]]; then
    if [[ "$sign_identity" == - ]]; then
        printf 'A Developer ID Application certificate is required for a release build.\n' >&2
        exit 1
    fi
    sign_args=(--force --sign "$sign_identity" --options runtime --timestamp)
fi

module_cache="$PWD/.build/swift-module-cache"
mkdir -p "$module_cache" "$output_dir"

stage="$(mktemp -d "$output_dir/.build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

bundle="$stage/FastRight.app"
extension="$bundle/Contents/PlugIns/FastRightFinder.appex"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$extension/Contents/MacOS" "$extension/Contents/Resources"
cp macos/App.plist "$bundle/Contents/Info.plist"
cp macos/Extension.plist "$extension/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
for localization in macos/Resources/*.lproj; do
    cp -R "$localization" "$bundle/Contents/Resources/"
    cp -R "$localization" "$extension/Contents/Resources/"
done

swift_target=arm64-apple-macos13.0
/usr/bin/xcrun swiftc -target "$swift_target" -O -module-name FastRight -module-cache-path "$module_cache" \
    macos/FastRight.swift macos/Settings.swift macos/Localization.swift macos/StoreSandbox.swift macos/CollectionSettings.swift macos/SettingsDrag.swift \
    macos/CreatedItemRename.swift macos/FinderAutomation.swift macos/FinderCutShortcut.swift macos/FastRightStatusItem.swift macos/StorePaste.swift \
    macos/FinderMenu.swift macos/FinderMenuIcons.swift macos/FileHash.swift \
    -o "$bundle/Contents/MacOS/fastright"

/usr/bin/xcrun swiftc -target "$swift_target" -O -module-name FastRightFinder -module-cache-path "$module_cache" \
    -Xlinker -e -Xlinker _NSExtensionMain macos/FinderExtension.swift macos/FinderMenu.swift macos/FinderMenuIcons.swift \
    macos/Settings.swift macos/Localization.swift macos/StoreSandbox.swift macos/FileHash.swift \
    -o "$extension/Contents/MacOS/FastRightFinder"

/usr/bin/xcrun swift -module-cache-path "$module_cache" macos/AppIcon.swift \
    "$bundle/Contents/Resources/FastRight.icns"

/usr/bin/xcrun swiftc -O -module-cache-path "$module_cache" \
    macos/BuildFinderMenuIcons.swift macos/FinderMenuIcons.swift macos/Settings.swift macos/Localization.swift \
    macos/StoreSandbox.swift -o "$stage/build-menu-icons"
"$stage/build-menu-icons" "$extension/Contents/Resources/FinderMenuIcons.archive"

/usr/bin/codesign "${sign_args[@]}" --entitlements macos/Finder.entitlements "$extension"
/usr/bin/codesign "${sign_args[@]}" --entitlements macos/App.entitlements "$bundle"
/usr/bin/codesign --verify --deep --strict --all-architectures "$bundle"

if [[ -d "$output_dir/FastRight.app" ]]; then
    mv "$output_dir/FastRight.app" "$stage/previous.app"
fi
if ! mv "$bundle" "$output_dir/FastRight.app"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$output_dir/FastRight.app"; fi
    exit 1
fi
printf 'Built %s\n' "$output_dir/FastRight.app"
