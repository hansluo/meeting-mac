#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Standard configured Xcode installations use SwiftPM's normal test runner.
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" != *CommandLineTools* ]]; then
  exec swift test "$@"
fi

# CLT has Swift but no XCTest; use an installed Xcode's test framework directly.
# This does not select Xcode globally or change its license state.
xcode_dev="${MEETING_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
framework_dir="$xcode_dev/Platforms/MacOSX.platform/Developer/Library/Frameworks"
library_dir="$xcode_dev/Platforms/MacOSX.platform/Developer/usr/lib"
if [[ ! -d "$framework_dir/XCTest.framework" || ! -x "$xcode_dev/usr/bin/xctest" ]]; then
  echo 'XCTest requires Xcode. Set MEETING_XCODE_DEVELOPER_DIR to its Contents/Developer directory.' >&2
  exit 1
fi
if [[ $# -gt 0 ]]; then
  echo 'The CLT fallback runs the full suite; test filters require a configured Xcode toolchain.' >&2
  exit 2
fi
swift build --build-tests \
  -Xswiftc -F -Xswiftc "$framework_dir" \
  -Xswiftc -I -Xswiftc "$library_dir" \
  -Xlinker "-F$framework_dir" -Xlinker "-L$library_dir" \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  -Xlinker -rpath -Xlinker "$library_dir"
binary_dir="$(swift build --show-bin-path)"
exec "$xcode_dev/usr/bin/xctest" "$binary_dir/MeetingMacPackageTests.xctest"
