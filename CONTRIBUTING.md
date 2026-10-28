# Contributing

Open an issue for a bug or a proposed change. For bugs, include macOS version, app version and a short reproduction. Use the private security-reporting form for vulnerabilities.

Build on macOS 14+ with Xcode command-line tools:

```sh
swift test
scripts/build.sh --run
```

Keep the menu-bar agent event-driven. UI and audio belong in short-lived processes. Test changes to scheduling around DST, sleep/wake and pauses; test IPC edits through process exit and UI reopening. Keep native renders distinct from generated concept artwork. Save new captures to a dated folder.

Pull requests should state the problem, resulting behavior and verification. Contributions use the repository's MIT license.
