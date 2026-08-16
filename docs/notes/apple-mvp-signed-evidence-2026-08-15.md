# Apple MVP Signed Evidence

## Scope

This note records the first signed builds of the product and the manual gates observed against them.
It does not extend `apple-mvp-release-evidence.md`: that note is closed against unsigned candidate `be3b113` and states its configuration as unsigned Debug automation only.
The two are separate evidence classes on separate commits, and neither is edited into the other.

## Evidence Identity

| Field                | Recorded value                                                                                                                                       |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Evidence date        | 2026-08-15 Asia/Seoul                                                                                                                                |
| Commit               | `d3737c078bb6d8620476ebb517142789e205af2f`; tree `359aa00119a0e0e274cdcc80377fb0639a98fa94`                                                          |
| Development Mac      | Mac mini `Mac16,10`, Apple M4, 10 cores, 16 GB memory                                                                                                |
| macOS                | 26.5.2 build `25F84`                                                                                                                                 |
| Xcode                | 26.6 build `17F113`                                                                                                                                  |
| XcodeGen             | 2.46.0                                                                                                                                               |
| Configuration        | Signed Release, automatic provisioning                                                                                                               |
| Signing team         | `393JTTV68D`                                                                                                                                         |
| Signing identity     | `Apple Development: Dongmin Yu`, valid through 2027-07-08                                                                                            |
| Registered devices   | Mac mini `00008132-001649522605001C`; iPhone 16 Pro `00008140-001938282206801C`                                                                      |
| CloudKit environment | \[PARTIAL\] The private container exists and its Development environment shows prior traffic, but this run started no session and mutated no record. |
| Physical iPhone run  | \[PARTIAL\] No build was installed on the device during this run.                                                                                    |

Signed build success and signed runtime observation are separate evidence classes.
A build that archives says nothing about how the product behaves once running.

## Signed Build Gates

| Gate                                 | Status | Evidence                                                                                                                                                                         |
| ------------------------------------ | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS Release archive                | PASS   | `xcodebuild archive` for `ClipboardKeyboardMac` reported `ARCHIVE SUCCEEDED`, signed with the team identity above and a `Mac Team Provisioning Profile` created on demand.       |
| iPhone Release archive               | PASS   | `xcodebuild archive` for `ClipboardKeyboardiOS` reported `ARCHIVE SUCCEEDED` with no asset-catalog warnings once the targets declared `TARGETED_DEVICE_FAMILY = 1`.              |
| Extension provisioning               | PASS   | The iPhone build resolved three distinct profiles — `…ios`, `…ios.keyboard`, `…ios.share` — each signed with the same development identity.                                      |
| Application icon compilation         | PASS   | actool compiled both catalogs, emplacing `AppIcon60x60@2x.png` into the iPhone bundle and generating `AppIcon.icns` into the macOS bundle from the per-size PNGs.                |
| Unsigned verifier on the same commit | PASS   | `./scripts/verify.sh` exited 0 on merged `main`: ClipboardCore 76/76, macOS 157/157, iPhone 193/193, keyboard 22/22, Share 31/31, security audit passed, Trunk clean on 168/194. |

## Signed macOS Runtime Gates

| Manual gate                     | Status | Observation or blocker                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Five-minute idle CPU and memory | PASS   | `./scripts/measure-mac-idle.sh` against the signed Release bundle: 301 samples over 300 seconds after a 60-second warm-up, median CPU `0.000`%, resident memory `62,784` KiB to `39,168` KiB for growth of `-23.062` MiB. The highest single CPU sample was 1.2%. Samples in `DerivedData/mac-idle-samples.csv`, SHA-256 `ab0fddde44022b951009c30b51d79b49d938b5eb1e3dea9f64c8d6ed5b367518`. |

Every other manual gate in `apple-mvp-release-evidence.md` remains unobserved.
The blockers are unchanged in kind: they need live pasteboard observation, a physical-device install, two devices against one CloudKit environment, or instrumentation, none of which this run performed.

## Release Decision

Release remains \[PARTIAL\].
Signed builds now exist, which removes the blocker every manual gate cited, but removing a blocker is not the same as observing a gate.
One of the 39 manual gates carries a measurement; the other 38 are still open.
