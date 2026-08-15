# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
`AGENTS.md` is a symlink to this file, so Codex and other agents read the same text — edit this file, never the link.

## Working rules

Run `./scripts/verify.sh` before completing any change.

Run only one heavy Apple job at a time, including Simulator boot and `xcodebuild`.

Regenerate `ClipboardKeyboard.xcodeproj` only from `project.yml`; never edit generated project files.

Preserve the privacy-before-read boundary: product code must classify metadata before reading clipboard content.

The keyboard extension is read-only, never requests Full Access, and must not access the network.

## Commands

```bash
./scripts/generate-project.sh   # project.yml -> ClipboardKeyboard.xcodeproj (xcodegen, version-pinned)
./scripts/verify.sh             # the full gate
./scripts/security-audit.sh     # grep-based API bans + entitlement contracts (also run inside verify.sh)
```

`verify.sh` regenerates the project, asserts the keyboard/Share Info.plist contracts, runs `swift test` on ClipboardCore, runs the four Xcode scheme test bundles unsigned and sequentially, runs the security audit, then `trunk fmt --no-fix` and `trunk check --no-fix`.

It exits 1 before building if another `xcodebuild`/`SWBBuildService` is running, if the 1-minute load average exceeds 10, or if there is not exactly one available `iPhone 17 Pro Max` simulator.

Standalone, deliberately _not_ wired into `verify.sh` — run them by hand when the change touches their area:

```bash
./scripts/audit-keyboard-boundary.sh          # stricter keyboard-only boundary audit
./scripts/test-bounded-runner.sh              # tests the C timeout supervisor used by verify.sh
swift scripts/generate-search-fixtures.swift  # seeded 5,000-record search fixtures
./scripts/measure-mac-idle.sh --self-test     # idle sampler self-check (real run needs a signed Release build)
```

### Single test

Tests are XCTest (no swift-testing).

```bash
swift test --package-path Packages/ClipboardCore --filter PrivacyGateTests
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClipboardKeyboardMacTests/PrivacyBoundaryIntegrationTests test
```

For the three iOS schemes (`ClipboardKeyboardiOS`, `ClipboardKeyboardKeyboard`, `ClipboardKeyboardShare`) swap the destination for `platform=iOS Simulator,id=<udid>`.

## Architecture

`Packages/ClipboardCore` is the platform-free domain: models, `PrivacyGate`, `RetentionPolicy`, transformations/extraction, `ClipSearchIndex`, sync primitives, and the `ClipPersisting` / `PinnedLibrary` ports in `Ports/Repositories.swift`.
It imports only Foundation and CryptoKit — no AppKit, UIKit, or CloudKit.
Each platform supplies its own adapters under `Apps/<platform>/Infrastructure/`; that is why `MacPinnedSyncEngine` and `PhonePinnedSyncEngine`, `MacRTFTextProjector` and `PhoneRTFTextProjector`, etc. exist as deliberate near-duplicates rather than a shared implementation.

The four targets are asymmetric by design:

- **macOS** — menu-bar app with consented short-lived encrypted local history plus explicit pinning. Owns capture (`PasteboardWatcher` → `ClipboardCaptureCoordinator`, wired in `MacAppModel`).
- **iPhone** — pinned-only. No history, no capture. `SystemPasteboardWriter` is the _sole_ pasteboard touchpoint and is write-only.
- **Keyboard** — read-only consumer of an App Group snapshot file (`keyboard-snapshot-v1.json` + digest, `.previous` fallback, `.revoked` fence), written by `KeyboardSnapshotPublisher` in the iPhone app. Full Access stays disabled.
- **Share** — write-only: queues one item into the App Group inbox; the containing app drains it via `ShareInboxConsumer`.

Only the two apps get CloudKit; only explicitly pinned content syncs, through the private container.

### The privacy-before-read invariant

`PrivacyGate.evaluate(metadata:policy:)` takes only _metadata_ (declared type identifiers, source confidence, change count) and returns `.authorizeRead` or `.drop`.
Clipboard content must never be read before that returns `.authorizeRead`.
This ordering is the product's core security claim — the audit scripts exist to protect it, so a change that trips them is a design problem, not a lint nit.

## Constraints that reject otherwise-reasonable code

`scripts/security-audit.sh` greps production Swift and fails the build on:

- Any `print` / `debugPrint` / `dump` / `Logger` / `os_log` in `Apps`, `Extensions`, or `Packages/ClipboardCore/Sources` — content-capable logging is banned outright.
- `UIPasteboard` anywhere in `Apps/iOS` except `Infrastructure/Pasteboard/SystemPasteboardWriter.swift`, which must contain exactly one `UIPasteboard` reference and it must be a write.
- `import CloudKit` / `Network` / `URLSession` / any networking symbol anywhere under `Extensions/`.
- Any pasteboard API at all in `Extensions/Keyboard`.
- A `DEVELOPMENT_TEAM` value in tracked config (signing goes in the gitignored `Config/Signing.local.xcconfig`).
- Entitlements drift: extensions may not carry iCloud/APS keys, and every entitlement file must list exactly `group.kr.donminzzi.clipboardkeyboard`.

