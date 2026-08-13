#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${repo_root}"

./scripts/generate-project.sh
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

xcrun simctl bootstatus "${simulator_id}" -b

simulator_destination="platform=iOS Simulator,id=${simulator_id}"
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardKeyboard -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardShare -destination "${simulator_destination}" CODE_SIGNING_ALLOWED=NO build test
