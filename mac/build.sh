#!/usr/bin/env bash
# Builds a universal DripWriter.app (arm64 + x86_64) and a release zip.
#   ./build.sh            build into build/
#   ./build.sh --install  also copy to /Applications and link the `dripwriter` command
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(grep -m1 'let appVersion' DripWriter.swift | sed 's/.*"\(.*\)".*/\1/')
APP=build/DripWriter.app
rm -rf build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14" DripWriter.swift -o "build/DripWriter-$arch"
done
lipo -create build/DripWriter-arm64 build/DripWriter-x86_64 -output "$APP/Contents/MacOS/DripWriter"
rm build/DripWriter-arm64 build/DripWriter-x86_64
[[ -f assets/AppIcon.icns ]] || { swift tools/make-icon.swift assets >/dev/null && iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns && rm -rf assets/AppIcon.iconset; }
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DripWriter</string>
<key>CFBundleDisplayName</key><string>DripWriter</string>
<key>CFBundleIdentifier</key><string>tech.rennko.dripwriter</string>
<key>CFBundleExecutable</key><string>DripWriter</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Made by Virat Reddy Kaukuntla</string>
</dict></plist>
PL
# Sign with a real certificate when there is one: macOS ties the Accessibility permission to the signature,
# so a stable identity keeps the permission across updates (an ad-hoc signature changes every build).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')}"
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --deep --timestamp=none -s "$SIGN_ID" "$APP" && echo "Signed with $SIGN_ID"
else
  codesign --force --deep -s - "$APP" && echo "Signed ad-hoc (no certificate found)"
fi
(cd build && ditto -c -k --keepParent DripWriter.app DripWriter-macOS.zip)
echo "Built $APP ($VERSION) and build/DripWriter-macOS.zip"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x DripWriter 2>/dev/null || true
  rm -rf /Applications/DripWriter.app && cp -R "$APP" /Applications/
  mkdir -p "$HOME/.local/bin" && ln -sf /Applications/DripWriter.app/Contents/MacOS/DripWriter "$HOME/.local/bin/dripwriter"
  echo "Installed to /Applications; command at ~/.local/bin/dripwriter"
fi
