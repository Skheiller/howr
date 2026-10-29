#!/bin/bash
# Verify the mounted distribution, not only the app used to create it.
set -euo pipefail
image=$1 version=$2
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/howr-dmg-check.XXXXXX")
attach_started=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$attach_started" -eq 1 ]]; then
    # A signal can arrive after attachment but before attach returns to Bash.
    # Inspect actual mount state rather than relying on a post-attach flag.
    if ! mounts=$(/sbin/mount); then
      echo "Could not inspect mounts; leaving $work intact." >&2
      exit 1
    fi
    if /usr/bin/grep -Fq " on $work/mount (" <<< "$mounts"; then
      if ! /usr/bin/hdiutil detach "$work/mount"; then
        echo "Could not detach $work/mount; leaving verification directory intact." >&2
        exit 1
      fi
    fi
  fi
  /bin/rm -rf "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/hdiutil verify "$image"
/bin/mkdir "$work/mount"
attach_started=1
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$image"
[[ -L "$work/mount/Applications" && "$(/usr/bin/readlink "$work/mount/Applications")" == /Applications ]]
app="$work/mount/Howr.app"
/usr/bin/codesign --verify --deep --strict "$app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == app.howr.Howr ]]
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]]
architectures=$(/usr/bin/lipo -archs "$app/Contents/MacOS/Howr")
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]
/usr/bin/ditto "$app" "$work/Howr.app"
/usr/bin/codesign --verify --deep --strict "$work/Howr.app"
[[ -s "$work/Howr.app/Contents/Resources/AppIcon.icns" ]]
echo "Verified mounted DMG, Applications shortcut, universal app and copied signature."
