# Security

Report a suspected vulnerability through this repository's **Security → Report a vulnerability** form. Please keep reports private until a fix is available. Include your macOS version, Howr version and steps to reproduce. Do not include passwords or private recordings.

The latest release is the supported version. Howr has no account, analytics, remote control service or automatic updater. Its agent communicates with its UI through inherited local pipes. Optional microphone checks read CoreAudio activity; Howr does not record audio.

Current releases are ad-hoc signed and are not Apple-notarized. SHA-256 checksums detect download corruption; they do not establish a Developer ID publisher identity. Download only from this repository's Releases page or the linked Homebrew tap. Follow [Apple's first-launch instructions](https://support.apple.com/102445) if macOS blocks the app. No install method disables Gatekeeper or removes quarantine attributes.
