#!/bin/bash
set -euo pipefail

repo_root="${CLIPBOARD_KEYBOARD_AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "${repo_root}"

fail() {
	echo "security audit failed: $*" >&2
	exit 1
}

forbid_matches() {
	local description="$1"
	local pattern="$2"
	shift 2
	local matches=""
	local command_exit=0
	set +e
	matches="$(rg -n --glob '*.swift' "${pattern}" "$@")"
	command_exit=$?
	set -e
	if [[ ${command_exit} -eq 0 ]]; then
		printf '%s\n' "${matches}" >&2
		fail "${description}"
	fi
	if [[ ${command_exit} -ne 1 ]]; then
		fail "could not inspect ${description}"
	fi
}

production_swift_paths=(Apps Extensions Packages/ClipboardCore/Sources)
forbid_matches "content-capable console logging is present" '(^|[^[:alnum:]_])(print|debugPrint|dump)[[:space:]]*\(|\b(Logger|os_log)[[:space:]\.(]' "${production_swift_paths[@]}"

iphone_source_paths=(Apps/iOS)
iphone_pasteboard_matches="$(rg -n --glob '*.swift' --glob '!Apps/iOS/Infrastructure/Pasteboard/SystemPasteboardWriter.swift' 'UIPasteboard' "${iphone_source_paths[@]}" || true)"
[[ -z ${iphone_pasteboard_matches} ]] || {
	printf '%s\n' "${iphone_pasteboard_matches}" >&2
	fail "iPhone pasteboard access exists outside SystemPasteboardWriter"
}

writer_file="Apps/iOS/Infrastructure/Pasteboard/SystemPasteboardWriter.swift"
[[ -f ${writer_file} ]] || fail "SystemPasteboardWriter is missing"
writer_access_count="$(rg -c 'UIPasteboard\.general\.string[[:space:]]*=' "${writer_file}" || true)"
[[ ${writer_access_count} == "1" ]] || fail "SystemPasteboardWriter must contain exactly one write-only pasteboard assignment"
writer_reference_count="$(rg -c 'UIPasteboard' "${writer_file}" || true)"
[[ ${writer_reference_count} == "1" ]] || fail "SystemPasteboardWriter contains a pasteboard read or an additional API access"

forbid_matches "keyboard pasteboard API is present" 'UIPasteboard|NSPasteboard|pasteboard' Extensions/Keyboard
forbid_matches "extension CloudKit or networking API is present" '(^|[^[:alnum:]_])(import[[:space:]]+(CloudKit|Network|CFNetwork)|CK[A-Z][[:alnum:]_]*|NSURLConnection|URL(Request|Session|Protocol)|URLSessionWebSocketTask|webSocketTask|NW(Connection|Listener|PathMonitor)|CF(HTTP|Network|Host|NetService|ReadStreamCreateForHTTP|SocketStream)[A-Za-z0-9_]*)\b|URL[[:space:]]*\([[:space:]]*string:[[:space:]]*"https?://|((Data|NSData)[[:space:]]*\([[:space:]]*contentsOf:[^\n]*URL[[:space:]]*\([[:space:]]*string:)' Extensions
forbid_matches "keyboard pasteboard write API is present" '\.(setData|setString|setItems)[[:space:]]*\(' Extensions/Keyboard

keyboard_info="ClipboardKeyboard.xcodeproj/Generated/ClipboardKeyboardKeyboard-Info.plist"
[[ -f ${keyboard_info} ]] || fail "generated keyboard Info.plist is missing; run scripts/generate-project.sh first"
open_access="$(plutil -extract NSExtension.NSExtensionAttributes.RequestsOpenAccess raw -o - "${keyboard_info}" 2>/dev/null || true)"
[[ ${open_access} == "false" ]] || fail "RequestsOpenAccess is not false"

for entitlement in Extensions/Keyboard/ClipboardKeyboardKeyboard.entitlements Extensions/Share/ClipboardKeyboardShare.entitlements; do
	[[ -f ${entitlement} ]] || fail "missing entitlement file ${entitlement}"
	for forbidden_key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services aps-environment; do
		escaped_key="${forbidden_key//./\\.}"
		if plutil -extract "${escaped_key}" raw -o - "${entitlement}" >/dev/null 2>&1; then
			fail "${entitlement} contains forbidden ${forbidden_key} entitlement"
		fi
	done
	app_group="$(plutil -extract 'com\.apple\.security\.application-groups.0' raw -o - "${entitlement}" 2>/dev/null || true)"
	[[ ${app_group} == "group.kr.donminzzi.clipboardkeyboard" ]] || fail "${entitlement} lacks the exact App Group"
done

tracked_signing_paths=(project.yml Config/Base.xcconfig Config/Debug.xcconfig Config/Release.xcconfig Config/Signing.xcconfig)
if rg -n 'DEVELOPMENT_TEAM[[:space:]]*[:=][[:space:]]*[A-Z0-9]+' "${tracked_signing_paths[@]}" >/dev/null; then
	fail "a signing team is committed"
fi

rg -q 'operations\.protection\(url\)[^\n]*== \.complete' Apps/iOS/Infrastructure/Snapshot/KeyboardSnapshotPublisher.swift || fail "snapshot publisher lacks a complete-protection check"
rg -q '\.complete' Extensions/Keyboard/KeyboardSnapshotReader.swift || fail "snapshot reader lacks a complete-protection check"
rg -q 'FileProtectionType\.complete' Extensions/Share/ShareInboxWriter.swift || fail "Share inbox writer lacks a complete-protection check"

echo "Security audit passed."
