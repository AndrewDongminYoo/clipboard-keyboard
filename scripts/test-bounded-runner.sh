#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source_path="${repo_root}/scripts/bounded-runner.c"
test_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-keyboard-bounded-runner-test.XXXXXX")"
runner_path="${test_tmp_dir}/bounded-runner"
failed_runner_path="${test_tmp_dir}/bounded-runner-handshake-failure"
background_pids=""
owned_group_ids=""

cleanup() {
	local background_pid
	local owned_group_id

	for background_pid in ${background_pids}; do
		/bin/kill -TERM "${background_pid}" 2>/dev/null || true
	done
	sleep 2
	for owned_group_id in ${owned_group_ids}; do
		/bin/kill -KILL -- "-${owned_group_id}" 2>/dev/null || true
	done
	for background_pid in ${background_pids}; do
		/bin/kill -KILL "${background_pid}" 2>/dev/null || true
		wait "${background_pid}" 2>/dev/null || true
	done
	/bin/rm -rf "${test_tmp_dir}"
}

trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_dead() {
	local process_pid="$1"
	local description="$2"
	local attempts_remaining=20

	while [[ ${attempts_remaining} -gt 0 ]]; do
		if ! /bin/kill -0 "${process_pid}" 2>/dev/null; then
			return 0
		fi
		sleep 0.05
		attempts_remaining=$((attempts_remaining - 1))
	done
	fail "${description} ${process_pid} is still alive"
}

wait_for_file() {
	local file_path="$1"
	local attempts_remaining=20

	while [[ ${attempts_remaining} -gt 0 ]]; do
		if [[ -s ${file_path} ]]; then
			return 0
		fi
		sleep 0.05
		attempts_remaining=$((attempts_remaining - 1))
	done
	fail "timed out waiting for ${file_path}"
}

run_expect_status() {
	local expected_status="$1"
	shift
	local command_status=0

	set +e
	"$@"
	command_status=$?
	set -e
	if [[ ${command_status} -ne ${expected_status} ]]; then
		fail "expected status ${expected_status}, got ${command_status}: $*"
	fi
}

[[ -f ${source_path} ]] || fail "runner source is missing: ${source_path}"

clang_path="$(xcrun --find clang)"
macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"${clang_path}" -isysroot "${macos_sdk_path}" -std=c11 -Wall -Wextra -Werror -pedantic "${source_path}" -o "${runner_path}"
"${clang_path}" -isysroot "${macos_sdk_path}" -std=c11 -Wall -Wextra -Werror -pedantic -DBOUNDED_RUNNER_TEST_HANDSHAKE_FAILURE "${source_path}" -o "${failed_runner_path}"

run_expect_status 7 "${runner_path}" 2 1 -- /bin/sh -c 'exit 7'
run_expect_status 143 "${runner_path}" 2 1 -- /bin/sh -c 'kill -TERM $$'

invalid_stderr="${test_tmp_dir}/invalid.stderr"
invalid_start=${SECONDS}
run_expect_status 1 "${runner_path}" 2 1 -- "${test_tmp_dir}/does-not-exist" 2>"${invalid_stderr}"
((SECONDS - invalid_start <= 4)) || fail "invalid command cleanup exceeded bound"
[[ $(<"${invalid_stderr}") == "bounded verification command setup failed" ]] || fail "invalid command diagnostic was not static"

unrelated_pid_file="${test_tmp_dir}/unrelated.pid"
unrelated_stop_file="${test_tmp_dir}/unrelated.stop"
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
/bin/sh -c 'echo $$ >"$1"; while [ ! -e "$2" ]; do sleep 0.1; done' sh "${unrelated_pid_file}" "${unrelated_stop_file}" &
unrelated_job_pid=$!
background_pids="${background_pids} ${unrelated_job_pid}"
wait_for_file "${unrelated_pid_file}"
unrelated_pid="$(<"${unrelated_pid_file}")"

