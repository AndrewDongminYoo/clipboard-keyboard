#!/bin/bash
# shellcheck disable=SC2310
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${repo_root}"

bootstatus_timeout_seconds=300
simulator_build_timeout_seconds=600
timeout_grace_seconds=10
cleanup_grace_seconds=2
active_child_pid=""
active_command_pgid=""
watchdog_pid=""
watchdog_pgid=""
timeout_marker=""
verifier_shell_pgid="$(/bin/ps -o pgid= -p "$$" | /usr/bin/tr -d '[:space:]')"

case "${verifier_shell_pgid}" in
"" | *[!0-9]*)
	echo "bounded verification command setup failed" >&2
	exit 1
	;;
*) ;;
esac

is_safe_command_group() {
	local leader_pid="$1"
	local process_group_id="$2"

	case "${process_group_id}" in
	"" | *[!0-9]*) return 1 ;;
	*) ;;
	esac
	[[ ${process_group_id} == "${leader_pid}" && ${process_group_id} != "${verifier_shell_pgid}" ]]
}

capture_command_group() {
	local leader_pid="$1"

	/bin/ps -o pgid= -p "${leader_pid}" | /usr/bin/tr -d '[:space:]'
}

command_group_is_alive() {
	local process_group_id="$1"

	if ! is_safe_command_group "${process_group_id}" "${process_group_id}"; then
		return 1
	fi
	/bin/kill -0 -- "-${process_group_id}" 2>/dev/null
}

terminate_command_group() {
	local leader_pid="$1"
	local process_group_id="$2"
	local grace_seconds="$3"

	if [[ -z ${process_group_id} ]]; then
		process_group_id="${leader_pid}"
	fi

	if ! is_safe_command_group "${leader_pid}" "${process_group_id}"; then
		echo "bounded verification command setup failed" >&2
		return 1
	fi

	if ! /bin/kill -0 -- "-${process_group_id}" 2>/dev/null; then
		return 0
	fi

	/bin/kill -TERM -- "-${process_group_id}" 2>/dev/null || true
	if [[ ${grace_seconds} -gt 0 ]]; then
		sleep "${grace_seconds}"
	fi
	if /bin/kill -0 -- "-${process_group_id}" 2>/dev/null; then
		/bin/kill -KILL -- "-${process_group_id}" 2>/dev/null || true
	fi
}

start_command_group() {
	set -m
	"$@" &
	active_child_pid="$!"
	set +m
	active_command_pgid="$(capture_command_group "${active_child_pid}")"

	if ! is_safe_command_group "${active_child_pid}" "${active_command_pgid}"; then
		echo "bounded verification command setup failed" >&2
		/bin/kill -TERM "${active_child_pid}" 2>/dev/null || true
		sleep "${cleanup_grace_seconds}"
		/bin/kill -KILL "${active_child_pid}" 2>/dev/null || true
		wait "${active_child_pid}" 2>/dev/null || true
		active_child_pid=""
		active_command_pgid=""
		return 1
	fi
}

cleanup_bounded_command() {
	local cleanup_failed=0

	if [[ -n ${watchdog_pid} ]]; then
		terminate_command_group "${watchdog_pid}" "${watchdog_pgid}" 0 || cleanup_failed=1
		wait "${watchdog_pid}" 2>/dev/null || true
		watchdog_pid=""
		watchdog_pgid=""
	fi

	if [[ -n ${active_child_pid} ]]; then
		terminate_command_group "${active_child_pid}" "${active_command_pgid}" "${cleanup_grace_seconds}" || cleanup_failed=1
		wait "${active_child_pid}" 2>/dev/null || true
		active_child_pid=""
		active_command_pgid=""
	fi

	if [[ -n ${timeout_marker} ]]; then
		/bin/rm -f "${timeout_marker}"
		timeout_marker=""
	fi

	return "${cleanup_failed}"
}

run_bounded() {
	local timeout_seconds="$1"
	local command_exit=0
	local watchdog_exit=0
	local timed_out=0

	shift
	timeout_marker="$(mktemp "${TMPDIR:-/tmp}/clipboard-keyboard-verify.XXXXXX")"
	/bin/rm -f "${timeout_marker}"
	start_command_group "$@"

	set -m
	(
		sleep "${timeout_seconds}"
		if command_group_is_alive "${active_command_pgid}"; then
			: >"${timeout_marker}"
			terminate_command_group "${active_child_pid}" "${active_command_pgid}" "${timeout_grace_seconds}"
			exit 42
		fi
		exit 0
	) &
	watchdog_pid="$!"
	set +m
	watchdog_pgid="$(capture_command_group "${watchdog_pid}")"
	if ! is_safe_command_group "${watchdog_pid}" "${watchdog_pgid}"; then
		echo "bounded verification command setup failed" >&2
		cleanup_bounded_command
		return 1
	fi

	set +e
	wait "${active_child_pid}" 2>/dev/null
	command_exit=$?
	set -e

	if [[ ! -e ${timeout_marker} ]] && command_group_is_alive "${watchdog_pgid}"; then
		terminate_command_group "${watchdog_pid}" "${watchdog_pgid}" 0 || true
	fi
	set +e
	wait "${watchdog_pid}" 2>/dev/null
	watchdog_exit=$?
	set -e

	if [[ ${watchdog_exit} -eq 42 ]]; then
		timed_out=1
	fi

	terminate_command_group "${active_child_pid}" "${active_command_pgid}" "${timeout_grace_seconds}" || true
	active_child_pid=""
	active_command_pgid=""
	watchdog_pid=""
	watchdog_pgid=""
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
