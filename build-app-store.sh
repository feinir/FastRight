#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-package}"
work="$(mktemp -d "${TMPDIR:-/tmp}/fastright-store.XXXXXX")"
trap 'rm -rf "$work"' EXIT

case "$mode" in
    preview)
        output="${FASTRIGHT_OUTPUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fastright-preview.XXXXXX")}"
        # The development-only bundle uses an independent identity and container.
        FASTRIGHT_RELEASE=0 FASTRIGHT_OUTPUT_DIR="$work/build" ./build.sh
        ;;
    package)
        output="${FASTRIGHT_OUTPUT_DIR:-$PWD/dist}"
        : "${FASTRIGHT_STORE_SIGN_IDENTITY:?Set the Apple Distribution or Mac App Distribution identity.}"
        : "${FASTRIGHT_STORE_INSTALLER_IDENTITY:?Set the Mac Installer Distribution identity.}"
        : "${FASTRIGHT_STORE_APP_PROFILE:?Set the Mac App Store provisioning profile for com.ynpe.fastright.}"
        : "${FASTRIGHT_STORE_FINDER_PROFILE:?Set the Mac App Store provisioning profile for com.ynpe.fastright.findersync.}"
        test -f "$FASTRIGHT_STORE_APP_PROFILE"
        test -f "$FASTRIGHT_STORE_FINDER_PROFILE"
        SIGN_IDENTITY=- FASTRIGHT_RELEASE=0 FASTRIGHT_OUTPUT_DIR="$work/build" ./build.sh
        ;;
    *) printf 'Usage: %s [package|preview]\n' "$0" >&2; exit 1 ;;
esac

app="$work/build/FastRight.app"
finder="$app/Contents/PlugIns/FastRightFinder.appex"
cp macos/AppStore.entitlements "$work/App.entitlements"
cp macos/FinderAppStore.entitlements "$work/Finder.entitlements"

if [[ "$mode" == preview ]]; then
    details="$(/usr/bin/codesign -dvv "$app" 2>&1)"
    identity="$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<< "$details")"
    team="$(sed -n 's/^TeamIdentifier=//p' <<< "$details")"
    if [[ -z "$identity" || ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        printf 'A Developer ID Application identity is required to test a team-owned App Group.\n' >&2
        exit 1
    fi
    group="$team.com.ynpe.fastright.sandbox-preview"
    /usr/bin/plutil -replace CFBundleIdentifier -string com.ynpe.fastright.sandbox-preview "$app/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string com.ynpe.fastright.sandbox-preview.findersync "$finder/Contents/Info.plist"
    for bundle in "$app" "$finder"; do
        /usr/bin/plutil -replace CFBundleDisplayName -string 'FastRight Sandbox Preview' "$bundle/Contents/Info.plist"
        /usr/bin/plutil -replace CFBundleName -string 'FastRight Sandbox Preview' "$bundle/Contents/Info.plist"
    done
    timestamp=--timestamp=none
else
    identity="$FASTRIGHT_STORE_SIGN_IDENTITY"
    group="${FASTRIGHT_STORE_APP_GROUP:-group.com.ynpe.fastright}"
    [[ "$group" =~ ^group\.[A-Za-z0-9.-]+$ ]]
    timestamp=--timestamp

    embed_profile() {
        local profile="$1" bundle="$2" entitlements="$3" decoded="$work/profile.plist"
        local bundle_id application_id team_id groups
        /usr/bin/security cms -D -i "$profile" -o "$decoded"
        bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist")"
        application_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded")"
        team_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$decoded")"
        groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$decoded")"
        if [[ "${application_id#*.}" != "$bundle_id" ]] ||
           ! sed 's/^[[:space:]]*//' <<< "$groups" | grep -Fxq "$group"; then
            printf 'The profile for %s must authorize the bundle ID and the %s App Group.\n' "$bundle_id" "$group" >&2
            exit 1
        fi
        /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $application_id" "$entitlements"
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_id" "$entitlements"
        cp "$profile" "$bundle/Contents/embedded.provisionprofile"
    }

    embed_profile "$FASTRIGHT_STORE_APP_PROFILE" "$app" "$work/App.entitlements"
    embed_profile "$FASTRIGHT_STORE_FINDER_PROFILE" "$finder" "$work/Finder.entitlements"
fi

for bundle in "$app" "$finder"; do
    /usr/bin/plutil -insert FastRightApplicationGroup -string "$group" "$bundle/Contents/Info.plist"
done
/usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.utilities "$app/Contents/Info.plist"
for entitlements in "$work/App.entitlements" "$work/Finder.entitlements"; do
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$entitlements"
done

/usr/bin/codesign --force --sign "$identity" --options runtime "$timestamp" --entitlements "$work/Finder.entitlements" "$finder"
/usr/bin/codesign --force --sign "$identity" --options runtime "$timestamp" --entitlements "$work/App.entitlements" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

mkdir -p "$output"
if [[ "$mode" == preview ]]; then
    preview="$output/FastRight Sandbox Preview.app"
    test ! -e "$preview"
    mv "$app" "$preview"
    printf 'Built %s\n' "$preview"
else
    version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
    package="$output/FastRight-$version-app-store.pkg"
    /usr/bin/productbuild --component "$app" /Applications --sign "$FASTRIGHT_STORE_INSTALLER_IDENTITY" "$package"
    /usr/sbin/pkgutil --check-signature "$package"
    printf 'Built %s\n' "$package"
fi
