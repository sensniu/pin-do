#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"

zsh "$task_root/scripts/test.sh"
zsh "$task_root/scripts/build-app.sh" Release
task_app="$task_root/build/DerivedData/Build/Products/Release/PinDo.app"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")
task_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")
if [[ "$task_identifier" != local.pindo.app ]]; then
    print -u2 'Refusing to package a development or prototype app.'
    exit 1
fi
/usr/bin/codesign --force --sign - --timestamp=none "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"

mkdir -p "$task_root/build/releases" "$task_root/build/Packaging"
task_staging=$(mktemp -d "$task_root/build/Packaging/PinDo.XXXXXX")
task_raw="$task_staging.iso"
function task_cleanup() {
    # Exact mktemp directory only; find does not follow the Applications symlink.
    /usr/bin/find "$task_staging" -depth -delete
    if [[ -f "$task_raw" ]]; then /usr/bin/find "$task_raw" -delete; fi
}
trap task_cleanup EXIT
/usr/bin/ditto "$task_app" "$task_staging/PinDo.app"
/bin/ln -s /Applications "$task_staging/Applications"
/bin/cp "$task_root/INSTALL.md" "$task_staging/安装与数据说明.md"
task_output="$task_root/build/releases/PinDo-${task_version}-arm64.dmg"
if ! /usr/bin/hdiutil create -volname "PinDo v${task_version}" -srcfolder "$task_staging" \
    -format UDZO -ov "$task_output"; then
    # UDF creation avoids temporary device mounts and HFS catalog FinderInfo on signed bundles.
    # macOS cannot resolve this absolute symlink on UDF; use Finder's Applications folder instead.
    /usr/bin/find "$task_staging/Applications" -type l -delete
    /usr/bin/hdiutil makehybrid -udf -udf-volume-name "PinDo v${task_version}" \
        -o "$task_raw" "$task_staging" -ov
    /usr/bin/hdiutil convert "$task_raw" -format UDZO -o "$task_output" -ov
fi
/usr/bin/hdiutil verify "$task_output"
print "Installer: $task_output"

