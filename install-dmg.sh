#!/bin/bash
set -euo pipefail

if [[ $# != 1 || ! -f "$1" ]]; then
    printf 'Usage: %s FastRight.dmg\n' "$0" >&2
    exit 1
fi

dmg="$1"
if [[ "$dmg" != /* ]]; then dmg="$PWD/$dmg"; fi
cd "$(dirname "$0")"
installed_app=/Applications/FastRight.app
project_app="$PWD/dist/FastRight.app"
extension_path=Contents/PlugIns/FastRightFinder.appex
app_id=com.ynpe.fastright
extension_id=com.ynpe.fastright.findersync
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

work="$(mktemp -d "${TMPDIR:-/tmp}/fastright-dmg.XXXXXX")"
mount_dir="$work/mounted"
install_stage=
mounted=0
replaced=0
committed=0

register_app() {
    "$lsregister" -f "$1"
    /usr/bin/pluginkit -a "$1/$extension_path"
}

cleanup() {
    if [[ "$replaced" == 1 && "$committed" == 0 ]]; then
        /usr/bin/pluginkit -r "$installed_app/$extension_path" 2>/dev/null || true
        "$lsregister" -u "$installed_app" 2>/dev/null || true
        if [[ -d "$installed_app" ]]; then mv "$installed_app" "$install_stage/failed.app" || return; fi
        if [[ -d "$install_stage/previous.app" ]]; then
            mv "$install_stage/previous.app" "$installed_app" || return
            register_app "$installed_app" || true
        fi
        if [[ -d "$project_app" ]]; then register_app "$project_app" || true; fi
        /usr/bin/pluginkit -e "$election" -i "$extension_id" || true
    fi
    if [[ -n "$install_stage" ]]; then rm -rf "$install_stage"; fi
    if [[ "$mounted" == 1 ]]; then /usr/bin/hdiutil detach "$mount_dir" >/dev/null || return; fi
    rm -rf "$work"
}
trap cleanup EXIT

/usr/bin/codesign --verify "$dmg"
/usr/bin/xcrun stapler validate "$dmg"
mkdir "$mount_dir"
/usr/bin/hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount_dir"
mounted=1
source_app="$mount_dir/FastRight.app"

bundle_id() { /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist"; }
test "$(bundle_id "$source_app")" = "$app_id"
test "$(bundle_id "$source_app/$extension_path")" = "$extension_id"
/usr/bin/codesign --verify --deep --strict --all-architectures "$source_app"
/usr/bin/xcrun stapler validate "$source_app"
for app in "$installed_app" "$project_app"; do
    if [[ -e "$app" ]]; then test "$(bundle_id "$app")" = "$app_id"; fi
done

registered="$(/usr/bin/pluginkit -m -A -D -v -i "$extension_id" || true)"
election=default
if printf '%s\n' "$registered" | grep '^+' >/dev/null; then election=use
elif printf '%s\n' "$registered" | grep '^-' >/dev/null; then election=ignore
fi

install_stage="$(mktemp -d /Applications/.fastright-install.XXXXXX)"
/usr/bin/ditto "$source_app" "$install_stage/FastRight.app"
restart=0
for pid in $(/usr/bin/pgrep -x -u "$(id -u)" fastright || true); do
    executable="$(/bin/ps -ww -p "$pid" -o comm= || true)"
    if [[ "$executable" == "$installed_app/Contents/MacOS/fastright" ||
          "$executable" == "$project_app/Contents/MacOS/fastright" ]]; then
        if kill -TERM "$pid" 2>/dev/null; then
            restart=1
            for ((attempt = 0; attempt < 50; attempt++)); do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                printf 'Could not close the running FastRight instance.\n' >&2
                exit 1
            fi
        fi
    fi
done

if [[ -d "$installed_app" ]]; then mv "$installed_app" "$install_stage/previous.app"; fi
replaced=1
mv "$install_stage/FastRight.app" "$installed_app"
/usr/bin/codesign --verify --deep --strict --all-architectures "$installed_app"
/usr/bin/xcrun stapler validate "$installed_app"

if [[ -d "$project_app" ]]; then
    /usr/bin/pluginkit -r "$project_app/$extension_path" 2>/dev/null || true
    "$lsregister" -u "$project_app" 2>/dev/null || true
fi
register_app "$installed_app"
/usr/bin/pluginkit -e "$election" -i "$extension_id"
/usr/bin/pluginkit -m -A -D -v -i "$extension_id" | grep -F "$installed_app/$extension_path"
committed=1

if [[ -d "$project_app" ]]; then rm -rf "$project_app"; fi
if [[ "$restart" == 1 ]]; then /usr/bin/open "$installed_app"; fi
printf 'Installed %s from %s\n' "$installed_app" "$dmg"
