# Contributing

Open an issue for a bug or a proposed change. For bugs, include macOS version, app version and a short reproduction. Use the private security-reporting form for vulnerabilities.

Fork the public repository, create a branch for your change, and build on macOS
14+ with Xcode command-line tools. There are no third-party Swift dependencies:

```sh
git clone https://github.com/YOUR-USERNAME/howr.git
cd howr
git switch -c your-change
swift test
python3 Tests/installer_test.py
scripts/build.sh --run
```

Keep the menu-bar agent event-driven. UI and audio belong in short-lived processes. Test changes to scheduling around DST, sleep/wake and pauses; test IPC edits through process exit and UI reopening. Keep native renders distinct from generated concept artwork. Save new captures to a dated folder.

For packaging changes, also run `scripts/release.sh`. It verifies the universal
app, mounts and checks the DMG, and validates all packaged checksums. The release
assets remain ad-hoc signed and are not notarized. Do not remove quarantine or
disable Gatekeeper in an installer.

For UI changes, include current screenshots and check keyboard navigation,
daylight/backlight appearance, closing/reopening the UI, and Settings. For
scheduling changes, include a reproducible example and test DST, active hours,
pause/skip and sleep/wake behavior. Tests do not replace real Mac checks.

Keep `.build/` and `build/` untracked. Save new native screenshots to a new dated
directory. Do not present generated brand/concept artwork as screenshots.

Pull requests should state the problem, resulting behavior, checks run and any
remaining limits. The macOS CI must pass. Release tags and Homebrew updates are
maintainer tasks; contributors should not publish releases or bump `VERSION`
unless the change calls for it. Contributions use the repository's MIT license.
