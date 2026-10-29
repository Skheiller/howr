#!/bin/zsh
# Builds build/Howr.app (release, ad-hoc signed). Usage: scripts/build.sh [--run]
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(cat VERSION)
BUILD_NUMBER=${HOWR_BUILD_NUMBER:-1}
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  echo "VERSION must be x.y.z and HOWR_BUILD_NUMBER must be numeric" >&2
  exit 1
fi

# pipefail makes a compile error fail the script; only grep's "no lines" status is ignored.
swift build -c release --arch arm64 --arch x86_64 2>&1 | { grep -vE '^\[' || true; }
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Howr

APP=build/Howr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Howr"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
strip -x "$APP/Contents/MacOS/Howr"

# Package the generated Howr brand mark at every macOS icon size.
rm -rf build/AppIcon.iconset
mkdir -p build/AppIcon.iconset
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" assets/brand/howr-logo.png --out "build/AppIcon.iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" assets/brand/howr-logo.png --out "build/AppIcon.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Howr</string>
  <key>CFBundleDisplayName</key><string>Howr</string>
  <key>CFBundleIdentifier</key><string>app.howr.Howr</string>
  <key>CFBundleExecutable</key><string>Howr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Howr — hourly chime</string>
</dict></plist>
PLIST

codesign --force --sign - --options runtime "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Howr 2>/dev/null || true
  open "$APP"
fi
