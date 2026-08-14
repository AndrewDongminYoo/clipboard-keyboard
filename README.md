# Clipboard Keyboard

## Product Boundary

Clipboard Keyboard is a privacy-first native Apple clipboard library and keyboard.

The macOS app keeps short local history, while iPhone and the keyboard operate only on explicitly pinned content.

The keyboard is read-only and keeps Full Access disabled.

## Prerequisites

Install Xcode with the macOS 14 and iOS 17 SDKs, XcodeGen `2.46.0`, and Swift 6.

Install Trunk `1.25.0` for the local quality gate.

The unsigned verifier expects exactly one available `iPhone 17 Pro Max` simulator.

## Generate

```bash
./scripts/generate-project.sh
```

## Verify

```bash
./scripts/verify.sh
```

This regenerates the project, runs the ClipboardCore package tests, runs the macOS, iPhone, keyboard, and Share scheme tests sequentially without code signing, audits source and generated entitlements, and runs the configured Trunk format and lint gates.

`./scripts/measure-mac-idle.sh --self-test` validates the sampler's 301-point, 300-second interval and median calculation without waiting five minutes; an actual measurement still requires exactly one non-ad-hoc signed Release app after the 60-second warm-up.

Unsigned verification does not prove App Group access, CloudKit delivery, device-lock behavior, App Intent authentication, or custom-keyboard behavior on a physical device.

## Local Signing

Copy the required local signing settings into `Config/Signing.local.xcconfig`.

This file is ignored by Git, and tracked configuration never contains a team identifier.

Use the following local-only values:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_IDENTIFIER
CODE_SIGN_STYLE = Automatic
```

Register `group.kr.donminzzi.clipboardkeyboard` for the iPhone app, keyboard extension, and Share extension.

Register the private CloudKit container `iCloud.kr.donminzzi.clipboardkeyboard` for the macOS and iPhone apps.

Do not add CloudKit, push, or networking entitlements to either extension.

Build and archive the `Release` configuration with local signing before collecting release evidence.

## Product Targets

- `ClipboardKeyboardMac` is the native macOS menu-bar app with consented, short local clipboard history and explicit pinning.
- `ClipboardKeyboardiOS` is the native iPhone pinned library, import/export surface, settings surface, and App Intent host.
- `ClipboardKeyboardKeyboard` is a read-only custom keyboard backed by a protected App Group snapshot with Full Access disabled.
- `ClipboardKeyboardShare` is the explicit Share handoff that queues one supported text or web URL for the containing app to commit.

## Privacy and Platform Limits

Application filtering is best effort because source attribution can become unknown during application switches.

Universal Clipboard is controlled by Apple platforms and is outside this product's control.

Payloads are not unlimited; rejected payloads fail explicitly rather than being silently truncated.

The custom keyboard is not available in every field, including secure fields, phone-pad fields, and hosts that reject third-party keyboards.

CloudKit stores only explicitly pinned content in encrypted fields, but this is not marketed as unconditional end-to-end encryption.

## Source of Truth

`project.yml` is the source of truth for the generated Xcode project.

`docs/specs/2026-08-13-clipboard-keyboard-design.md` is the product and security source of truth.
