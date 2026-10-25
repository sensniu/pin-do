#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_derived="$task_root/build/DerivedData"

# Hostless logic tests use the same model/rule source files as the app.
/usr/bin/xcodebuild \
    -project "$task_root/PinDo.xcodeproj" \
    -scheme PinDoTests \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$task_derived" \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing

/usr/bin/xcrun xctest "$task_derived/Build/Products/Debug/PinDoTests.xctest"

