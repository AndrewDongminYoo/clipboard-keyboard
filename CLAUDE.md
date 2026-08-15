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

## Source of truth

`docs/specs/2026-08-13-clipboard-keyboard-design.md` is the product and security source of truth; `docs/plans/2026-08-13-clipboard-keyboard-apple-mvp-implementation.md` is the task-by-task plan with a design-requirement traceability table.
`README.md` owns prerequisites, local signing setup, and the stated platform limits — don't restate them here.
Unsigned verification proves none of App Group access, CloudKit delivery, device-lock behavior, App Intent authentication, or real keyboard behavior; those are manual gates recorded in `docs/notes/apple-mvp-release-evidence.md`.
