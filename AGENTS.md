# Clipboard Keyboard

Regenerate `ClipboardKeyboard.xcodeproj` only from `project.yml`; never edit generated project files.

Preserve the privacy-before-read boundary: product code must classify metadata before reading clipboard content.

The keyboard extension is read-only, never requests Full Access, and must not access the network.

Run only one heavy Apple job at a time, including Simulator boot and `xcodebuild`.

Run `./scripts/verify.sh` before completing a change.