`ClipboardKeyboard.xcodeproj/` is gitignored and fully generated, Info.plists under `Generated/` included.
Edit `project.yml` and re-run `generate-project.sh`; expect a clean clone to have no `.xcodeproj` until you generate one.
XcodeGen is pinned by `.xcodegen-version` and the script refuses a mismatched version.

## Known traps

**A wedged CoreSimulator looks like a slow build.**
`xcodebuild test` stops after `Resolved source packages` and prints nothing further, while the process sits in `-[SimDevice(DVTAdditions) dvt_installApplicationAtPath:]` indefinitely.
Neither the unified log nor the device's own logs record anything, so there is no error to find.
Confirm it outside xcodebuild with `xcrun simctl install <udid> <path>.app`, which hangs identically, then clear it with `pkill -f "CoreSimulator.CoreSimulatorService"` — launchd respawns the service and no sudo is needed.
Measured 2026-08-15: install went from an indefinite hang to 7.5 seconds, and a full `verify.sh` from over 52 minutes to 84 seconds.

**`verify.sh` only ever builds Debug.**
It runs the four scheme test bundles in Debug against concrete destinations, so the gate never compiles a Release configuration or a generic destination.
Release-only breakage passes it unseen: `Packages/ClipboardCore/Package.swift` shipped with no `platforms:` declaration and every Release build failed on `concurrency is only available in macOS 10.15.0 or newer` while the gate stayed green.
Build a Release archive by hand after touching `Package.swift`, `Config/*.xcconfig`, or any deployment target.

**The build gate races the build service this script itself starts.**
`ensure_apple_build_gate` refuses to run when `SWBBuildService` is alive, but every `xcodebuild` stage leaves that service resident for a while after it finishes, so a later stage in the same run can trip on the service an earlier stage just used.
It therefore polls for up to `apple_build_gate_wait_seconds` instead of failing on sight; a real competing build still blocks the run, it just no longer fails on its own shadow.
The same lag applies to you: after running any `xcodebuild` by hand, wait for `pgrep -x SWBBuildService` to come back empty before starting `verify.sh`.

**Every platform contract here sits behind a fake, so a green suite says nothing about it.**
`verify.sh` passed on all five defects the first device pass turned up, and each one had a test suite standing next to it: the package declared no `platforms:` and no Release build had ever run; the icons shipped an alpha channel because assets are binary rather than source; the keyboard declared no `PrimaryLanguage` and aborted whichever app hosted it; the sync engine cancelled `CKSyncEngine` from inside that engine's own event callback, which a fake transport returns from harmlessly; and the macOS master key was never created, because `MacKeychainMasterKeyStoreTests` injects a fake `KeychainOperations` and never reaches `SecItemAdd`.
Read the suite as pinning what someone chose to pin. A real `SecItemAdd`, a real `CKSyncEngine` callback, a Release configuration, a binary asset's attributes, and a device install are all outside it — this is [evidence-basis-discipline]'s "a gate's green is evidence only about what the gate reads", and it has now cost five separate debugging sessions in this repository alone.
Two of the five are worth naming because they are invisible from the code: on macOS the data protection keychain needs an access group whitelisted by a provisioning profile, which a non-sandboxed app cannot have, so `kSecUseDataProtectionKeychain` fails with `errSecMissingEntitlement` (-34018) forever; and `CKSyncEngine` traps the process if you cancel it from within `handleEvent`.

**Production code cannot log, so failures arrive as a single bit.**
`security-audit.sh` bans `print`, `Logger`, and `os_log` outright, which is what keeps clipboard content out of the system log — but it also means a bootstrap failure used to reduce to `protectedStorageLocked = true` with the reason discarded, and diagnosing one took a code read plus a separately compiled probe.
`MacSettingsModel.recordProtectedStorageFailure(_:)` is the pattern to follow when adding a failure path: surface a case from an internal error enum, never an arbitrary `Error`'s description, which can carry a path or a fragment of a record.

**The two platforms' app icons follow opposite rules.**
iOS wants a full-bleed opaque square — no alpha, no rounded corners, no outer shadow — because the system applies its own mask, and an alpha channel is rejected at submission.
macOS wants the reverse: an 824x824 body centered in a 1024 canvas with transparent margins, an alpha channel, and a soft drop shadow, which is what Notes, Reminders, Calculator, and Maps all measure to on this machine.
Reusing the iOS artwork for `Apps/macOS` renders oversized and square-cornered in the Dock.
The iOS set carries the `iphone` and `ios-marketing` idioms only; restoring an `ipad` idiom also means changing `TARGETED_DEVICE_FAMILY`, which every iOS target pins to `1`.
Do not hand-add an `.icns` — actool builds one from the macOS PNGs and emplaces it during the build.

## Source of truth

`docs/specs/2026-08-13-clipboard-keyboard-design.md` is the product and security source of truth; `docs/plans/2026-08-13-clipboard-keyboard-apple-mvp-implementation.md` is the task-by-task plan with a design-requirement traceability table.
`README.md` owns prerequisites, local signing setup, and the stated platform limits — don't restate them here.
Unsigned verification proves none of App Group access, CloudKit delivery, device-lock behavior, App Intent authentication, or real keyboard behavior; those are manual gates recorded in `docs/notes/apple-mvp-release-evidence.md`.
