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

ensure_apple_build_gate() {
	if pgrep -x xcodebuild >/dev/null || pgrep -x SWBBuildService >/dev/null; then
		echo "another Apple build is active; refusing to stack heavy jobs" >&2
		exit 1
	fi
	local one_minute_load
	one_minute_load="$(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/')"
	awk -v load="${one_minute_load}" 'BEGIN { exit !(load <= 10) }' || {
		echo "one-minute load ${one_minute_load} exceeds the Apple build gate" >&2
		exit 1
	}
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

share_activation_rule_is_valid() {
	local candidate_rule="$1"
	[[ ${candidate_rule} != *"TRUEPREDICATE"* &&
		${candidate_rule} != *"FALSEPREDICATE"* &&
		${candidate_rule} != *'UTI-CONFORMS-TO "public.text"'* &&
		${candidate_rule} == *'== "public.utf8-plain-text"'* &&
		${candidate_rule} == *'== "public.utf16-external-plain-text"'* &&
		${candidate_rule} == *'== "public.utf16-plain-text"'* &&
		${candidate_rule} == *'== "public.plain-text"'* &&
		${candidate_rule} == *'== "public.url"'* &&
		${candidate_rule} == *'UTI-CONFORMS-TO "public.file-url"'* &&
		${candidate_rule} == *'UTI-CONFORMS-TO "public.image"'* &&
		${candidate_rule} == *"\$item.attachments.@count == 1"* ]]
}

if share_activation_rule_is_valid "FALSEPREDICATE"; then
	echo "share activation guard negative regression failed" >&2
	exit 1
fi
# shellcheck disable=SC2016
broad_text_regression='UTI-CONFORMS-TO "public.text" == "public.utf8-plain-text" == "public.utf16-external-plain-text" == "public.utf16-plain-text" == "public.plain-text" == "public.url" UTI-CONFORMS-TO "public.file-url" UTI-CONFORMS-TO "public.image" $item.attachments.@count == 1'
if share_activation_rule_is_valid "${broad_text_regression}"; then
	echo "share activation guard broad-text negative regression failed" >&2
	exit 1
fi
if ! share_activation_rule_is_valid "${share_activation_rule}"; then
	echo "share generated plist contract failed" >&2
	exit 1
fi
swift test --package-path Packages/ClipboardCore
ensure_apple_build_gate
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

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
ensure_apple_build_gate
run_bounded "${simulator_build_timeout_seconds}" xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -configuration Debug -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO test
ensure_apple_build_gate
run_bounded "${simulator_build_timeout_seconds}" xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardKeyboard -configuration Debug -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO test
ensure_apple_build_gate
run_bounded "${simulator_build_timeout_seconds}" xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardShare -configuration Debug -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO test
./scripts/security-audit.sh
trunk fmt --no-fix --diff=full project.yml Config Packages Apps Extensions Tests scripts README.md docs/specs docs/plans docs/notes
trunk check --no-fix project.yml Config Packages Apps Extensions Tests scripts README.md docs/specs docs/plans docs/notes
