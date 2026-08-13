#!/bin/bash
# shellcheck disable=SC2310
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${repo_root}"

bootstatus_timeout_seconds=300
simulator_build_timeout_seconds=600
timeout_grace_seconds=10
runner_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-keyboard-verify-runner.XXXXXX")"
runner_path="${runner_build_dir}/bounded-runner"

cleanup_runner_build() {
	/bin/rm -rf "${runner_build_dir}"
}

trap cleanup_runner_build EXIT

clang_path="$(xcrun --find clang)"
macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"${clang_path}" -isysroot "${macos_sdk_path}" -std=c11 -Wall -Wextra -Werror -pedantic scripts/bounded-runner.c -o "${runner_path}"

run_bounded() {
	local timeout_seconds="$1"
	shift
	"${runner_path}" "${timeout_seconds}" "${timeout_grace_seconds}" -- "$@"
}

./scripts/generate-project.sh
keyboard_open_access=""
if ! keyboard_open_access="$(plutil -extract NSExtension.NSExtensionAttributes.RequestsOpenAccess raw -o - ClipboardKeyboard.xcodeproj/Generated/ClipboardKeyboardKeyboard-Info.plist 2>/dev/null)"; then
	echo "keyboard generated plist contract failed" >&2
	exit 1
fi
if [[ ${keyboard_open_access} != "false" ]]; then
	echo "keyboard generated plist contract failed" >&2
	exit 1
fi

share_activation_rule=""
if ! share_activation_rule="$(plutil -extract NSExtension.NSExtensionAttributes.NSExtensionActivationRule raw -o - ClipboardKeyboard.xcodeproj/Generated/ClipboardKeyboardShare-Info.plist 2>/dev/null)"; then
	echo "share generated plist contract failed" >&2
	exit 1
fi
if [[ ${share_activation_rule} != "FALSEPREDICATE" ]]; then
	echo "share generated plist contract failed" >&2
	exit 1
fi
swift test --package-path Packages/ClipboardCore
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build test

simulator_ids="$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone 17 Pro Max \(/ { print $2 }')"
simulator_count="$(printf '%s\n' "${simulator_ids}" | awk 'NF { count += 1 } END { print count + 0 }')"

if [[ ${simulator_count} != "1" ]]; then
	echo "expected exactly one available iPhone 17 Pro Max simulator, found ${simulator_count}" >&2
	exit 1
fi

simulator_id="$(printf '%s\n' "${simulator_ids}" | awk 'NF { print; exit }')"
simulator_state="$(xcrun simctl list devices available | awk -F '[()]' -v simulator_id="${simulator_id}" '$2 == simulator_id { gsub(/[[:space:]]/, "", $4); print $4; exit }')"

if [[ ${simulator_state} == "Shutdown" ]]; then
	xcrun simctl boot "${simulator_id}"
elif [[ ${simulator_state} != "Booted" ]]; then
	echo "iPhone 17 Pro Max simulator ${simulator_id} is in unsupported state ${simulator_state}" >&2
	exit 1
fi

run_bounded "${bootstatus_timeout_seconds}" xcrun simctl bootstatus "${simulator_id}" -b

simulator_destination="platform=iOS Simulator,id=${simulator_id}"
run_bounded "${simulator_build_timeout_seconds}" xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO build test
run_bounded "${simulator_build_timeout_seconds}" xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardKeyboard -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO build test
run_bounded "${simulator_build_timeout_seconds}" xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardShare -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO build test
