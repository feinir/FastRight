#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

profile="${FASTRIGHT_NOTARY_PROFILE:-FastRemote-notary}"
work="$(mktemp -d "${TMPDIR:-/tmp}/fastright-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

notarize() {
    local artifact="$1" receipt="$2" submission result
    /usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$profile" --output-format json > "$receipt"
    submission="$(/usr/bin/plutil -extract id raw -o - "$receipt")"
    printf 'Waiting for Apple notarization of %s (%s).\n' "${artifact##*/}" "$submission"
    /usr/bin/xcrun notarytool wait "$submission" --keychain-profile "$profile" --output-format json > "$receipt"
    result="$(/usr/bin/plutil -extract status raw -o - "$receipt")"
    if [[ "$result" != Accepted ]]; then
        /usr/bin/xcrun notarytool log "$submission" --keychain-profile "$profile"
        return 1
    fi
}

FASTRIGHT_RELEASE=1 FASTRIGHT_OUTPUT_DIR="$work/build" ./build.sh
app="$work/build/FastRight.app"
test "$(/usr/bin/xcrun lipo -archs "$app/Contents/MacOS/fastright")" = arm64
test "$(/usr/bin/xcrun lipo -archs "$app/Contents/PlugIns/FastRightFinder.appex/Contents/MacOS/FastRightFinder")" = arm64
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
developer_id="$(/usr/bin/codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"
test -n "$developer_id"

/usr/bin/ditto -c -k --keepParent "$app" "$work/FastRight.zip"
notarize "$work/FastRight.zip" "$work/app-notary.json"
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"

mkdir "$work/image"
/usr/bin/ditto "$app" "$work/image/FastRight.app"
ln -s /Applications "$work/image/Applications"
name="FastRight-$version-arm64.dmg"
dmg="$work/$name"
/usr/bin/hdiutil create -volname FastRight -srcfolder "$work/image" -fs HFS+ -format UDZO "$dmg"
/usr/bin/codesign --sign "$developer_id" --timestamp --identifier com.ynpe.fastright.dmg "$dmg"
notarize "$dmg" "$work/dmg-notary.json"
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"
/usr/bin/hdiutil verify "$dmg"

mkdir -p dist
mv "$dmg" "dist/$name"
./install-dmg.sh "dist/$name"
for previous in dist/FastRight-*-{universal,arm64}.dmg; do
    if [[ "$previous" != "dist/$name" ]]; then rm -f "$previous"; fi
done
printf 'Packaged %s\n' "$PWD/dist/$name"
