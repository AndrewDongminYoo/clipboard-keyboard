# Clipboard Keyboard

## Product Boundary

Clipboard Keyboard is a privacy-first native Apple clipboard library and keyboard.

The macOS app keeps short local history, while iPhone and the keyboard operate only on explicitly pinned content.

The keyboard is read-only and keeps Full Access disabled.

## Prerequisites

Install Xcode and XcodeGen `2.46.0`.

Install Trunk `1.25.0` for the local quality gate.

## Generate

```bash
./scripts/generate-project.sh
```

## Verify

```bash
./scripts/verify.sh
```

## Local Signing

Copy the required local signing settings into `Config/Signing.local.xcconfig`.

This file is ignored by Git, and tracked configuration never contains a team identifier.

## Source of Truth

`project.yml` is the source of truth for the generated Xcode project.

`docs/specs/2026-08-13-clipboard-keyboard-design.md` is the product and security source of truth.
