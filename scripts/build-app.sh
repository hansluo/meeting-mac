#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the selected Swift/SDK without changing Xcode selection or license state.
swift build -c release --product MeetingMacApp \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$PWD/dist"
final_app="$PWD/dist/Meeting Mac.app"
staging="$(mktemp -d "$PWD/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Meeting Mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/FunASR"
# The complete default build includes all local weights and native runtimes.
python3 scripts/prepare-builtin-resources.py "$app/Contents/Resources/BuiltinModels"
cp -R "$binary_dir/MeetingMac_MeetingCore.bundle" "$app/Contents/Resources/"
cp -R ThirdParty "$app/Contents/Resources/ThirdParty"
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
<key>CFBundleShortVersionString</key><string>0.3.0</string>
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
# Activate only after a complete verified bundle exists; retain the old app on build failure.
if [[ -e "$final_app" ]]; then mv "$final_app" "$staging/previous.app"; fi
if ! mv "$app" "$final_app"; then
  if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$final_app"; fi
  exit 1
fi
printf 'Built: %s\n' "$final_app"
printf '%s\n' 'SenseVoice, Google embedding and native runtimes are included; no Python is required for defaults.'