timeout_child_pid_file="${test_tmp_dir}/timeout-child.pid"
timeout_grandchild_pid_file="${test_tmp_dir}/timeout-grandchild.pid"
timeout_stderr="${test_tmp_dir}/timeout.stderr"
timeout_start=${SECONDS}
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
"${runner_path}" 1 1 -- /bin/sh -c 'trap "" TERM; echo $$ >"$1"; sleep 0.2; (trap "" TERM; while :; do sleep 1; done) & echo $! >"$2"; while :; do sleep 1; done' sh "${timeout_child_pid_file}" "${timeout_grandchild_pid_file}" 2>"${timeout_stderr}" &
timeout_runner_pid=$!
background_pids="${background_pids} ${timeout_runner_pid}"
wait_for_file "${timeout_child_pid_file}"
timeout_sentinel_pid="$(/bin/ps -axo pid=,ppid= | /usr/bin/awk -v parent_pid="${timeout_runner_pid}" '$2 == parent_pid { print $1; exit }')"
[[ -n ${timeout_sentinel_pid} ]] || fail "timeout sentinel pid was not observable"
owned_group_ids="${owned_group_ids} ${timeout_sentinel_pid}"
run_expect_status 1 wait "${timeout_runner_pid}"
((SECONDS - timeout_start <= 4)) || fail "timeout cleanup exceeded bound"
[[ $(<"${timeout_stderr}") == "bounded verification command timed out" ]] || fail "timeout diagnostic was not the exact static line"
timeout_child_pid="$(<"${timeout_child_pid_file}")"
timeout_grandchild_pid="$(<"${timeout_grandchild_pid_file}")"
assert_dead "${timeout_runner_pid}" "timeout runner"
assert_dead "${timeout_sentinel_pid}" "timeout sentinel"
assert_dead "${timeout_child_pid}" "timeout child"
assert_dead "${timeout_grandchild_pid}" "timeout grandchild"
/bin/kill -0 "${unrelated_pid}" 2>/dev/null || fail "unrelated process was signaled"

signal_child_pid_file="${test_tmp_dir}/signal-child.pid"
signal_grandchild_pid_file="${test_tmp_dir}/signal-grandchild.pid"
signal_stderr="${test_tmp_dir}/signal.stderr"
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
"${runner_path}" 30 1 -- /bin/sh -c 'trap "" TERM; echo $$ >"$1"; (trap "" TERM; while :; do sleep 1; done) & echo $! >"$2"; while :; do sleep 1; done' sh "${signal_child_pid_file}" "${signal_grandchild_pid_file}" 2>"${signal_stderr}" &
signal_runner_pid=$!
background_pids="${background_pids} ${signal_runner_pid}"
wait_for_file "${signal_child_pid_file}"
wait_for_file "${signal_grandchild_pid_file}"
signal_sentinel_pid="$(/bin/ps -axo pid=,ppid= | /usr/bin/awk -v parent_pid="${signal_runner_pid}" '$2 == parent_pid { print $1; exit }')"
[[ -n ${signal_sentinel_pid} ]] || fail "signal sentinel pid was not observable"
owned_group_ids="${owned_group_ids} ${signal_sentinel_pid}"
signal_start=${SECONDS}
/bin/kill -TERM "${signal_runner_pid}"
run_expect_status 143 wait "${signal_runner_pid}"
((SECONDS - signal_start <= 4)) || fail "runner SIGTERM cleanup exceeded bound"
signal_child_pid="$(<"${signal_child_pid_file}")"
signal_grandchild_pid="$(<"${signal_grandchild_pid_file}")"
assert_dead "${signal_runner_pid}" "signal runner"
assert_dead "${signal_sentinel_pid}" "signal sentinel"
assert_dead "${signal_child_pid}" "signal child"
assert_dead "${signal_grandchild_pid}" "signal grandchild"
[[ ! -s ${signal_stderr} ]] || fail "runner SIGTERM emitted an unexpected diagnostic"
/bin/kill -0 "${unrelated_pid}" 2>/dev/null || fail "unrelated process was signaled during runner cleanup"

handshake_stderr="${test_tmp_dir}/handshake.stderr"
handshake_start=${SECONDS}
run_expect_status 1 "${failed_runner_path}" 2 1 -- /bin/sleep 30 2>"${handshake_stderr}"
((SECONDS - handshake_start <= 4)) || fail "handshake failure cleanup exceeded bound"
[[ $(<"${handshake_stderr}") == "bounded verification command setup failed" ]] || fail "handshake failure diagnostic was not static"
if /usr/bin/pgrep -f "${failed_runner_path}" >/dev/null; then
	fail "handshake-failure runner left a process behind"
fi
/bin/kill -0 "${unrelated_pid}" 2>/dev/null || fail "unrelated process was signaled by handshake cleanup"

: >"${unrelated_stop_file}"
wait "${unrelated_job_pid}" 2>/dev/null || true
echo "bounded runner tests passed"
