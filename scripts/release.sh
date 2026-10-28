#!/bin/bash
# Build and verify the universal app, then package immutable versioned release assets.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(cat VERSION)
if [[ -n "${HOWR_RELEASE_TAG:-}" && "$HOWR_RELEASE_TAG" != "v$version" ]]; then
  echo "Release tag must match VERSION (v$version)." >&2; exit 1
fi
scripts/build.sh
app=build/Howr.app
/usr/bin/codesign --verify --deep --strict "$app"
architectures=$(/usr/bin/lipo -archs "$app/Contents/MacOS/Howr")
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]]
mkdir -p build/release
archive="Howr-$version-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "build/release/$archive"
cd build/release
/usr/bin/shasum -a 256 "$archive" > SHA256SUMS
checksum=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
cat > release.json <<JSON
{"version":"$version","minimum_macos":"14.0","architectures":["arm64","x86_64"],"signing":"ad-hoc","notarized":false,"sha256":"$checksum"}
JSON
/usr/bin/shasum -a 256 -c SHA256SUMS
echo "Release assets are in build/release (ad-hoc signed, not notarized)."
