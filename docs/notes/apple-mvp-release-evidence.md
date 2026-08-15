# Apple MVP Release Evidence

## Evidence Identity

| Field                      | Recorded value                                                                                                                                                                                       |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Evidence date              | 2026-08-15 Asia/Seoul                                                                                                                                                                                |
| Verified candidate commit  | `be3b1131fa59d4801c3b1a2992c85215319578ba`; tree `24537f8197b14abeea363cca69151eea53186d41`.                                                                                                         |
| Verifier artifact          | Local raw log `.superpowers/sdd/2026-08-13-clipboard-keyboard-apple-mvp-implementation/task-15-head-be3b113-verify.log`; SHA-256 `d742ecb4fc21df10536eeaf70e912ad721a1e362d2da9b627a1f40f3fe3d5736`. |
| Development Mac            | Mac mini `Mac16,10`, Apple M4, 10 cores, 16 GB memory                                                                                                                                                |
| macOS                      | 26.5.2 build `25F84`                                                                                                                                                                                 |
| Xcode                      | 26.6 build `17F113`                                                                                                                                                                                  |
| XcodeGen                   | 2.46.0                                                                                                                                                                                               |
| Trunk                      | 1.25.0                                                                                                                                                                                               |
| Configuration              | \[PARTIAL\] Unsigned Debug automation only; no signed Release app was available.                                                                                                                     |
| macOS bundle identifier    | `kr.donminzzi.clipboardkeyboard.mac`                                                                                                                                                                 |
| iPhone bundle identifier   | `kr.donminzzi.clipboardkeyboard.ios`                                                                                                                                                                 |
| Keyboard bundle identifier | `kr.donminzzi.clipboardkeyboard.ios.keyboard`                                                                                                                                                        |
| Share bundle identifier    | `kr.donminzzi.clipboardkeyboard.ios.share`                                                                                                                                                           |
| App Group                  | `group.kr.donminzzi.clipboardkeyboard`                                                                                                                                                               |
| CloudKit container         | `iCloud.kr.donminzzi.clipboardkeyboard`                                                                                                                                                              |
| Signing team               | \[PARTIAL\] No local signed Release configuration was available.                                                                                                                                     |
| Physical iPhone            | \[PARTIAL\] No signed physical-device run was authorized or available.                                                                                                                               |
| CloudKit environment       | \[PARTIAL\] No live development or production container was selected or mutated.                                                                                                                     |

Static audit, deterministic automated measurements, and signed runtime observations are separate evidence classes.
One class never implies another.

## Automated Local Evidence

| Gate                                     | Status | Evidence                                                                                                                                                                                                                                                                                                                            |
| ---------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deterministic search fixtures            | PASS   | `swift scripts/generate-search-fixtures.swift` used seeded variation to produce 5,000 records and 6 versioned queries; two consecutive combined SHA-256 calculations matched at `9ecbfc02f3c2f44b1dd8f9acd17150a0884af03115610282cebec77bec5725a3`.                                                                                 |
| Search correctness and timing collection | PASS   | `MacSearchPerformanceTests` loads all 5,000 records, validates every versioned query, and attaches query-to-first-result samples without treating one Debug sample as the signed Release threshold.                                                                                                                                 |
| Fail-closed privacy boundaries           | PASS   | The five Task 15 integration classes directly cover Keychain denial, corrupt encrypted record/store, disk full, zero unpinned CloudKit writes, locked/corrupt App Group reads, protected-data memory purge, Share partial cleanup, and the original privacy/insertion boundaries with immediate-failure spies.                      |
| Idle sampler interval and median         | PASS   | `./scripts/measure-mac-idle.sh --self-test` validates 301 samples from `t=0` through `t=300`, a full 300-second interval, and the 151st sorted sample as the median without starting a signed runtime measurement.                                                                                                                  |
| Large input correctness                  | PASS   | Automated direct resolution covers 524,287, 524,288, 524,289, and 1,048,576 bytes without truncation; signed end-to-end runtime behavior remains separate below.                                                                                                                                                                    |
| Source and entitlement audit             | PASS   | `./scripts/security-audit.sh` passed against generated property lists and tracked source; negative fixtures must also remain part of the task report.                                                                                                                                                                               |
| Full unsigned verifier                   | PASS   | `./scripts/verify.sh` completed with exit 0 on verified candidate `be3b113`: ClipboardCore 76/76, macOS 157/157, iOS 193/193, Keyboard 22/22, and Share 31/31; the security audit passed, Trunk formatting checked 163 files, and Trunk lint checked 172 files with no issues. The raw artifact path and digest are recorded above. |

## Signed macOS Runtime Gates

