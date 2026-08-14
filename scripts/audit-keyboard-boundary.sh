#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
keyboard_sources="${repo_root}/Extensions/Keyboard"
keyboard_info="${repo_root}/ClipboardKeyboard.xcodeproj/Generated/ClipboardKeyboardKeyboard-Info.plist"
keyboard_entitlements="${repo_root}/Extensions/Keyboard/ClipboardKeyboardKeyboard.entitlements"
app_entitlements="${repo_root}/Apps/iOS/ClipboardKeyboardiOS.entitlements"
app_group='["group.kr.donminzzi.clipboardkeyboard"]'

forbidden_pattern='URLSession|Network|CloudKit|CKContainer|UIPasteboard|FileHandle[^[:cntrl:]]*(forWriting|forUpdating)|Data\.write|\.write\(to:'
if rg -n --glob '*.swift' "${forbidden_pattern}" "${keyboard_sources}"; then
	echo "keyboard boundary audit failed: forbidden API found" >&2
	exit 1
fi

mutation_pattern='\b(createFile|createDirectory|removeItem|moveItem|copyItem|replaceItem|setAttributes)[[:space:]]*\('
if rg -n --glob '*.swift' "${mutation_pattern}" "${keyboard_sources}"; then
	echo "keyboard boundary audit failed: filesystem mutation found" >&2
	exit 1
fi

file_manager_occurrences="$(rg -n --glob '*.swift' 'FileManager' "${keyboard_sources}" || true)"
unexpected_file_manager="$(printf '%s\n' "${file_manager_occurrences}" | rg -v 'FileManager\.default\.(containerURL|fileExists|attributesOfItem)' || true)"
if [[ -n ${unexpected_file_manager} ]]; then
	printf '%s\n' "${unexpected_file_manager}" >&2
	echo "keyboard boundary audit failed: only exact read-only FileManager.default calls are allowed" >&2
	exit 1
fi

requests_open_access="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:RequestsOpenAccess' "${keyboard_info}")"
if [[ ${requests_open_access} != "false" ]]; then
	echo "keyboard boundary audit failed: RequestsOpenAccess must be false" >&2
	exit 1
fi

for entitlement_file in "${keyboard_entitlements}" "${app_entitlements}"; do
	groups="$(plutil -extract 'com\.apple\.security\.application-groups' json -o - "${entitlement_file}")"
	if [[ ${groups} != "${app_group}" ]]; then
		echo "keyboard boundary audit failed: unexpected App Group in ${entitlement_file}" >&2
		exit 1
	fi
done

for forbidden_key in com.apple.developer.icloud-container-identifiers com.apple.developer.ubiquity-container-identifiers aps-environment; do
	if /usr/libexec/PlistBuddy -c "Print :${forbidden_key}" "${keyboard_entitlements}" >/dev/null 2>&1; then
		echo "keyboard boundary audit failed: forbidden entitlement ${forbidden_key}" >&2
		exit 1
	fi
done

echo "keyboard boundary audit passed"
