#!/bin/bash
# Verify public release assets and retain macOS security settings.
set -euo pipefail
fail() { echo "Howr: $*" >&2; exit 1; }
work=""; stage=""; target=""; lock_dir=""; lock_owned=0; committed=0
cleanup() {
  local result=$?
  trap - EXIT INT TERM HUP
  set +e
  local keep_stage=0
  if [[ -n "$stage" && -d "$stage" ]]; then
    if [[ "$committed" -eq 0 && -d "$stage/previous.app" ]]; then
      if [[ ! -e "$target" ]]; then
        /bin/mv "$stage/previous.app" "$target" || keep_stage=1
      else
        keep_stage=1
      fi
      if [[ "$keep_stage" -eq 1 ]]; then echo "Previous app preserved at $stage/previous.app" >&2; fi
    fi
    if [[ "$keep_stage" -eq 0 ]]; then /bin/rm -rf "$stage"; fi
  fi
  if [[ "$lock_owned" -eq 1 ]]; then /bin/rmdir "$lock_dir"; fi
  if [[ -n "$work" ]]; then /bin/rm -rf "$work"; fi
  exit "$result"
}
arm_cleanup() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
fetch() { /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 120 "$1" -o "$2"; }
_howr_move() { /bin/mv "$@"; }
_howr_copy() { /usr/bin/ditto "$@"; }
_howr_verify() { /usr/bin/codesign --verify --deep --strict "$1"; }
_howr_check_target() {
  if [[ -e "$target" ]]; then
    [[ -d "$target" ]] || fail "An unexpected file exists at $target."
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$target/Contents/Info.plist")" == app.howr.Howr ]] || fail "A different app occupies $target."
    if /usr/bin/pgrep -x Howr >/dev/null; then fail "Quit Howr from its menu before upgrading, then run this command again."; fi
  fi
}
# The lock, rollback and move sequence is exercised by Tests/installer_test.py.
_howr_install_app() {
  local app=$1 install_dir=$2
  /bin/mkdir -p "$install_dir"
  target="$install_dir/Howr.app"
  lock_dir="$install_dir/.howr-install.lock"
  arm_cleanup
  /bin/mkdir "$lock_dir" 2>/dev/null || fail "Another install is running, or an interrupted install left $lock_dir. Check before removing a stale lock."
  lock_owned=1
  [[ ! -L "$target" ]] || fail "Refusing to replace a symbolic link."
  _howr_check_target
  stage=$(/usr/bin/mktemp -d "$install_dir/.howr-install.XXXXXX")
  _howr_copy "$app" "$stage/Howr.app"
  _howr_verify "$stage/Howr.app"
  if [[ -e "$target" ]]; then _howr_move "$target" "$stage/previous.app"; fi
  [[ ! -e "$target" ]] || fail "The destination became occupied; nothing will be nested into it."
  _howr_move "$stage/Howr.app" "$target"
  _howr_verify "$target"
  [[ ! -e "$target/Howr.app" ]] || fail "Unexpected nested app; installation did not complete."
  committed=1
}
main() {
[[ "$(uname -s)" == Darwin ]] || fail "macOS 14 or later is required."
major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
[[ "$major" -ge 14 ]] || fail "macOS 14 or later is required."
case "$(uname -m)" in arm64|x86_64) ;; *) fail "Apple silicon or Intel is required." ;; esac
[[ "$(id -u)" -ne 0 ]] || fail "Run as your normal user, without sudo."
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/howr-download.XXXXXX")
arm_cleanup
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
_howr_install_app "$app" "$install_dir"
echo "Installed Howr $version at $target"
echo "This release is ad-hoc signed, not Apple-notarized."
echo "Open Howr in Finder. If blocked, review System Settings → Privacy & Security → Open Anyway."
}
# Sourcing defines functions for isolated replacement tests; piping into Bash runs main.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
