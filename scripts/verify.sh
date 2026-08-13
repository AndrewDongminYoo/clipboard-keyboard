#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${repo_root}"

bootstatus_timeout_seconds=300
simulator_build_timeout_seconds=600
timeout_grace_seconds=10
cleanup_grace_seconds=2
active_child_pid=""
watchdog_pid=""
timeout_marker=""
process_tree_pids=()

collect_process_tree() {
	local parent_pid="$1"
	local child_pid=""

	process_tree_pids+=("${parent_pid}")
	while IFS= read -r child_pid; do
		[[ -n ${child_pid} ]] || continue
		collect_process_tree "${child_pid}"
	done < <(/usr/bin/pgrep -P "${parent_pid}" 2>/dev/null || true)
}

terminate_process_tree() {
	local root_pid="$1"
	local grace_seconds="$2"
	local process_pid=""

	process_tree_pids=()
	collect_process_tree "${root_pid}"
	for process_pid in "${process_tree_pids[@]}"; do
		kill -TERM "${process_pid}" 2>/dev/null || true
	done

	if [[ ${grace_seconds} -gt 0 ]]; then
		sleep "${grace_seconds}"
	fi

	for process_pid in "${process_tree_pids[@]}"; do
		if kill -0 "${process_pid}" 2>/dev/null; then
			kill -KILL "${process_pid}" 2>/dev/null || true
		fi
	done
}

cleanup_bounded_command() {
	if [[ -n ${watchdog_pid} ]]; then
		terminate_process_tree "${watchdog_pid}" 0
		wait "${watchdog_pid}" 2>/dev/null || true
		watchdog_pid=""
	fi

	if [[ -n ${active_child_pid} ]]; then
		terminate_process_tree "${active_child_pid}" "${cleanup_grace_seconds}"
		wait "${active_child_pid}" 2>/dev/null || true
		active_child_pid=""
	fi

	if [[ -n ${timeout_marker} ]]; then
		/bin/rm -f "${timeout_marker}"
		timeout_marker=""
	fi
}

run_bounded() {
	local timeout_seconds="$1"
	local command_exit=0
	local watchdog_exit=0
	local timed_out=0

	shift
	timeout_marker="$(mktemp "${TMPDIR:-/tmp}/clipboard-keyboard-verify.XXXXXX")"
	/bin/rm -f "${timeout_marker}"
	"$@" &
	active_child_pid="$!"
	(
		sleep "${timeout_seconds}"
		if kill -0 "${active_child_pid}" 2>/dev/null; then
			: >"${timeout_marker}"
			terminate_process_tree "${active_child_pid}" "${timeout_grace_seconds}"
			exit 42
		fi
		exit 0
	) &
	watchdog_pid="$!"

	set +e
	wait "${active_child_pid}" 2>/dev/null
	command_exit=$?
	set -e

	if [[ ! -e ${timeout_marker} ]] && kill -0 "${watchdog_pid}" 2>/dev/null; then
		terminate_process_tree "${watchdog_pid}" 0
	fi
	set +e
	wait "${watchdog_pid}" 2>/dev/null
	watchdog_exit=$?
	set -e

	if [[ ${watchdog_exit} -eq 42 ]]; then
		timed_out=1
	fi

	active_child_pid=""
	watchdog_pid=""
	/bin/rm -f "${timeout_marker}"
	timeout_marker=""

	if [[ ${timed_out} -eq 1 ]]; then
		echo "bounded verification command timed out" >&2
		return 1
	fi

	return "${command_exit}"
}

trap cleanup_bounded_command EXIT
trap 'exit 1' INT TERM

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
