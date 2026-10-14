#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the selected Swift/SDK without changing Xcode selection or license state.
swift build -c release --product MeetingMacApp \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Meeting Mac.app"
# Replace only the generated bundle; models and user environments are never copied.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/FunASR"
cp "$binary_dir/MeetingMacApp" "$app/Contents/MacOS/MeetingMacApp"
cp Runtime/FunASR/worker.py "$app/Contents/Resources/FunASR/worker.py"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MeetingMacApp</string>
<key>CFBundleIdentifier</key><string>com.hansluo.meetingmac</string>
<key>CFBundleName</key><string>Meeting Mac</string>
<key>CFBundleDisplayName</key><string>Meeting Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>NSHumanReadableCopyright</key><string>Meeting Mac</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# Local ad-hoc signature; distribution/notarization is a separate step.
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
printf '%s\n' 'Models, Python environments and sherpa dylibs are external: choose them in 模型设置.'
