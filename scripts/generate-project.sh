#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
required_version="$(tr -d '[:space:]' <"${repo_root}/.xcodegen-version")"

if ! command -v xcodegen >/dev/null 2>&1; then
	echo "xcodegen ${required_version} is required" >&2
	exit 1
fi

actual_version="$(xcodegen --version | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
if [[ ${actual_version} != "${required_version}" ]]; then
	echo "expected xcodegen ${required_version}, found ${actual_version}" >&2
	exit 1
fi

cd "${repo_root}"
xcodegen generate --spec project.yml
