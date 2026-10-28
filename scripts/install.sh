#!/bin/bash
# Download from the public release, verify before replacing, and retain macOS security settings.
set -euo pipefail
fail() { echo "Howr: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "macOS 14 or later is required."
major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
[[ "$major" -ge 14 ]] || fail "macOS 14 or later is required."
case "$(uname -m)" in arm64|x86_64) ;; *) fail "Apple silicon or Intel is required." ;; esac
[[ "$(id -u)" -ne 0 ]] || fail "Run as your normal user, without sudo."
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/howr-download.XXXXXX")
stage=""
cleanup() {
  if [[ -n "$stage" && -d "$stage" ]]; then
    if [[ -d "$stage/previous.app" && ! -e "$target" ]]; then /bin/mv "$stage/previous.app" "$target"; fi
    /bin/rm -rf "$stage"
  fi
  /bin/rm -rf "$work"
}
trap cleanup EXIT
fetch() { /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 120 "$1" -o "$2"; }
base=https://github.com/Skheiller/howr/releases
fetch "$base/latest/download/release.json" "$work/release.json"
version=$(/usr/bin/plutil -extract version raw "$work/release.json")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid release version."
checksum=$(/usr/bin/plutil -extract sha256 raw "$work/release.json")
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid release checksum."
archive="Howr-$version-universal.zip"
fetch "$base/download/v$version/$archive" "$work/$archive"
actual=$(/usr/bin/shasum -a 256 "$work/$archive" | /usr/bin/awk '{print $1}')
[[ "$actual" == "$checksum" ]] || fail "Checksum mismatch; nothing was installed."
# Reject absolute/traversal paths before extraction. ditto archives can also contain __MACOSX metadata.
/usr/bin/zipinfo -1 "$work/$archive" > "$work/entries"
if /usr/bin/awk '/^\// || /(^|\/)\.\.(\/|$)/ || ($0 !~ /^Howr\.app\// && $0 !~ /^__MACOSX\//) {bad=1} END {exit !bad}' "$work/entries"; then
  fail "Unexpected archive contents."
fi
/usr/bin/ditto -x -k "$work/$archive" "$work/extracted"
app="$work/extracted/Howr.app"
/usr/bin/codesign --verify --deep --strict "$app" || fail "Invalid app signature."
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == app.howr.Howr ]] || fail "Unexpected app identifier."
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]] || fail "Version mismatch."
install_dir=${HOWR_INSTALL_DIR:-/Applications}
if [[ -z "${HOWR_INSTALL_DIR:-}" && ! -w "$install_dir" ]]; then install_dir="$HOME/Applications"; fi
/bin/mkdir -p "$install_dir"
target="$install_dir/Howr.app"
[[ ! -L "$target" ]] || fail "Refusing to replace a symbolic link."
if [[ -e "$target" ]]; then
  [[ -d "$target" ]] || fail "An unexpected file exists at $target."
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$target/Contents/Info.plist")" == app.howr.Howr ]] || fail "A different app occupies $target."
  if /usr/bin/pgrep -x Howr >/dev/null; then fail "Quit Howr from its menu before upgrading, then run this command again."; fi
fi
stage=$(/usr/bin/mktemp -d "$install_dir/.howr-install.XXXXXX")
/usr/bin/ditto "$app" "$stage/Howr.app"
/usr/bin/codesign --verify --deep --strict "$stage/Howr.app"
if [[ -e "$target" ]]; then /bin/mv "$target" "$stage/previous.app"; fi
/bin/mv "$stage/Howr.app" "$target"
echo "Installed Howr $version at $target"
echo "This release is ad-hoc signed, not Apple-notarized."
echo "Open Howr in Finder. If blocked, review System Settings → Privacy & Security → Open Anyway."
