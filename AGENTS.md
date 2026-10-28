# Howr native app

This workspace uses Swift Package Manager, not Bun. On macOS 14+ with Xcode command-line tools, run `swift test` and `scripts/build.sh`. The latter produces an ad-hoc signed universal `build/Howr.app`. `scripts/build.sh --run` also launches it.

Keep `.build/` and `build/` untracked. Do not add Swift commands to the Linux web build. `VERSION` is Howr's release version; `HOWR_BUILD_NUMBER` optionally supplies its numeric bundle build number. Portfolio tags do not version this app.

`design/landing/references/` contains native UI renders. Other landing PNGs are generated concepts; preserve that distinction in public captions.
