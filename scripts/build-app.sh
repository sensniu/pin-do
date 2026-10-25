#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_configuration="${1:-Debug}"
if [[ "$task_configuration" != Debug && "$task_configuration" != Release ]]; then
    print -u2 "Usage: scripts/build-app.sh [Debug|Release]"
    exit 2
fi

if [[ ! -f "$task_root/PinDo/Resources/AppIcon.icns" || "$task_root/asset/pin-do.png" -nt "$task_root/PinDo/Resources/AppIcon.icns" ]]; then
    zsh "$task_root/scripts/generate-icon.sh"
fi

# A single project-owned directory contains all derived build products.
/usr/bin/xcodebuild \
    -project "$task_root/PinDo.xcodeproj" \
    -scheme PinDo \
    -configuration "$task_configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$task_root/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build

print "App: $task_root/build/DerivedData/Build/Products/$task_configuration/PinDo.app"

