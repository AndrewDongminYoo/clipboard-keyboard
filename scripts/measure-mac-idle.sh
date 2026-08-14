#!/bin/bash
set -euo pipefail

measurement_duration_seconds=300
sample_count=$((measurement_duration_seconds + 1))
median_sample_number=$(((sample_count + 1) / 2))

median_cpu_from_file() {
	local sample_file="$1"
	tail -n +2 "${sample_file}" | cut -d, -f2 | sort -n | awk -v median_sample_number="${median_sample_number}" 'NR == median_sample_number { printf "%.3f", $1 }'
}

if [[ ${1:-} == "--self-test" ]]; then
	self_test_samples="$(mktemp "${TMPDIR:-/tmp}/clipboard-keyboard-idle-self-test.XXXXXX")"
	trap '/bin/rm -f "${self_test_samples}"' EXIT
	printf 'elapsed_seconds,cpu_percent,rss_kib\n' >"${self_test_samples}"
	for elapsed_second in $(seq 0 "${measurement_duration_seconds}"); do
		printf '%s,%s,%s\n' "${elapsed_second}" "${elapsed_second}" "$((1000 + elapsed_second))" >>"${self_test_samples}"
	done
	observed_samples="$(tail -n +2 "${self_test_samples}" | wc -l | tr -d ' ')"
	observed_last_elapsed="$(tail -n 1 "${self_test_samples}" | cut -d, -f1)"
	observed_median="$(median_cpu_from_file "${self_test_samples}")"
	[[ ${observed_samples} == "301" && ${observed_last_elapsed} == "300" && ${observed_median} == "150.000" ]] || {
		echo "idle measurement self-test failed" >&2
		exit 1
	}
	echo "Idle measurement self-test passed: samples=301 interval_seconds=300 median=150.000."
	exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 /absolute/path/to/Release/ClipboardKeyboardMac.app [samples.csv]" >&2
	exit 64
fi

app_bundle="$1"
output_file="${2:-clipboard-keyboard-mac-idle.csv}"
[[ ${app_bundle} == /* && -d ${app_bundle} ]] || {
	echo "signed Release app bundle is required" >&2
	exit 65
}
[[ ${app_bundle} == *"/Release/"* ]] || {
	echo "app path must identify a Release build" >&2
	exit 65
}
codesign --verify --deep --strict "${app_bundle}" >/dev/null 2>&1 || {
	echo "app signature verification failed" >&2
	exit 65
}
signature_details="$(codesign -dvv "${app_bundle}" 2>&1)"
team_identifier="$(printf '%s\n' "${signature_details}" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
[[ -n ${team_identifier} && ${team_identifier} != "not set" ]] || {
	echo "a non-ad-hoc signed app is required" >&2
	exit 65
}

executable_name="$(plutil -extract CFBundleExecutable raw -o - "${app_bundle}/Contents/Info.plist")"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "${app_bundle}/Contents/Info.plist")"
[[ ${bundle_identifier} == "kr.donminzzi.clipboardkeyboard.mac" ]] || {
	echo "unexpected bundle identifier" >&2
	exit 65
}
executable_path="${app_bundle}/Contents/MacOS/${executable_name}"

matching_pids=()
while IFS= read -r candidate_pid; do
	[[ -n ${candidate_pid} ]] || continue
	candidate_executable="$(ps -p "${candidate_pid}" -o comm= 2>/dev/null || true)"
	[[ ${candidate_executable} == "${executable_path}" ]] && matching_pids+=("${candidate_pid}")
done < <(pgrep -x "${executable_name}" || true)
[[ ${#matching_pids[@]} -eq 1 ]] || {
	echo "run exactly one instance of the signed Release app before measuring" >&2
	exit 66
}
measured_pid="${matching_pids[0]}"

echo "Warming signed Release app for 60 seconds."
sleep 60
kill -0 "${measured_pid}" 2>/dev/null || {
	echo "app exited during warm-up" >&2
	exit 67
}

temporary_samples="$(mktemp "${TMPDIR:-/tmp}/clipboard-keyboard-idle.XXXXXX")"
trap '/bin/rm -f "${temporary_samples}"' EXIT
printf 'elapsed_seconds,cpu_percent,rss_kib\n' >"${temporary_samples}"
for elapsed_second in $(seq 0 "${measurement_duration_seconds}"); do
	sample_line=""
	if ! sample_line="$(ps -p "${measured_pid}" -o %cpu= -o rss=)"; then
		echo "app exited during measurement" >&2
		exit 67
	fi
	read -r cpu_percent rss_kib <<<"${sample_line}"
	[[ -n ${cpu_percent:-} && -n ${rss_kib:-} ]] || {
		echo "app exited during measurement" >&2
		exit 67
	}
	printf '%s,%s,%s\n' "${elapsed_second}" "${cpu_percent}" "${rss_kib}" >>"${temporary_samples}"
	[[ ${elapsed_second} -eq ${measurement_duration_seconds} ]] || sleep 1
done

cp "${temporary_samples}" "${output_file}"
median_cpu="$(median_cpu_from_file "${temporary_samples}")"
first_rss="$(sed -n '2s/.*,//p' "${temporary_samples}")"
last_rss="$(tail -n 1 "${temporary_samples}" | cut -d, -f3)"
rss_growth_mib="$(awk -v first="${first_rss}" -v last="${last_rss}" 'BEGIN { printf "%.3f", (last - first) / 1024 }')"
printf 'samples=%s interval_seconds=%s median_cpu_percent=%s rss_growth_mib=%s output=%s\n' "${sample_count}" "${measurement_duration_seconds}" "${median_cpu}" "${rss_growth_mib}" "${output_file}"
awk -v cpu="${median_cpu}" 'BEGIN { exit !(cpu < 1) }' || {
	echo "median CPU gate failed" >&2
	exit 1
}
awk -v growth="${rss_growth_mib}" 'BEGIN { exit !(growth <= 10) }' || {
	echo "resident-memory growth gate failed" >&2
	exit 1
}
