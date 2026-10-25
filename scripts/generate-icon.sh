#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_iconset="$task_root/build/AppIcon.iconset"
mkdir -p "$task_iconset" "$task_root/PinDo/Resources"
for task_size in 16 32 128 256 512; do
    /usr/bin/sips -z "$task_size" "$task_size" "$task_root/asset/pin-do.png" \
        --out "$task_iconset/icon_${task_size}x${task_size}.png" > /dev/null
    task_double=$((task_size * 2))
    /usr/bin/sips -z "$task_double" "$task_double" "$task_root/asset/pin-do.png" \
        --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" > /dev/null
done
/usr/bin/xcrun swift -module-cache-path "$task_root/build/DerivedData/ModuleCache.noindex" \
    "$task_root/scripts/PackIcon.swift" "$task_iconset" "$task_root/PinDo/Resources/AppIcon.icns"