| Manual gate                                        | Status      | Observation or blocker                                                                                                                                                                  |
| -------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Confidential markers for every supported text type | \[PARTIAL\] | No signed Release app was available for live pasteboard observation.                                                                                                                    |
| Best-effort ignored application                    | \[PARTIAL\] | No signed Release app and verified ignored application identity were available.                                                                                                         |
| Background-helper limitation                       | \[PARTIAL\] | Requires a signed Release app and an application whose foreground identity differs from the copy source.                                                                                |
| Private Copy success and 60-second pause           | \[PARTIAL\] | Requires a signed Release Services registration and live pasteboard observation.                                                                                                        |
| Private Copy conflict fallback                     | \[PARTIAL\] | Requires a signed Release Services registration and injected pasteboard conflict.                                                                                                       |
| Immediate application-switch race                  | \[PARTIAL\] | Requires a signed Release app and timestamped foreground switching during a live copy.                                                                                                  |
| Plain Text byte round trip                         | \[PARTIAL\] | Requires a signed Release app and live pasteboard bytes.                                                                                                                                |
| RTF byte round trip                                | \[PARTIAL\] | Requires a signed Release app and live pasteboard bytes.                                                                                                                                |
| HTML byte round trip                               | \[PARTIAL\] | Requires a signed Release app and live pasteboard bytes.                                                                                                                                |
| Progressively large text                           | \[PARTIAL\] | Automated resolution proves no truncation through 1,048,576 bytes, but no signed end-to-end capture run was executed.                                                                   |
| Five-minute idle CPU and memory                    | \[PARTIAL\] | `scripts/measure-mac-idle.sh` requires exactly one non-ad-hoc signed Release app, a 60-second warm-up, and 301 samples spanning `t=0` through `t=300`; no qualifying app was available. |
| Search p95 at or below 150 ms                      | \[PARTIAL\] | Requires the signed Release app, 60-second warm-up, recorded samples, and hardware-tied p95 calculation.                                                                                |

## Signed Cross-Device and CloudKit Gates

| Manual gate                                    | Status      | Observation or blocker                                                                               |
| ---------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------- |
| Plain Text bidirectional pin and delete        | \[PARTIAL\] | Requires signed macOS and physical iPhone apps connected to a selected private CloudKit environment. |
| Markdown bidirectional pin and delete          | \[PARTIAL\] | Same signed two-device and CloudKit blocker.                                                         |
| RTF bidirectional pin and delete               | \[PARTIAL\] | Same signed two-device and CloudKit blocker.                                                         |
| HTML bidirectional pin and delete              | \[PARTIAL\] | Same signed two-device and CloudKit blocker.                                                         |
| 524,288-byte encrypted asset boundary          | \[PARTIAL\] | No signed two-device CloudKit transfer was executed.                                                 |
| 524,289-byte encrypted asset boundary          | \[PARTIAL\] | No signed two-device CloudKit transfer was executed.                                                 |
| Sync disable                                   | \[PARTIAL\] | No signed CloudKit session was started.                                                              |
| Delete Cloud Data with stale device            | \[PARTIAL\] | Destructive live CloudKit deletion was explicitly prohibited and was not executed.                   |
| Stale device reconnect after deletion          | \[PARTIAL\] | Depends on the prohibited destructive live CloudKit deletion.                                        |
| Live CloudKit zero writes for unpinned content | \[PARTIAL\] | No live CloudKit mutation or server-side record inspection was authorized.                           |

## Signed iPhone, Share, and App Intent Gates

| Manual gate                          | Status      | Observation or blocker                                                                                                         |
| ------------------------------------ | ----------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Plain Text import, export, and share | \[PARTIAL\] | Requires a signed physical-device run and Files/Share UI observation.                                                          |
| Markdown import, export, and share   | \[PARTIAL\] | Requires a signed physical-device run and Files/Share UI observation.                                                          |
| RTF import, export, and share        | \[PARTIAL\] | Requires a signed physical-device run and Files/Share UI observation.                                                          |
| HTML import, export, and share       | \[PARTIAL\] | Requires a signed physical-device run and Files/Share UI observation.                                                          |
| Share partial write and cleanup      | \[PARTIAL\] | Automated injected failure is covered, but protected-storage behavior requires a signed locked-device run.                     |
| App Intents locked errors            | \[PARTIAL\] | Automated locked dependency behavior is covered, but local authentication and lock state require a signed physical-device run. |
| Korean negative account candidates   | \[PARTIAL\] | Deterministic fixtures exist in package tests; signed UI presentation was not observed.                                        |

## Signed Keyboard Gates

| Manual gate                                           | Status      | Observation or blocker                                                                                                                      |
| ----------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Full Access disabled                                  | \[PARTIAL\] | Generated plist and static audit show `RequestsOpenAccess=false`; Settings UI confirmation requires a signed physical-device install.       |
| Network unavailable                                   | \[PARTIAL\] | Static extension audit finds no networking API or entitlement; runtime confirmation requires a signed physical-device install.              |
| Device lock and unlock                                | \[PARTIAL\] | Requires a signed physical-device run with protected data transitions.                                                                      |
| Corrupt snapshot                                      | \[PARTIAL\] | Automated fail-closed behavior is covered; signed App Group file injection was not performed.                                               |
| Stale-but-valid snapshot                              | \[PARTIAL\] | Automated refresh recommendation is covered; signed App Group observation was not performed.                                                |
| Multiline, Unicode, emoji, and exact code indentation | \[PARTIAL\] | Automated insertion closure preserves exact strings; host application behavior requires a signed keyboard.                                  |
| Time to first interactive content                     | \[PARTIAL\] | Requires timestamped signed physical-device video or instrumentation.                                                                       |
| Peak resident memory                                  | \[PARTIAL\] | Requires a signed physical-device Instruments or OS memory observation.                                                                     |
| Secure-field keyboard substitution                    | \[PARTIAL\] | Requires a signed physical-device host field; substitution is platform behavior, not a product defect.                                      |
| Phone-pad keyboard substitution                       | \[PARTIAL\] | Requires a signed physical-device phone-pad field; substitution is platform behavior, not a product defect.                                 |
| Host rejects third-party keyboard                     | \[PARTIAL\] | Requires a signed physical-device host known to reject third-party keyboards; rejection is platform or host behavior, not a product defect. |

## Release Decision

The unsigned automated layer does not authorize publishing or release.
Release remains \[PARTIAL\] until every required signed/manual row is either observed with concrete evidence or explicitly accepted as a release gap by the operator.
