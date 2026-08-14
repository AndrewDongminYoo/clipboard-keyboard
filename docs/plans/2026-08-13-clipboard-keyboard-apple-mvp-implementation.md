# Clipboard Keyboard Apple MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the approved Apple MVP as a native macOS menu bar app, native iPhone app, Full-Access-free iOS keyboard extension, and explicit Share extension that retain unpinned history only on the Mac and synchronize only user-pinned content.

**Architecture:** A Foundation-only local Swift package owns immutable content models, privacy and retention policies, deterministic transformations, search, extraction, snapshot schemas, and pinned-replica state machines.
The macOS and iOS targets own their AppKit, UIKit, SwiftUI, Keychain, filesystem, App Group, App Intents, and CloudKit adapters, while the keyboard reads a protected versioned snapshot and never writes shared state or uses the network.

**Tech Stack:** Swift 6, SwiftUI, AppKit, UIKit, Foundation, CryptoKit, Security, CloudKit with `CKSyncEngine`, App Intents, Uniform Type Identifiers, ServiceManagement, LocalAuthentication, XCTest, XcodeGen, and Trunk.

## Global Constraints

- The product and security source of truth is `docs/specs/2026-08-13-clipboard-keyboard-design.md` at SHA-256 `9f79a68c47083e1ef486bbe4f6b335f0ed00cf6cb51890d9ba89eaf6f760f655`.
- Keep the deployment floors at iOS 17 and macOS 14.
- Use native Swift targets only for the Apple MVP.
- Keep the shared `ClipboardCore` package free of AppKit, UIKit, SwiftUI, CloudKit, Keychain, and App Group APIs.
- Use Swift 6 language mode with complete strict concurrency checking.
- Add no third-party runtime dependency.
- Use XcodeGen `2.46.0` as a development-only dependency because the empty repository needs one reproducible source of truth for four Apple targets, test targets, capabilities, and schemes.
- Track `project.yml` and ignore the generated `ClipboardKeyboard.xcodeproj`; always change `project.yml` first and regenerate.
- The operator confirmed availability and selected the bundle namespace `kr.donminzzi.clipboardkeyboard`, the App Group `group.kr.donminzzi.clipboardkeyboard`, and the CloudKit container `iCloud.kr.donminzzi.clipboardkeyboard` on 2026-08-14.
- Treat the confirmed identifiers as the explicit implementation namespace selected by the operator on 2026-08-14.
- Keep `DEVELOPMENT_TEAM` out of Git.
- Default builds and tests must work with `CODE_SIGNING_ALLOWED=NO`; physical-device, App Group, Services, and CloudKit checks require a local signing configuration supplied by the operator.
- Automatic Mac capture and iCloud synchronization both start disabled until explicit consent.
- Store unpinned Mac history for at most 24 hours or 200 items by default, whichever limit is reached first.
- Synchronize only explicit pinned revisions and content-free deletion or reset state.
- Keep `RequestsOpenAccess` set to `false` for the keyboard for every configuration.
- Do not impose a character-count limit and never persist a truncated representation as complete.
- Run only one heavy Apple job at a time, including Simulator boot, `xcodebuild`, archive, and device deployment.
- Run Trunk in read-only mode first with explicit paths: `trunk fmt --no-fix --diff=full <paths>` and `trunk check --no-fix <paths>`.
- Do not run a formatter or rewriter against the repository root without an explicit path list.
- Do not put clipboard bytes, previews, titles, queries, extracted values, or imported filenames in production logs, production assertions, UI snapshots, or crash metadata.
- Automated tests may use synthetic sentinel content but must never use or retain real clipboard data.
- Every task ends with a focused test run, an explicit-path quality gate, a staged-diff review, and one conventional commit.
- The root agent owns staging and commits; implementation workers must not stage, commit, or edit outside their assigned paths.

## Verified Planning Baseline

- Repository root: `/Volumes/dongminyu/Development/01_personal/clipboard-keyboard`.
- Planning baseline commit: `85713d2d9d005573fc592dcadc38aae1a51c0af5`.
- Toolchain observed on 2026-08-13: Xcode 26.6 build `17F113`, Swift 6.3.3, macOS SDK 26.5, iOS SDK 26.5, and one available iPhone 17 Pro Max simulator running iOS 26.5.
- XcodeGen is not installed at planning time; install version `2.46.0` before Task 1 and verify it through `.xcodegen-version`.
- Trunk is installed at `/usr/local/bin/trunk`; repository configuration does not exist yet.
- No Git remote is configured.
- The personal Apple Developer team identifier and capability registration state are \[UNKNOWN\]; unsigned and simulator work must proceed independently of that external gate.

## Delivery Checkpoints

1. Tasks 1-4 produce a reproducible multi-target shell and a fully tested domain package without reading a real clipboard or contacting iCloud.
2. Tasks 5-7 produce a useful local-only macOS product with encrypted rotating history, search, pause, application filters, and Private Copy.
3. Tasks 8-12 produce the local iPhone library, extraction and file workflows, protected keyboard snapshot, Share intake, and authenticated App Intents without CloudKit.
4. Tasks 13-14 add pinned-only private CloudKit synchronization, large encrypted assets, conflicts, tombstones, and reset behavior.
5. Task 15 closes security, integration, performance, documentation, and manual release gates.

Do not start a later checkpoint until every automated check in the prior checkpoint passes and its staged diff has been reviewed.

## Scope Exclusions

- Do not add automatic paste or Accessibility permission.
- Do not add a custom cross-device relay or synchronize unpinned history.
- Do not monitor the iPhone clipboard in the background.
- Do not add image, RTFD, arbitrary-file, OCR, or media history.
- Do not add AI classification, semantic search, or user-authored transformation scripts.
- Do not add a complete library backup archive.
- Do not add Android, team libraries, or shared CloudKit databases.
- Do not market unconditional end-to-end encryption or guaranteed source-application attribution.

## Implementation References

- [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/2.46.0/Docs/ProjectSpec.md) for `project.yml` target, property-list, entitlement, and scheme syntax.
- [Apple Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html) for the uppercase `NSKeyEquivalent` and `NSServices` contract.
- [Apple custom-keyboard open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) for the `RequestsOpenAccess=false` boundary.
- [Apple App Intent authentication policy](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requireslocaldeviceauthentication) for all three authenticated actions.
- [Apple `CKSyncEngine`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) for private-database synchronization, serialized state, pending changes, and delegate ordering.
- [Apple encrypted CloudKit fields](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues) and [Apple `CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset) for inline encrypted fields and large encrypted assets.

## File Responsibility Map

| Path                                     | Responsibility                                                                                                                          |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `project.yml`                            | Source of truth for app, extension, test targets, schemes, build settings, generated property lists, and target dependencies            |
| `Config/*.xcconfig`                      | Shared Swift, deployment, warning, and configuration settings without a committed team identifier                                       |
| `Packages/ClipboardCore/`                | Platform-independent models, policies, transformations, extraction, search, snapshot schemas, repository ports, and sync state machines |
| `Apps/macOS/App/`                        | macOS lifecycle, dependency composition, menu bar item, and app-visible state                                                           |
| `Apps/macOS/Features/`                   | Palette, settings, onboarding, explicit save, pause, pin, import, export, and deletion UI                                               |
| `Apps/macOS/Infrastructure/Pasteboard/`  | Pasteboard metadata reads, delayed payload reads, source-confidence tracking, watcher, and capture coordinator                          |
| `Apps/macOS/Infrastructure/Content/`     | AppKit-owned RTF text projection after the Privacy Gate                                                                                 |
| `Apps/macOS/Infrastructure/Persistence/` | Keychain master key, authenticated encryption, encrypted local files, retention, and memory-only search index                           |
| `Apps/macOS/Infrastructure/CloudKit/`    | macOS-owned private-database `CKSyncEngine` adapter and record codec                                                                    |
| `Apps/macOS/Services/`                   | Private Copy Service and global palette shortcut                                                                                        |
| `Apps/iOS/App/`                          | iPhone lifecycle and dependency composition                                                                                             |
| `Apps/iOS/Features/`                     | Library, Extract, Settings, import, export, share, sync, deletion, and reset UI                                                         |
| `Apps/iOS/Infrastructure/Persistence/`   | Keychain-backed protected pinned working set                                                                                            |
| `Apps/iOS/Infrastructure/Content/`       | UIKit-owned RTF text projection for explicit import                                                                                     |
| `Apps/iOS/Infrastructure/Pasteboard/`    | The single explicit write-only containing-app pasteboard adapter                                                                        |
| `Apps/iOS/Infrastructure/Snapshot/`      | Atomic `NSFileProtectionComplete` keyboard snapshot publication                                                                         |
| `Apps/iOS/Infrastructure/Share/`         | Share inbox consumption, validation, commit, and cleanup                                                                                |
| `Apps/iOS/Infrastructure/CloudKit/`      | iPhone-owned private-database `CKSyncEngine` adapter and record codec                                                                   |
| `Apps/iOS/Intents/`                      | `PinTextIntent`, `ExtractValuesIntent`, `FindPinnedIntent`, and App Shortcuts registration                                              |
| `Extensions/Keyboard/`                   | Read-only snapshot loader, local search UI, and `UITextDocumentProxy` insertion                                                         |
| `Extensions/Share/`                      | Explicit one-item text or URL preview, Pin decision, protected inbox write, and terminal cleanup                                        |
| `Tests/`                                 | Target-level tests and spies for Apple-framework adapters                                                                               |
| `scripts/`                               | Project generation, full verification, security source scans, and deterministic performance-fixture generation                          |
| `docs/notes/`                            | Manual release evidence tied to a commit, hardware, operating-system build, and test configuration                                      |

---

### Task 1: Bootstrap the Reproducible Apple Workspace and Quality Gate

**Files:**

- Create: `.gitignore`
- Create: `.xcodegen-version`
- Create: `AGENTS.md`
- Create: `README.md`
- Create: `project.yml`
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`
- Create: `Config/Signing.xcconfig`
- Create: `scripts/generate-project.sh`
- Create: `scripts/verify.sh`
- Create: `Packages/ClipboardCore/Package.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/ClipboardCore.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/ClipboardCoreSmokeTests.swift`
- Create: `Apps/macOS/App/ClipboardKeyboardMacApp.swift`
- Create: `Apps/macOS/App/MacAppDelegate.swift`
- Create: `Apps/iOS/App/ClipboardKeyboardApp.swift`
- Create: `Extensions/Keyboard/KeyboardViewController.swift`
- Create: `Extensions/Share/ShareViewController.swift`
- Create: `Tests/macOS/MacTargetSmokeTests.swift`
- Create: `Tests/iOS/PhoneTargetSmokeTests.swift`
- Create: `Tests/Keyboard/KeyboardTargetSmokeTests.swift`
- Create: `Tests/Share/ShareTargetSmokeTests.swift`
- Create through `setup-trunk`: `.trunk/trunk.yaml` and only the supporting files selected by that skill

**Interfaces:**

- Produces: Xcode schemes `ClipboardKeyboardMac`, `ClipboardKeyboardiOS`, `ClipboardKeyboardKeyboard`, and `ClipboardKeyboardShare` with test bundles `ClipboardKeyboardMacTests`, `ClipboardKeyboardiOSTests`, `ClipboardKeyboardKeyboardTests`, and `ClipboardKeyboardShareTests`.
- Produces: Swift package product `ClipboardCore`.
- Produces: `scripts/generate-project.sh`, which rejects a missing or wrong XcodeGen version and then generates `ClipboardKeyboard.xcodeproj` from `project.yml`.
- Produces: `scripts/verify.sh`, which runs package tests and target tests sequentially with `CODE_SIGNING_ALLOWED=NO`.
- Consumes: no application code from later tasks.

- [ ] **Step 1: Prove the bootstrap is absent before creating it**

Run:

```bash
test ! -e project.yml
test ! -e Packages/ClipboardCore/Package.swift
test ! -e ClipboardKeyboard.xcodeproj
```

Expected: all three checks exit `0` on the planning baseline.

- [ ] **Step 2: Record and validate the development-only generator version**

Write exactly `2.46.0` followed by a newline to `.xcodegen-version`.
Implement `scripts/generate-project.sh` around this contract:

```bash
#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
required_version="$(tr -d '[:space:]' < "$repo_root/.xcodegen-version")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen $required_version is required" >&2
  exit 1
fi

actual_version="$(xcodegen --version | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
if [ "$actual_version" != "$required_version" ]; then
  echo "expected xcodegen $required_version, found $actual_version" >&2
  exit 1
fi

cd "$repo_root"
xcodegen generate --spec project.yml
```

Install XcodeGen outside the repository with `brew install xcodegen`, then run `xcodegen --version` and require `2.46.0` before continuing.

- [ ] **Step 3: Create the package and four minimal compilable targets**

Set the shared build configuration to:

```xcconfig
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_TREAT_WARNINGS_AS_ERRORS = YES
CLANG_WARN_DOCUMENTATION_COMMENTS = YES
MACOSX_DEPLOYMENT_TARGET = 14.0
IPHONEOS_DEPLOYMENT_TARGET = 17.0
```

Define all four products and four test bundles in `project.yml`.
Use these exact product bundle identifiers:

```yaml
ClipboardKeyboardMac: kr.donminzzi.clipboardkeyboard.mac
ClipboardKeyboardiOS: kr.donminzzi.clipboardkeyboard.ios
ClipboardKeyboardKeyboard: kr.donminzzi.clipboardkeyboard.ios.keyboard
ClipboardKeyboardShare: kr.donminzzi.clipboardkeyboard.ios.share
```

Embed the keyboard and Share extensions in `ClipboardKeyboardiOS`, link `ClipboardCore` into every product, generate property lists from `project.yml`, and leave CloudKit and App Group entitlements out until their owning tasks.
Set the keyboard extension point and explicitly set `RequestsOpenAccess` to `false` from the first generated build.
Set the Share extension point with `NSExtensionActivationRule` equal to `FALSEPREDICATE` until Task 11 supplies its explicit text and URL rule.
Make `Config/Signing.xcconfig` contain only `#include? "Signing.local.xcconfig"`, reference it from the tracked configuration chain, and ignore `Config/Signing.local.xcconfig`.
Keep each app entry point to a visible text label and each extension entry point to a compiling empty controller.
Give `README.md` the sections Product Boundary, Prerequisites, Generate, Verify, Local Signing, and Source of Truth.
Give repository-local `AGENTS.md` only the project-specific rules to regenerate from `project.yml`, preserve the privacy-before-read boundary, keep the keyboard read-only and Full-Access-free, run one heavy Apple job at a time, and execute `./scripts/verify.sh` before completion.

- [ ] **Step 4: Generate and run the baseline build matrix sequentially**

Run:

```bash
./scripts/generate-project.sh
swift test --package-path Packages/ClipboardCore
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardKeyboard -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardShare -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO build test
```

Expected: package tests and all four target test bundles pass with zero warnings.
If the verified simulator model is no longer installed, run `xcrun simctl list devices available`, select one exact available iPhone, and update only `scripts/verify.sh`; do not change deployment targets.

- [ ] **Step 5: Initialize the repository quality gate with the dedicated skill**

Invoke `setup-trunk` for this repository.
Enable only linters that can inspect the present Swift, YAML, Markdown, shell, secrets, and repository files without adding a runtime dependency.
Run mutation-free checks first and review every proposed config file before accepting it.

Run:

```bash
trunk fmt --no-fix --diff=full project.yml Config/*.xcconfig README.md AGENTS.md scripts/generate-project.sh scripts/verify.sh
trunk check --no-fix project.yml Config/*.xcconfig README.md AGENTS.md scripts/generate-project.sh scripts/verify.sh Packages/ClipboardCore Apps/macOS Apps/iOS Extensions Tests
```

Expected: no formatter diff and no linter finding.

- [ ] **Step 6: Verify generated-state discipline and commit**

After the first generation, hash every file path and byte sequence under `ClipboardKeyboard.xcodeproj`, regenerate, hash again, and require equality even though the generated project is ignored by Git.

```bash
project_hash_before="$(find ClipboardKeyboard.xcodeproj -type f -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
./scripts/generate-project.sh
project_hash_after="$(find ClipboardKeyboard.xcodeproj -type f -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
test "$project_hash_before" = "$project_hash_after"
```

Confirm `.gitignore` excludes `ClipboardKeyboard.xcodeproj`, derived data, `Config/Signing.local.xcconfig`, and no source directory.

Stage the explicit paths from this task, inspect `git diff --cached --check` and the whole staged diff, then commit:

```bash
git commit -m "chore: bootstrap native Apple workspace"
```

### Task 2: Implement Core Privacy, Capture, and Retention Policies

**Files:**

- Delete: `Packages/ClipboardCore/Sources/ClipboardCore/ClipboardCore.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Models/ClipModels.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Privacy/PrivacyGate.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Privacy/RetentionPolicy.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Ports/Repositories.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Support/Clock.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/PrivacyGateTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/RetentionPolicyTests.swift`
- Delete: `Packages/ClipboardCore/Tests/ClipboardCoreTests/ClipboardCoreSmokeTests.swift`

**Interfaces:**

- Produces: `ApplicationIdentity`, `SourceConfidence`, `SourceObservation`, `PasteboardEventMetadata`, `CapturePolicy`, `PrivacyDecision`, `PrivacyDropReason`, `RetentionClass`, and `ClipMetadata`.
- Produces: `PrivacyGate.evaluate(_:policy:) -> PrivacyDecision`.
- Produces: `RetentionPolicy.evictionIDs(for:now:) -> Set<UUID>`.
- Produces: `ClipPersisting` and `Clock` protocols for platform adapters.
- Consumes: only Foundation types.

- [ ] **Step 1: Write failing Privacy Gate precedence tests**

Add table-driven tests covering consent not granted, Private Copy marker, recognized confidential marker, active capture pause, unknown source, ignored verified application, unsupported types, and accepted stable foreground text.
Include a precedence test where an accepted text type appears beside a confidential marker and still drops before read authorization.

Use this contract in tests:

```swift
let decision = PrivacyGate().evaluate(
    PasteboardEventMetadata(
        changeCount: 41,
        declaredTypeIdentifiers: ["public.utf8-plain-text", "com.agilebits.onepassword"],
        source: .init(identity: nil, confidence: .unknown),
        capturePauseActive: false
    ),
    policy: .standard(consentGranted: true, ignoredApplications: [])
)

XCTAssertEqual(decision, .drop(.confidentialType))
```

- [ ] **Step 2: Run the focused tests and verify the expected compile failure**

Run:

```bash
swift test --package-path Packages/ClipboardCore --filter PrivacyGateTests
```

Expected: fail because `PrivacyGate` and its input types do not exist.

- [ ] **Step 3: Implement the metadata-only decision model**

Implement these public shapes without a payload or preview field:

```swift
public struct ApplicationIdentity: Hashable, Codable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let signingIdentifier: String
}

public enum SourceConfidence: String, Codable, Sendable {
    case unknown
    case inferredStableForeground
}

public enum PrivacyDecision: Equatable, Sendable {
    case drop(PrivacyDropReason)
    case authorizeRead(changeCount: Int)
}

public struct PrivacyGate: Sendable {
    public func evaluate(_ metadata: PasteboardEventMetadata, policy: CapturePolicy) -> PrivacyDecision
}
```

Evaluate in this exact order: consent, Private Copy marker or confidential marker, capture pause, acceptable source confidence, verified ignored application, supported primary text declaration, then `.authorizeRead`.
Seed `CapturePolicy.standard` with `com.agilebits.onepassword`, `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, and `org.nspasteboard.AutoGeneratedType` plus the application marker `kr.donminzzi.clipboardkeyboard.private-copy`.
Never infer an ignored application from a display name.

- [ ] **Step 4: Write failing retention-boundary tests**

Test disabled history, items older than 24 hours, an ordered set of 201 unpinned items, pinned exemption, and the union of age and count evictions.

Use this assertion:

```swift
let policy = RetentionPolicy(maxAge: 24 * 60 * 60, maxUnpinnedCount: 200, historyEnabled: true)
let evicted = policy.evictionIDs(for: records, now: Date(timeIntervalSince1970: 200_000))

XCTAssertFalse(evicted.contains(pinned.id))
XCTAssertEqual(records.filter { !$0.isPinned && !evicted.contains($0.id) }.count, 200)
```

- [ ] **Step 5: Implement retention and repository ports, then run the package suite**

Define `ClipMetadata` with only opaque ID, capture time, byte count, representation kinds, keyed digest, source-confidence enum, and pinned flag.
Do not put title, preview, source application name, query terms, or extracted values in metadata.
Define asynchronous `ClipPersisting` methods `save(_:)`, `load(id:)`, `listMetadata()`, `delete(id:)`, and `delete(ids:)`.

Run:

```bash
swift test --package-path Packages/ClipboardCore --filter PrivacyGateTests
swift test --package-path Packages/ClipboardCore --filter RetentionPolicyTests
swift test --package-path Packages/ClipboardCore
```

Expected: all package tests pass.

- [ ] **Step 6: Run the explicit-path quality gate and commit**

Run:

```bash
trunk fmt --no-fix --diff=full Packages/ClipboardCore
trunk check --no-fix Packages/ClipboardCore
```

Stage only `Packages/ClipboardCore`, inspect the staged diff, and commit:

```bash
git commit -m "feat(core): add privacy and retention policies"
```

### Task 3: Implement Representations, Transformations, Extraction, and Search

**Files:**

- Modify: `Packages/ClipboardCore/Sources/ClipboardCore/Models/ClipModels.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Content/RepresentationResolver.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Content/HTMLTextProjector.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Content/Transformations.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Content/ValueExtractor.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Search/ClipSearchIndex.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/RepresentationResolverTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/HTMLTextProjectorTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/TransformationTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/ValueExtractorTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/ClipSearchIndexTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/korean-value-cases.json`

**Interfaces:**

- Produces: `RepresentationKind`, `RawTextRepresentation`, `ClipRepresentation`, `ResolvedTextContent`, `ClipEnvelope`, `ContentKind`, `ClipCategory`, `ValueCandidate`, and `CopyFormat`.
- Produces: `HTMLTextProjector.project(_ data: Data) throws -> String`, a pure parser that never resolves URLs or loads external resources.
- Produces: `RepresentationResolver.resolve(_:) throws -> ResolvedTextContent`.
- Produces: `TextTransformer.render(_ content: ResolvedTextContent, as format: CopyFormat) throws -> [ClipRepresentation]`.
- Produces: `ValueExtractor.candidates(in:) -> [ValueCandidate]`.
- Produces: `ClipSearchIndex.replace(_:)` and `ClipSearchIndex.search(_:,scope:,limit:) -> [ClipSearchResult]`.
- Consumes: the metadata and repository contracts from Task 2.

- [ ] **Step 1: Write failing original-representation and canonical-string tests**

Cover plain text preference, RTF fallback, HTML fallback, user-declared Markdown, mixed representations, exact code whitespace and line endings, unreadable supported representation rejection, and unrelated auxiliary-type omission.

Use the exact result shape:

```swift
let result = try RepresentationResolver().resolve([
    RawTextRepresentation(kind: .html, data: Data("<p>Hello</p>".utf8), textProjection: nil),
    RawTextRepresentation(kind: .plainText, data: Data("Hello\n".utf8), textProjection: "Hello\n")
])

XCTAssertEqual(result.insertionString, "Hello\n")
XCTAssertEqual(result.originals.map(\.kind), [.html, .plainText])
```

The platform reader, not the resolver, represents a failed supported read as an error; the resolver must never accept a prefix or a partial-success flag.
Plain Text and Markdown use their exact decoded string as `textProjection`.
RTF requires the owning AppKit or UIKit adapter to supply its string projection after a complete read.
HTML projection uses the pure `HTMLTextProjector`, which handles text, entities, and deterministic block separators without invoking WebKit or loading referenced resources.

- [ ] **Step 2: Run the focused representation tests and verify failure**

Run:

```bash
swift test --package-path Packages/ClipboardCore --filter RepresentationResolverTests
```

Expected: compile failure because the representation types are absent.

- [ ] **Step 3: Implement immutable representations and deterministic transformations**

Use immutable value types and these cases:

```swift
public enum RepresentationKind: String, Codable, CaseIterable, Sendable {
    case plainText
    case markdown
    case rtf
    case html
}

public enum CopyFormat: String, Codable, CaseIterable, Sendable {
    case originalCompatible
    case plainText
    case markdownSource
    case html
    case rtf
    case digitsOnly
    case trimSurroundingWhitespace
    case normalizeInternalWhitespace
}
```

Keep each original byte sequence unchanged.
Generate a new representation or pinned revision for every explicit transform instead of overwriting an original.
Reject HTML or RTF conversion when no lossless source exists rather than inventing rich content.
Add malicious HTML fixtures containing remote image, stylesheet, and script URLs and assert projection performs no network-capable call.

Define the accepted local-history boundary explicitly:

```swift
public struct ClipRepresentation: Codable, Equatable, Sendable {
    public let kind: RepresentationKind
    public let originalBytes: Data
    public let byteSize: Int
    public let keyedDigest: Data
}

public struct ClipEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let retentionClass: RetentionClass
    public let sourceConfidence: SourceConfidence
    public let representations: [ClipRepresentation]
    public let canonicalInsertionString: String
    public let title: String
    public let contentKind: ContentKind
    public let category: ClipCategory?
    public let preview: String
    public let valueCandidates: [ValueCandidate]
}
```

Require `ClipRepresentation.byteSize == originalBytes.count` and make keyed digests caller-supplied so the core package never owns a platform encryption key.
Treat `preview` and `valueCandidates` as discardable derived fields, while `representations` and `canonicalInsertionString` are immutable source fields.

- [ ] **Step 4: Write failing Korean value-extraction tests**

Version positive and negative fixtures for phone numbers, emails, URLs, one-time codes, account-number candidates with nearby bank or `계좌` or `입금` context, order numbers without account context, and bare digit sequences.

Assert the selected candidate never contains the entire source message:

```swift
let candidates = ValueExtractor().candidates(in: "입금 계좌 123-456-789012 입니다")
let account = try XCTUnwrap(candidates.first { $0.kind == .accountNumber })

XCTAssertEqual(account.original, "123-456-789012")
XCTAssertEqual(account.digitsOnly, "123456789012")
XCTAssertNil(ValueExtractor().candidates(in: "주문번호 123-456-789012").first { $0.kind == .accountNumber })
```

Implement deterministic regular expressions and bounded context windows.
Do not infer a bank name from digits.

- [ ] **Step 5: Write failing local-search tests and implement the memory-only index**

Test title, canonical insertion string, category, exact code symbols, Unicode, whitespace normalization for matching only, stable recency tie-breaking, scope filtering, and a hard result limit.
Keep stored originals untouched.

Use this interface:

```swift
public actor ClipSearchIndex {
    public func replace(_ documents: [ClipSearchDocument])
    public func remove(ids: Set<UUID>)
    public func search(_ query: String, scope: SearchScope, limit: Int) -> [ClipSearchResult]
    public func purge()
}
```

- [ ] **Step 6: Run the complete core suite, quality gate, and commit**

Run:

```bash
swift test --package-path Packages/ClipboardCore
trunk fmt --no-fix --diff=full Packages/ClipboardCore
trunk check --no-fix Packages/ClipboardCore
```

Stage only `Packages/ClipboardCore`, review the staged diff and fixture contents, then commit:

```bash
git commit -m "feat(core): add text processing and search"
```

### Task 4: Implement Pinned Revisions, Conflicts, Tombstones, and Reset State

**Files:**

- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Models/PinnedModels.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Sync/PinnedReplica.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Sync/PendingMutationJournal.swift`
- Modify: `Packages/ClipboardCore/Sources/ClipboardCore/Ports/Repositories.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/PinnedReplicaTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/PendingMutationJournalTests.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/PinnedLibraryContractTests.swift`

**Interfaces:**

- Produces: `PinPayload`, `PinnedRevision`, `PinnedTombstone`, `LibraryResetGeneration`, `PinnedMutation`, `PinnedReplicaState`, `MergeOutcome`, and `SyncState`.
- Produces: `PinnedReplica.apply(_:) -> MergeOutcome`.
- Produces: `PendingMutationJournal.pending: [PinnedMutation]` plus idempotent enqueue, acknowledge, stale-generation purge, and retry ordering.
- Produces: `PinPayload.init(envelope:title:category:)`, which copies complete immutable representations and the canonical insertion string but excludes capture source, preview, and extracted candidates.
- Produces: `PinnedLibrary` protocol with list, search, pin, revise, delete, replace-from-remote, and reset operations.
- Consumes: immutable representations and search types from Task 3.

- [ ] **Step 1: Write failing revision and deletion-wins tests**

Cover a first pin, a local edit that creates a new immutable revision, concurrent remote edit that preserves a conflict copy, a newer tombstone against an edit, an older tombstone, duplicate idempotent delivery, and stale mutation from a prior reset generation.

Use these identities and counters:

```swift
public struct PinnedRevision: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let revisionID: UUID
    public let libraryGeneration: Int64
    public let itemGeneration: Int64
    public let modifiedAt: Date
    public let deviceID: String
    public let payload: PinPayload
}
```

Require item generation to increase monotonically and use revision ID only as an idempotency key, not as ordering.
Define `PinPayload` as the complete immutable original representations, canonical insertion string, encrypted title, inferred content kind, and optional user category.
Do not add source identity, source confidence, preview, search normalization, or unselected extraction candidates to it.

- [ ] **Step 2: Run the focused replica tests and verify failure**

Run:

```bash
swift test --package-path Packages/ClipboardCore --filter PinnedReplicaTests
```

Expected: compile failure because pinned replica types do not exist.

- [ ] **Step 3: Implement the pure merge state machine**

Implement these decisions:

```swift
public enum MergeOutcome: Equatable, Sendable {
    case inserted(UUID)
    case updated(UUID)
    case conflict(primary: UUID, copy: UUID)
    case deleted(UUID)
    case ignoredDuplicate
    case ignoredStaleGeneration
}
```

A higher library reset generation clears all content-bearing revisions before applying later mutations.
A tombstone at the same or higher item generation wins over content.
Concurrent content at the same item generation retains the deterministic primary selected by `(modifiedAt, deviceID, revisionID)` and creates a visibly marked conflict copy for the other payload.
Tombstones and reset records contain no title, category, insertion string, original bytes, preview, query, or extracted value.

- [ ] **Step 4: Define the asynchronous pinned-library contract and contract-test fake**

Use this protocol without exposing CloudKit:

```swift
public protocol PinnedLibrary: Sendable {
    func allItems() async throws -> [PinnedRevision]
    func search(_ query: String, limit: Int) async throws -> [PinnedRevision]
    func pin(_ payload: PinPayload) async throws -> PinnedRevision
    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision
    func delete(itemID: UUID) async throws -> PinnedTombstone
    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome
    func advanceResetGeneration() async throws -> LibraryResetGeneration
}
```

Add contract tests proving Pin is the only transition that turns source content into a synchronized-domain revision and that deleting a candidate does not retain its source message.
Add a `ClipEnvelope → PinPayload` contract test proving complete original representations and canonical insertion text survive, while source confidence, preview, and unselected value candidates do not cross the pinned boundary.
Candidate Pin creates `PinPayload` directly from the selected candidate and never converts the source message envelope.
Implement the pending journal as part of encrypted replica state so local libraries can record durable Pin and deletion intent before CloudKit exists.

- [ ] **Step 5: Run package tests, quality gate, and commit**

Run:

```bash
swift test --package-path Packages/ClipboardCore
trunk fmt --no-fix --diff=full Packages/ClipboardCore
trunk check --no-fix Packages/ClipboardCore
```

Stage only `Packages/ClipboardCore`, review the staged diff, and commit:

```bash
git commit -m "feat(core): add pinned replica state"
```

### Task 5: Build the Encrypted macOS Local History Store

**Files:**

- Create: `Apps/macOS/Infrastructure/Persistence/MacKeychainMasterKeyStore.swift`
- Create: `Apps/macOS/Infrastructure/Persistence/AESGCMClipCipher.swift`
- Create: `Apps/macOS/Infrastructure/Persistence/EncryptedMacClipStore.swift`
- Create: `Apps/macOS/Infrastructure/Persistence/MacHistoryIndex.swift`
- Create: `Tests/macOS/MacKeychainMasterKeyStoreTests.swift`
- Create: `Tests/macOS/AESGCMClipCipherTests.swift`
- Create: `Tests/macOS/EncryptedMacClipStoreTests.swift`
- Create: `Tests/macOS/MacHistoryIndexTests.swift`
- Modify: `project.yml`

**Interfaces:**

- Produces: `MasterKeyProviding.loadOrCreateKey() throws -> SymmetricKey`.
- Produces: `ClipCipher.seal(_:) throws -> Data` and `ClipCipher.open(_:) throws -> ClipEnvelope`.
- Produces: `EncryptedMacClipStore`, an actor conforming to `ClipPersisting`.
- Produces: `MacHistoryIndex.unlock(from:)`, `search(_:)`, `remove(ids:)`, and `lock()`.
- Consumes: `ClipEnvelope`, `ClipMetadata`, `RetentionPolicy`, `ClipPersisting`, and `ClipSearchIndex` from Tasks 2-3.

- [ ] **Step 1: Write failing authenticated-encryption and Keychain tests**

Test key creation, repeat loading of the same 256-bit key, duplicate item rejection, Keychain denied, ciphertext bit flip, wrong key, and no plaintext fallback.
Use dependency-injected `SecItem` operations so tests do not mutate the operator's login Keychain.

```swift
let sealed = try cipher.seal(envelope)
XCTAssertNil(sealed.range(of: Data(envelope.canonicalInsertionString.utf8)))
XCTAssertEqual(try cipher.open(sealed), envelope)
```

- [ ] **Step 2: Run focused persistence tests and verify failure**

Run:

```bash
./scripts/generate-project.sh
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:ClipboardKeyboardMacTests/AESGCMClipCipherTests test
```

Expected: compile failure because the persistence adapters do not exist.

- [ ] **Step 3: Implement Keychain and per-record encrypted files**

Store one random 256-bit master key under service `kr.donminzzi.clipboardkeyboard.master-key.mac` with an accessibility class that is unavailable before the user logs in.
Seal each `ClipEnvelope` with AES-GCM and bind its UUID plus schema version as authenticated additional data.
Write ciphertext to `Application Support/ClipboardKeyboard/records/<opaque-uuid>.clip` through a sibling temporary file followed by atomic replacement.
Write `metadata.json` with only the `ClipMetadata` fields permitted by Task 2.
If Keychain, encryption, full-file write, atomic replacement, or metadata commit fails, remove the temporary file and leave no metadata-only row.

- [ ] **Step 4: Write failing retention, disk-content, and memory-index tests**

Task 5 persists only unpinned, retention-bounded macOS clipboard history.
Create a temporary store containing expired unpinned, over-count unpinned, and active unpinned records.
Assert pinned envelopes are rejected and are not valid Task 5 fixtures.
Pinned exemption from age and count eviction remains verified by `RetentionPolicyTests`, while Task 7 owns durable pinned persistence through `EncryptedMacPinnedStore` and `LocalMacPinnedLibrary`.
Assert purge removes only selected ciphertext files and metadata rows.
Recursively scan the temporary store and assert no file contains known title, preview, query, extracted value, source hint, or canonical string bytes.
Assert `MacHistoryIndex.lock()` removes all search results without modifying encrypted files.

- [ ] **Step 5: Implement retention and bounded in-memory search**

Decrypt accepted records only while the app is running and protected storage is available.
Load at most the current retention window, build `ClipSearchDocument` values in actor-isolated memory, remove them on deletion or retention purge, and purge the entire index on protected-storage lock or app termination.
Expose content-free error categories such as `keyUnavailable`, `authenticationFailed`, `diskFull`, `atomicReplaceFailed`, and `corruptRecord`.

- [ ] **Step 6: Run macOS tests, source scan, quality gate, and commit**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
if rg -n 'print\(|debugPrint\(|dump\(' Apps/macOS/Infrastructure/Persistence Tests/macOS; then exit 1; fi
trunk fmt --no-fix --diff=full Apps/macOS/Infrastructure/Persistence Tests/macOS
trunk check --no-fix Apps/macOS/Infrastructure/Persistence Tests/macOS
```

Expected: tests pass and the source scan prints no production logging call.
Stage only the persistence files, tests, and `project.yml`, review the staged diff, then commit:

```bash
git commit -m "feat(mac): add encrypted local history"
```

### Task 6: Implement the macOS Privacy-Gated Capture Pipeline

**Files:**

- Create: `Apps/macOS/Infrastructure/Pasteboard/MacPasteboardClient.swift`
- Create: `Apps/macOS/Infrastructure/Pasteboard/SourceObservationTracker.swift`
- Create: `Apps/macOS/Infrastructure/Pasteboard/PasteboardWatcher.swift`
- Create: `Apps/macOS/Infrastructure/Pasteboard/ClipboardCaptureCoordinator.swift`
- Create: `Apps/macOS/Infrastructure/Content/MacRTFTextProjector.swift`
- Create: `Apps/macOS/Features/ExplicitSave/ExplicitSaveSession.swift`
- Create: `Tests/macOS/MacPasteboardClientTests.swift`
- Create: `Tests/macOS/SourceObservationTrackerTests.swift`
- Create: `Tests/macOS/ClipboardCaptureCoordinatorTests.swift`
- Create: `Tests/macOS/MacRTFTextProjectorTests.swift`
- Create: `Tests/macOS/ExplicitSaveSessionTests.swift`

**Interfaces:**

- Produces: `MacPasteboardReading.readMetadata()`, `readSupportedRepresentations(for:)`, and `writeRepresentations(_:marker:)` as separate calls.
- Produces: `SourceObservationTracker.beginInterval()` and `finishInterval() -> SourceObservation`.
- Produces: `ClipboardCaptureCoordinator.poll()`, `beginExplicitSave()`, `confirmExplicitSave(token:)`, and `pauseCapture(for:)`.
- Produces: `ExplicitSaveToken(changeCount:expiresAt:)` with a 30-second implementation default.
- Consumes: `PrivacyGate`, `RepresentationResolver`, `EncryptedMacClipStore`, and `MacHistoryIndex`.

- [ ] **Step 1: Write a failing read-order spy test**

Use a pasteboard spy that increments separate metadata and payload counters.
For Private Copy marker, confidential marker, paused capture, unknown source, ignored verified application, and unsupported declarations, assert `payloadReadCount == 0` and no preview, digest, store, index, or sync call occurs.

```swift
await coordinator.poll()

XCTAssertEqual(pasteboard.metadataReadCount, 1)
XCTAssertEqual(pasteboard.payloadReadCount, 0)
XCTAssertEqual(store.saveCallCount, 0)
```

- [ ] **Step 2: Run the focused coordinator tests and verify failure**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:ClipboardKeyboardMacTests/ClipboardCaptureCoordinatorTests test
```

Expected: compile failure because the capture coordinator does not exist.

- [ ] **Step 3: Implement source confidence and the 500-millisecond watcher**

At each poll interval, record the frontmost process identity and activation-notification generation at the beginning and end.
Return `.inferredStableForeground` only when the bundle, team, signing identifier, and activation generation are unchanged.
Return `.unknown` on activation races, missing signing information, helper ambiguity, or lookup errors.
Resolve user-selected ignored applications from an application picker and validate their code-signing identity before saving a rule.
Poll `NSPasteboard.general.changeCount` every 500 milliseconds without reading representation bytes until the Privacy Gate authorizes the exact change count.

- [ ] **Step 4: Implement complete representation reads and atomic accept-or-drop behavior**

After authorization, read every declared supported primary text representation into bounded volatile memory.
If any declared supported representation fails or the `changeCount` changes during the read, discard the whole event.
Preserve complete Plain Text, Markdown, RTF, and HTML bytes; ignore unrelated nonconfidential auxiliary types.
Use `MacRTFTextProjector` only after authorization to derive the RTF insertion string, and use the pure core projector for HTML so copied markup cannot trigger an external resource load.
Generate canonical text, preview, derived values, and keyed digest only after all reads succeed, then encrypt and store once.
Never enqueue an unpinned event to a sync adapter.
Assert every capture failure leaves `NSPasteboard.general` content and ownership unchanged.

- [ ] **Step 5: Implement explicit Save Current Clipboard and capture pause**

The explicit flow must still drop Private Copy and confidential markers before reading.
For an otherwise eligible current change count, hold complete representations only in `ExplicitSaveSession`, show a content-free summary containing representation kinds and total byte count, and require a second confirmation within 30 seconds.
Cancel, timeout, pasteboard change, read failure, or failed commit purges volatile bytes.
Implement pause as a deadline that drops every pasteboard event for exactly the active interval and supports early resume.

- [ ] **Step 6: Run integration-focused tests, quality gate, and commit**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
trunk fmt --no-fix --diff=full Apps/macOS/Infrastructure/Pasteboard Apps/macOS/Infrastructure/Content Apps/macOS/Features/ExplicitSave Tests/macOS
trunk check --no-fix Apps/macOS/Infrastructure/Pasteboard Apps/macOS/Infrastructure/Content Apps/macOS/Features/ExplicitSave Tests/macOS
```

Stage only the Task 6 paths, inspect the staged diff for any pre-gate content access, then commit:

```bash
git commit -m "feat(mac): add privacy-gated clipboard capture"
```

### Task 7: Ship the Local-Only macOS Menu Bar Experience and Private Copy

**Files:**

- Modify: `project.yml`
- Modify: `Apps/macOS/App/ClipboardKeyboardMacApp.swift`
- Modify: `Apps/macOS/App/MacAppDelegate.swift`
- Create: `Apps/macOS/App/MacAppModel.swift`
- Create: `Apps/macOS/Features/Onboarding/MacOnboardingView.swift`
- Create: `Apps/macOS/Features/Palette/PaletteViewModel.swift`
- Create: `Apps/macOS/Features/Palette/PaletteView.swift`
- Create: `Apps/macOS/Features/Palette/StatusItemController.swift`
- Create: `Apps/macOS/Features/Palette/PalettePanelController.swift`
- Create: `Apps/macOS/Features/Settings/MacSettingsView.swift`
- Create: `Apps/macOS/Features/Settings/IgnoredApplicationPicker.swift`
- Create: `Apps/macOS/Features/Files/MacClipDocumentCodec.swift`
- Create: `Apps/macOS/Features/Files/MacImportExportController.swift`
- Create: `Apps/macOS/Infrastructure/Persistence/EncryptedMacPinnedStore.swift`
- Create: `Apps/macOS/Infrastructure/Persistence/LocalMacPinnedLibrary.swift`
- Create: `Apps/macOS/Services/GlobalPaletteShortcut.swift`
- Create: `Apps/macOS/Services/PrivateCopyService.swift`
- Create: `Tests/macOS/PaletteViewModelTests.swift`
- Create: `Tests/macOS/LocalMacPinnedLibraryTests.swift`
- Create: `Tests/macOS/MacClipDocumentCodecTests.swift`
- Create: `Tests/macOS/PrivateCopyServiceTests.swift`
- Create: `Tests/macOS/MacSettingsTests.swift`

**Interfaces:**

- Produces: `MacAppModel` as the single app-state composition root.
- Produces: `EncryptedMacPinnedStore` and `LocalMacPinnedLibrary`, which conform to the Task 4 pinned contract and keep pinned content outside unpinned retention.
- Produces: `PaletteViewModel.search(scope:)`, `copySelected(as:)`, `pinSelected()`, `exportSelected()`, and `deleteSelected()`.
- Produces: `MacClipDocumentCodec` and `MacImportExportController` for explicit one-item TXT, MD, RTF, and HTML workflows.
- Produces: `PrivateCopyService.privateCopy(_:userData:error:)` advertised through `NSServices`.
- Produces: `GlobalPaletteShortcut` using the native Carbon hot-key registration API with default Option-Command-V.
- Consumes: the local history, capture coordinator, transformations, and pinned-library protocol from Tasks 2-6.

- [ ] **Step 1: Write failing palette and settings view-model tests**

Test Recent versus Pinned scope, bounded single-line preview, keyboard selection, Return copying all compatible originals, Copy As, explicit Pin, import, export, delete, capture consent default false, 60-second pause countdown, ignored-app identity display, sync default false, protected-storage error, and pending-state labels.
Test encrypted local Pin, immutable edit, retention exemption, pending-journal persistence, TXT and MD and RTF and HTML same-format byte round trips, malformed import rejection, cancelled export cleanup, and a configurable global shortcut conflict.
Test retention settings reject values longer than 24 hours or greater than 200 items, accept shorter positive limits, and support a fully disabled history state.

```swift
await viewModel.handle(.returnKey)

XCTAssertEqual(pasteboardWriter.lastWrite?.kinds, [.plainText, .rtf, .html])
XCTAssertTrue(viewModel.shouldClose)
```

- [ ] **Step 2: Implement the menu bar shell and settings without automatic paste**

Compose `NSStatusItem`, `NSPanel`, and SwiftUI content.
Set `LSUIElement=true` so the application remains an agent-style menu bar app while retaining an explicit Settings window.
Keep one search field with Recent and Pinned scopes.
Use arrow keys for selection and Return for copy-and-close.
Expose Pin, Copy As, Export, and Delete as explicit actions.
Show Paused, Capture Pause Countdown, Protected Storage Locked, Sync Pending, and Deletion Pending states without content in error messages.
Do not add Accessibility permission or an automatic paste path.
Add opt-in login launch through `SMAppService.mainApp`.
Allow the palette shortcut to be changed in Settings while retaining Option-Command-V as the default and displaying a conflict instead of silently replacing another registration.
Allow the user to shorten the unpinned age or count limit or disable history; do not offer a control that exceeds the approved 24-hour or 200-item defaults in the MVP.

Persist pinned replica state in a separate authenticated encrypted document through `EncryptedMacPinnedStore`.
Implement `LocalMacPinnedLibrary` over that document so an explicit Pin is retention-exempt, searchable in the Pinned scope, and journaled for Task 13 while producing no CloudKit call when sync is disabled.
Implement one-item TXT, MD, RTF, and HTML import, export, and sharing with exact same-format byte round trips, explicit Pin on import, explicit file destinations on export, and temporary-file cleanup.

- [ ] **Step 3: Write a failing Private Copy transaction test**

Test successful pass-through of every compatible representation plus `kr.donminzzi.clipboardkeyboard.private-copy`, failed source read, failed pasteboard write, destination without Services support, shortcut conflict, and absence of a false shield.

```swift
try service.performPrivateCopy(from: servicePasteboard)

XCTAssertEqual(systemPasteboard.marker, "kr.donminzzi.clipboardkeyboard.private-copy")
XCTAssertTrue(shieldPresenter.didShowSuccess)
XCTAssertEqual(historyStore.saveCallCount, 0)
```

- [ ] **Step 4: Advertise and register the native macOS Service**

Add one `NSServices` entry through `project.yml` with `NSMessage` `privateCopy`, uppercase `NSKeyEquivalent` `C`, `NSSendTypes` and `NSReturnTypes` for supported text, an empty `NSRequiredContext`, and a localized menu title `Private Copy`.
Uppercase `C` intentionally maps to Shift-Command-C.
Register `PrivateCopyService` with `NSApplication.shared.servicesProvider` only after the app dependencies are ready.
Write selected bytes back to the general pasteboard with the private marker and display the shield only after the write succeeds.
Offer `Pause Capture for 60 Seconds` when the Service is not handled or conflicts.
Do not claim to disable Universal Clipboard or erase the system pasteboard.

- [ ] **Step 5: Run automated and signed manual macOS checks**

Run automated checks:

```bash
./scripts/generate-project.sh
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
trunk fmt --no-fix --diff=full project.yml Apps/macOS Tests/macOS
trunk check --no-fix project.yml Apps/macOS Tests/macOS
```

With the operator's local signing configuration, run the app and verify the Service in TextEdit and Xcode, verify shortcut conflict behavior, verify the success shield, verify no history record appears, and verify the 60-second fallback.
Record any host that does not expose selected content to Services as unsupported rather than a product failure.

- [ ] **Step 6: Review capabilities and commit**

Inspect the generated macOS property list and assert the `NSServices` key equivalent remains uppercase `C`.
Stage only Task 7 files and `project.yml`, inspect the complete staged diff, then commit:

```bash
git commit -m "feat(mac): add menu bar palette and private copy"
```

### Task 8: Build the Protected iPhone Pinned Library

**Files:**

- Modify: `Apps/iOS/App/ClipboardKeyboardApp.swift`
- Create: `Apps/iOS/App/PhoneAppModel.swift`
- Create: `Apps/iOS/Infrastructure/Persistence/PhoneKeychainMasterKeyStore.swift`
- Create: `Apps/iOS/Infrastructure/Persistence/EncryptedPhonePinnedStore.swift`
- Create: `Apps/iOS/Infrastructure/Persistence/LocalPinnedLibrary.swift`
- Create: `Apps/iOS/Features/Library/LibraryViewModel.swift`
- Create: `Apps/iOS/Features/Library/LibraryView.swift`
- Create: `Apps/iOS/Features/Library/PinnedEditorView.swift`
- Create: `Apps/iOS/Features/Settings/PhoneSettingsView.swift`
- Create: `Tests/iOS/EncryptedPhonePinnedStoreTests.swift`
- Create: `Tests/iOS/LocalPinnedLibraryTests.swift`
- Create: `Tests/iOS/LibraryViewModelTests.swift`

**Interfaces:**

- Produces: `EncryptedPhonePinnedStore`, which persists complete pinned replica state under `NSFileProtectionComplete`.
- Produces: `LocalPinnedLibrary`, an actor conforming to `PinnedLibrary`.
- Produces: `PhoneAppModel` and `LibraryViewModel` for local-only app operation.
- Consumes: pinned models, merge state, search, transformations, and `PinnedLibrary` from Tasks 3-4.

- [ ] **Step 1: Write failing file-protection and encrypted-store tests**

Use a temporary directory and injected file-attribute operations.
Test authenticated round trip, wrong key, tampered ciphertext, atomic replacement, write failure cleanup, no plaintext fallback, complete file protection on temporary and final files, and protected-data-unavailable behavior.

```swift
let attributes = try fileManager.attributesOfItem(atPath: storeURL.path)
XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
XCTAssertNil(try Data(contentsOf: storeURL).range(of: Data("secret prompt".utf8)))
```

- [ ] **Step 2: Run the focused store tests and verify failure**

Run:

```bash
./scripts/generate-project.sh
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO -only-testing:ClipboardKeyboardiOSTests/EncryptedPhonePinnedStoreTests test
```

Expected: compile failure because the phone persistence adapters do not exist.

- [ ] **Step 3: Implement the protected working set and local pinned actor**

Store the phone master key under service `kr.donminzzi.clipboardkeyboard.master-key.ios` with an accessibility class that requires the device to be unlocked.
Persist pinned replica state as one authenticated encrypted document through a protected temporary file and atomic replacement.
After replacement, reapply and verify `NSFileProtectionComplete` on the final file.
On `UIApplication.protectedDataWillBecomeUnavailableNotification`, close handles, purge decoded content, clear search state, and make repository calls return a content-free locked error.
On unlock, reopen only after key and file protection checks succeed.

- [ ] **Step 4: Write failing local-library behavior tests**

Test explicit Pin, edit-as-new-revision, local search, built-in categories Prompts, Code, Everyday, and Uncategorized, delete with immediate local disappearance, deletion-pending status, and a durable local pending journal while sync is disabled.

```swift
let revision = try await library.pin(payload)

XCTAssertEqual(revision.itemGeneration, 1)
XCTAssertEqual(try XCTUnwrap(stateStore.lastSavedState).pendingJournal.pending.map(\.kind), [.saveRevision])
XCTAssertEqual(try await library.search("deploy", limit: 20).map(\.itemID), [revision.itemID])
```

Keep a durable pending-mutation journal inside the encrypted document so later CloudKit work can enqueue pins and tombstones without changing the local store schema.
No CloudKit transport exists in the local-only checkpoint; Task 13 separately verifies that disabling sync leaves this journal intact while producing zero transport writes.

- [ ] **Step 5: Implement the Library and Settings surfaces**

Build a three-tab shell with Library, Extract, and Settings, leaving Extract as a disabled explanatory state until Task 9.
Implement search, category filtering, item editing, deletion confirmation, sync off by default, cache status, privacy summary, and local-delete behavior.
Categories are user organization only and never trigger automatic Pin.
Do not display remote success before a later sync confirmation.

- [ ] **Step 6: Run iPhone tests, quality gate, and commit**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
trunk fmt --no-fix --diff=full Apps/iOS Tests/iOS
trunk check --no-fix Apps/iOS Tests/iOS
```

Stage only the Task 8 paths, inspect the whole staged diff, then commit:

```bash
git commit -m "feat(ios): add protected pinned library"
```

### Task 9: Add iPhone Extraction, Import, Export, and Item Sharing

**Files:**

- Create: `Apps/iOS/Features/Extract/ExtractViewModel.swift`
- Create: `Apps/iOS/Features/Extract/ExtractView.swift`
- Create: `Apps/iOS/Features/Files/ClipDocumentCodec.swift`
- Create: `Apps/iOS/Features/Files/ClipFileDocument.swift`
- Create: `Apps/iOS/Features/Files/ImportExportViewModel.swift`
- Create: `Apps/iOS/Infrastructure/Content/PhoneRTFTextProjector.swift`
- Create: `Apps/iOS/Infrastructure/Pasteboard/SystemPasteboardWriter.swift`
- Modify: `Apps/iOS/Features/Library/LibraryView.swift`
- Modify: `Apps/iOS/Features/Settings/PhoneSettingsView.swift`
- Create: `Tests/iOS/ExtractViewModelTests.swift`
- Create: `Tests/iOS/ClipDocumentCodecTests.swift`
- Create: `Tests/iOS/ImportExportViewModelTests.swift`
- Create: `Tests/iOS/PhoneRTFTextProjectorTests.swift`
- Create: `Tests/iOS/SystemPasteboardWriterTests.swift`

**Interfaces:**

- Produces: `ExtractViewModel.acceptPastedText(_:)`, `copyCandidate(_:variant:)`, and `pinCandidate(_:variant:)`.
- Produces: `SystemPasteboardWriter.write(_:)`, the only iPhone-app adapter allowed to mutate the system pasteboard and never to read it.
- Produces: `ClipDocumentCodec.decode(data:declaredType:)` and `encode(_:as:)`.
- Produces: `ClipFileDocument` for explicit item-level file export and `ShareLink`.
- Consumes: `ValueExtractor`, `TextTransformer`, `RepresentationResolver`, and `PinnedLibrary`.

- [ ] **Step 1: Write failing candidate-isolation tests**

Test a whole iMessage-like Korean message, candidate context display, original and digits-only variants, copy without save, pin selected candidate only, cancellation, empty input, and no durable source-message record.

```swift
await viewModel.acceptPastedText("입금 계좌 123-456-789012, 주문번호 998877")
try await viewModel.pinCandidate(accountCandidate, variant: .digitsOnly)

let items = try await library.allItems()
XCTAssertEqual(items.count, 1)
let item = try XCTUnwrap(items.first)
XCTAssertEqual(item.payload.insertionString, "123456789012")
XCTAssertFalse(item.payload.insertionString.contains("주문번호"))
```

- [ ] **Step 2: Implement explicit system paste intake and extraction UI**

Use SwiftUI `PasteButton(payloadType: String.self)` as the only clipboard intake control.
Do not read or poll `UIPasteboard.general` in application code.
Hold the pasted source in view-model memory only, display deterministic candidates with bounded context, and purge the source on cancel, completed copy, successful Pin, protected-data lock, or view teardown.
Copying a candidate must not save it.
Route that explicit user action through `SystemPasteboardWriter`, which performs a write only and exposes no read API.
Pinning a candidate must construct a `PinPayload` containing only the selected value and chosen representation.

- [ ] **Step 3: Write failing TXT, MD, RTF, and HTML round-trip tests**

Version test fixtures for Unicode, multiline code, CRLF, malformed RTF, malformed HTML, unsupported binary data, and a cancelled export.
Require exact byte preservation when importing and exporting the same declared representation.
Require `.txt`, `.md`, `.rtf`, and `.html` as the default extensions for Plain Text, Markdown, RTF, and HTML.

```swift
let imported = try codec.decode(data: fixture, declaredType: .rtf)
let exported = try codec.encode(imported, as: .rtf)

XCTAssertEqual(exported.data, fixture)
XCTAssertEqual(exported.fileExtension, "rtf")
```

- [ ] **Step 4: Implement explicit file workflows**

Use `.fileImporter` with only Plain Text, Markdown, RTF, and HTML content types.
Preview the decoded item and require an explicit Pin before durable storage.
Use `PhoneRTFTextProjector` for complete local RTF bytes and the pure core projector for HTML; neither path may fetch external resources.
Use `FileDocument` and `ShareLink` for one-item export and sharing.
Remove every temporary export file after completion or cancellation.
Do not implement a full-library backup or image/file history.

- [ ] **Step 5: Run iPhone tests and a pasteboard source scan**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
test "$(rg -l 'UIPasteboard\.general' Apps/iOS)" = 'Apps/iOS/Infrastructure/Pasteboard/SystemPasteboardWriter.swift'
trunk fmt --no-fix --diff=full Apps/iOS/Features Apps/iOS/Infrastructure/Content Apps/iOS/Infrastructure/Pasteboard Tests/iOS
trunk check --no-fix Apps/iOS/Features Apps/iOS/Infrastructure/Content Apps/iOS/Infrastructure/Pasteboard Tests/iOS
```

Expected: all tests pass and the pasteboard scan returns exactly `SystemPasteboardWriter.swift`.

- [ ] **Step 6: Stage, review, and commit**

Stage only Task 9 files, inspect fixtures and the complete staged diff, then commit:

```bash
git commit -m "feat(ios): add extraction and file workflows"
```

### Task 10: Publish the Protected Snapshot and Build the Read-Only Keyboard

**Files:**

- Modify: `project.yml`
- Create: `Apps/iOS/ClipboardKeyboardiOS.entitlements`
- Create: `Extensions/Keyboard/ClipboardKeyboardKeyboard.entitlements`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Models/KeyboardSnapshot.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/KeyboardSnapshotTests.swift`
- Create: `Apps/iOS/Infrastructure/Snapshot/KeyboardSnapshotPublisher.swift`
- Create: `Tests/iOS/KeyboardSnapshotPublisherTests.swift`
- Modify: `Extensions/Keyboard/KeyboardViewController.swift`
- Create: `Extensions/Keyboard/KeyboardRootView.swift`
- Create: `Extensions/Keyboard/KeyboardViewModel.swift`
- Create: `Extensions/Keyboard/KeyboardSnapshotReader.swift`
- Create: `Tests/Keyboard/KeyboardSnapshotReaderTests.swift`
- Create: `Tests/Keyboard/KeyboardViewModelTests.swift`
- Create: `scripts/audit-keyboard-boundary.sh`

**Interfaces:**

- Produces: `KeyboardSnapshot`, `KeyboardSnapshotItem`, and schema version `1`.
- Produces: `KeyboardSnapshotPublisher.publish(items:generation:lastCloudRefresh:)` and `clear(generation:)`.
- Produces: `KeyboardSnapshotReader.load() -> SnapshotLoadResult`.
- Produces: `KeyboardViewModel.search(_:)` and `insert(itemID:)` with an injected insertion closure.
- Consumes: local pinned revisions and the App Group `group.kr.donminzzi.clipboardkeyboard`.

- [ ] **Step 1: Write failing canonical snapshot and digest tests**

Define a snapshot containing only ID, title, category, and canonical insertion string per item plus schema version, generation, creation time, last successful CloudKit refresh time, content digest, and item count.
Encode with sorted JSON keys and compute SHA-256 over the canonical encoding with the digest field omitted.
Test deterministic encoding, digest mismatch, item-count mismatch, unknown schema, partial JSON, duplicate IDs, and a valid snapshot older than 24 hours.

```swift
let result = KeyboardSnapshotValidator().validate(encodedSnapshot)

XCTAssertEqual(result, .valid(expectedSnapshot))
XCTAssertTrue(expectedSnapshot.refreshRecommended(at: clock.now))
XCTAssertFalse(expectedSnapshot.items.isEmpty)
```

An old but valid snapshot remains usable and only reports `refreshRecommended`.

- [ ] **Step 2: Run core snapshot tests and verify failure**

Run:

```bash
swift test --package-path Packages/ClipboardCore --filter KeyboardSnapshotTests
```

Expected: compile failure because the snapshot schema does not exist.

- [ ] **Step 3: Implement protected atomic publication**

Resolve the App Group container through an injected URL provider.
Write a complete temporary snapshot with `NSFileProtectionComplete`, flush and close it, decode and validate it, atomically replace `keyboard-snapshot-v1.json`, reapply `NSFileProtectionComplete`, then re-read file attributes and digest.
On any failure, remove the temporary file and retain the prior valid snapshot.
On deletion, reset, protected-data unavailability, or local store lock, publish or clear immediately without waiting for CloudKit.

- [ ] **Step 4: Write failing read-only extension tests**

Test valid, missing, locked, corrupt, unsupported, partial, stale-valid, and replacement-race snapshots.
Return these content-free states:

```swift
enum SnapshotLoadResult: Equatable {
    case available(KeyboardSnapshot)
    case refreshRecommended(KeyboardSnapshot)
    case unavailable(SnapshotUnavailableReason)
}
```

Unknown schema, digest mismatch, partial read, or locked protection must fail closed to an empty library with `Open the app to sync`.

- [ ] **Step 5: Build the keyboard UI and exact entitlement boundary**

Set `RequestsOpenAccess` to `false` in the generated keyboard property list for Debug and Release.
Give the containing iPhone app and keyboard the App Group entitlement, and give the keyboard no iCloud or push entitlement.
Host `KeyboardRootView` from `UIInputViewController`, search only the loaded snapshot, filter Prompts, Code, and Everyday, and insert selected text through `textDocumentProxy.insertText`.
Do not read the general pasteboard, invoke CloudKit, access the network, write usage history, mutate pins, or write the snapshot.
Show cache freshness and noninteractive instructions without unsupported app-opening workarounds.

- [ ] **Step 6: Implement and run the keyboard boundary audit**

Make `scripts/audit-keyboard-boundary.sh` fail if production keyboard sources contain `URLSession`, `Network`, `CloudKit`, `CKContainer`, `UIPasteboard`, write-mode `FileHandle`, `Data.write`, or `FileManager` mutation calls.
Also parse the generated property list and entitlements to require `RequestsOpenAccess=false`, exactly one App Group, and no iCloud entitlement.

Run sequentially:

```bash
./scripts/generate-project.sh
swift test --package-path Packages/ClipboardCore --filter KeyboardSnapshotTests
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardKeyboard -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
./scripts/audit-keyboard-boundary.sh
```

- [ ] **Step 7: Run the quality gate, review identifiers, and commit**

Run:

```bash
trunk fmt --no-fix --diff=full project.yml Packages/ClipboardCore Apps/iOS/Infrastructure/Snapshot Extensions/Keyboard Tests/iOS Tests/Keyboard scripts/audit-keyboard-boundary.sh
trunk check --no-fix project.yml Packages/ClipboardCore Apps/iOS/Infrastructure/Snapshot Extensions/Keyboard Tests/iOS Tests/Keyboard scripts/audit-keyboard-boundary.sh
```

Before staging, verify that the App Group identifier is available to the operator's personal Apple Developer account.
If unavailable, stop and ask rather than changing identifiers silently.
Stage only Task 10 files and commit:

```bash
git commit -m "feat(keyboard): add protected read-only snapshot"
```

### Task 11: Add Explicit Share Extension Intake and Inbox Cleanup

**Files:**

- Modify: `project.yml`
- Modify: `Apps/iOS/ClipboardKeyboardiOS.entitlements`
- Create: `Extensions/Share/ClipboardKeyboardShare.entitlements`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Models/ShareInboxItem.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/ShareInboxItemTests.swift`
- Modify: `Extensions/Share/ShareViewController.swift`
- Create: `Extensions/Share/ShareViewModel.swift`
- Create: `Extensions/Share/ShareInboxWriter.swift`
- Create: `Apps/iOS/Infrastructure/Share/ShareInboxConsumer.swift`
- Create: `Apps/iOS/Features/ShareInbox/PendingShareView.swift`
- Create: `Tests/Share/ShareViewModelTests.swift`
- Create: `Tests/Share/ShareInboxWriterTests.swift`
- Create: `Tests/iOS/ShareInboxConsumerTests.swift`

**Interfaces:**

- Produces: `ShareInboxItem(schemaVersion:id:createdAt:kind:data:digest:)` with schema version `1`.
- Produces: `ShareInboxWriter.write(_:)` for exactly one validated text or URL item.
- Produces: `ShareInboxConsumer.pendingItems()`, `commit(id:)`, `reject(id:)`, and `purgeTerminalItems()`.
- Consumes: App Group, `NSFileProtectionComplete`, `RepresentationResolver`, and `PinnedLibrary`.

- [ ] **Step 1: Write failing one-item and lifecycle tests**

Test one text, one URL, multiple inputs, unsupported attachment, explicit cancellation, explicit Pin, protected write failure, partial file, digest mismatch, app validation failure, successful app commit, and terminal cleanup.

```swift
try await shareViewModel.pin()

XCTAssertEqual(writer.items.count, 1)
XCTAssertEqual(shareViewModel.completion, .queuedForContainingApp)
XCTAssertNotEqual(shareViewModel.completion, .pinned)
```

The Share extension must never report a successful Pin because only the containing app can validate and commit it.

- [ ] **Step 2: Implement explicit preview and protected inbox write**

Accept exactly one `public.text` or URL provider.
Load it only after the user opens the Share extension, display a bounded preview, and require a Pin tap.
Encode a versioned inbox item with a digest, write it to a protected temporary file, validate, atomically replace into `share-inbox/`, and verify `NSFileProtectionComplete`.
Delete temporary files on cancel, timeout, write failure, or extension expiration.
Do not invoke CloudKit from the extension.

- [ ] **Step 3: Implement containing-app consumption**

On app activation and protected-data availability, enumerate only version-1 inbox files, validate schema and digest, and present pending items.
Require the final app confirmation before calling `PinnedLibrary.pin`.
Delete the inbox item only after successful local commit or a terminal rejection.
Keep a recoverable inbox item when a transient local-store error occurs.
Purge decoded inbox content and close handles when protected data becomes unavailable.

- [ ] **Step 4: Configure the extension activation and entitlement boundary**

Use `project.yml` to permit one text or one web URL and reject images, files, and multiple attachments.
Give the Share extension only the shared App Group entitlement; do not give it CloudKit, remote notifications, or keyboard open access.

- [ ] **Step 5: Run tests, audit extension sources, and commit**

Run:

```bash
./scripts/generate-project.sh
swift test --package-path Packages/ClipboardCore --filter ShareInboxItemTests
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardShare -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO -only-testing:ClipboardKeyboardiOSTests/ShareInboxConsumerTests test
if rg -n 'CloudKit|CKContainer|URLSession' Extensions/Share; then exit 1; fi
trunk fmt --no-fix --diff=full project.yml Packages/ClipboardCore Extensions/Share Apps/iOS/Infrastructure/Share Apps/iOS/Features/ShareInbox Tests
trunk check --no-fix project.yml Packages/ClipboardCore Extensions/Share Apps/iOS/Infrastructure/Share Apps/iOS/Features/ShareInbox Tests
```

Stage only Task 11 files, inspect the whole staged diff, then commit:

```bash
git commit -m "feat(share): add protected explicit intake"
```

### Task 12: Add Authenticated App Intents and Shortcuts

**Files:**

- Create: `Apps/iOS/Intents/IntentDependencies.swift`
- Create: `Apps/iOS/Intents/PinTextIntent.swift`
- Create: `Apps/iOS/Intents/ExtractValuesIntent.swift`
- Create: `Apps/iOS/Intents/FindPinnedIntent.swift`
- Create: `Apps/iOS/Intents/ClipboardKeyboardShortcuts.swift`
- Create: `Tests/iOS/AppIntentPolicyTests.swift`
- Create: `Tests/iOS/AppIntentBehaviorTests.swift`

**Interfaces:**

- Produces: `PinTextIntent`, `ExtractValuesIntent`, and `FindPinnedIntent` with `static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }`.
- Produces: `IntentDependencies` that resolves only the protected local pinned library, deterministic extractor, and explicit write-only pasteboard adapter.
- Produces: `ClipboardKeyboardShortcuts` with one phrase set per intent.
- Consumes: `PinnedLibrary`, `ValueExtractor`, and protected-data state.

- [ ] **Step 1: Write failing static authentication-policy tests**

Assert all three intents require local-device authentication and none uses `alwaysAllowed` or the weaker cross-device `requiresAuthentication` policy.

```swift
XCTAssertEqual(PinTextIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
XCTAssertEqual(ExtractValuesIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
XCTAssertEqual(FindPinnedIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
```

- [ ] **Step 2: Run focused policy tests and verify failure**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO -only-testing:ClipboardKeyboardiOSTests/AppIntentPolicyTests test
```

Expected: compile failure because the intents do not exist.

- [ ] **Step 3: Implement the three authenticated actions**

`Pin Text` accepts an explicit string, rejects empty input, and pins only that string after the system-enforced local authentication.
`Extract Values` accepts an explicit string, returns deterministic candidates, and does not persist them.
`Find Pinned` accepts a query, searches the protected local library, asks the user to choose when multiple results exist, and returns the selected insertion string or writes it through `SystemPasteboardWriter` only when the intent's explicit Copy parameter is enabled.
Do not expose pinned titles or values through an unauthenticated `AppEntity` query.
When protected data is unavailable, return a fixed locked error with no title, query, result count, or value.

- [ ] **Step 4: Add behavior tests with injected dependencies**

Test success, cancellation, empty input, multiple result selection, copy without persistence, repository failure, and protected-data lock.
Verify result descriptions and thrown errors do not contain input or stored content.
Register localized App Shortcut phrases without content-derived parameters.

- [ ] **Step 5: Run automated and locked-device manual checks**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
trunk fmt --no-fix --diff=full Apps/iOS/Intents Tests/iOS/AppIntentPolicyTests.swift Tests/iOS/AppIntentBehaviorTests.swift
trunk check --no-fix Apps/iOS/Intents Tests/iOS/AppIntentPolicyTests.swift Tests/iOS/AppIntentBehaviorTests.swift
```

On a signed physical iPhone, invoke all three actions from Shortcuts and Siri while unlocked and locked.
Require authentication before content access and verify locked failure text is content-free.

- [ ] **Step 6: Stage, review, and commit**

Stage only Task 12 files, inspect authentication policy in every intent, then commit:

```bash
git commit -m "feat(intents): add authenticated clipboard actions"
```

### Task 13: Add Pinned-Only Private CloudKit Synchronization

**Files:**

- Modify: `project.yml`
- Modify: `Apps/macOS/App/MacAppModel.swift`
- Modify: `Apps/iOS/App/PhoneAppModel.swift`
- Create: `Apps/macOS/ClipboardKeyboardMac.entitlements`
- Modify: `Apps/iOS/ClipboardKeyboardiOS.entitlements`
- Modify: `Packages/ClipboardCore/Sources/ClipboardCore/Sync/PendingMutationJournal.swift`
- Modify: `Packages/ClipboardCore/Tests/ClipboardCoreTests/PendingMutationJournalTests.swift`
- Create: `Packages/ClipboardCore/Sources/ClipboardCore/Sync/PinnedCloudDocument.swift`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/PinnedCloudDocumentTests.swift`
- Create: `Apps/macOS/Infrastructure/CloudKit/MacCloudRecordCodec.swift`
- Create: `Apps/macOS/Infrastructure/CloudKit/MacPinnedSyncEngine.swift`
- Create: `Apps/macOS/Infrastructure/CloudKit/MacSyncStateStore.swift`
- Create: `Apps/iOS/Infrastructure/CloudKit/PhoneCloudRecordCodec.swift`
- Create: `Apps/iOS/Infrastructure/CloudKit/PhonePinnedSyncEngine.swift`
- Create: `Apps/iOS/Infrastructure/CloudKit/PhoneSyncStateStore.swift`
- Create: `Tests/macOS/MacCloudRecordCodecTests.swift`
- Create: `Tests/macOS/MacPinnedSyncEngineTests.swift`
- Create: `Tests/iOS/PhoneCloudRecordCodecTests.swift`
- Create: `Tests/iOS/PhonePinnedSyncEngineTests.swift`

**Interfaces:**

- Produces: target-owned `MacPinnedSyncEngine` and `PhonePinnedSyncEngine` adapters around the user's private `CKDatabase`.
- Produces: `PinnedCloudDocument`, a Foundation-only schema and deterministic payload encoding shared by both target-owned record codecs without importing CloudKit into `ClipboardCore`.
- Produces: target-owned record codecs for `PinnedRevision`, `PinnedTombstone`, and `LibraryReset` record types in custom zone `PinnedLibrary`.
- Produces: encrypted local persistence for `CKSyncEngine.State.Serialization` and the pending-mutation journal.
- Consumes: pinned replica state and pending local mutations from Tasks 4 and 8.

- [ ] **Step 1: Write failing record-codec privacy tests**

First test that `PinnedCloudDocument` deterministically encodes the same pinned revision and field schema on macOS and iOS.
Build a pinned revision containing a sentinel title, category, plain text, Markdown, RTF, HTML, and canonical insertion string.
Encode it into a `CKRecord` and assert every content-bearing field is present only through `record.encryptedValues`.
Assert tombstones and reset records contain no content-bearing value.
Assert no server query or sort key depends on an encrypted field.

```swift
let record = try codec.encode(revision)

XCTAssertNotNil(record.encryptedValues["payload"])
XCTAssertNil(record["payload"])
XCTAssertFalse(record.allKeys().contains("title"))
```

- [ ] **Step 2: Run focused codec tests and verify failure**

Run:

```bash
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:ClipboardKeyboardMacTests/MacCloudRecordCodecTests test
```

Expected: compile failure because the record codec does not exist.

- [ ] **Step 3: Implement the private custom-zone record contract**

Use record types `PinnedRevision`, `PinnedTombstone`, and `LibraryReset` in zone `PinnedLibrary`.
Map both target-owned codecs through the exact field keys and schema version declared by `PinnedCloudDocument` so their serialized payload bytes cannot drift.
Use record names derived from opaque item and revision IDs.
Keep only routing and monotonic counters outside encrypted fields: record type, opaque record name, library generation, item generation, mutation kind, and schema version.
Put title, category, insertion string, original Plain Text, Markdown, RTF, HTML, and other user-authored inline fields into `CKRecord.encryptedValues`.
Never query or sort by encrypted content; fetch by zone changes and search locally.

- [ ] **Step 4: Write failing sync-enable and unpinned-zero-write tests**

Test sync disabled on first launch, explicit enable, persisted `CKSyncEngine` state update, account unavailable, fetch, send, retryable error, terminal error, duplicate event, unpinned Mac capture, explicit Pin, and sync disable without remote deletion.

```swift
pasteboard.enqueueStableForegroundCopy(
    changeCount: 1,
    representations: [.plainText(Data("local only".utf8))]
)
await macCapture.poll()
XCTAssertEqual(cloudTransport.savedRecordCount, 0)

_ = try await pinnedLibrary.pin(payload)
XCTAssertEqual(syncJournal.pendingKinds, [.saveRevision])
```

Repeat the explicit Pin with sync disabled and assert the local journal still contains `.saveRevision` while `cloudTransport.savedRecordCount` remains `0`.

- [ ] **Step 5: Implement target-owned `CKSyncEngine` adapters**

Create one `CKSyncEngine` per app process against the private database and custom zone.
Persist every `.stateUpdate` serialization in the app's encrypted local store and restore it at launch.
Feed only pending pinned revisions, tombstones, reset records, and required zone setup to the engine.
Handle delegate events serially and never call `fetchChanges` or `sendChanges` from inside a delegate event handler.
Expose manual refresh outside the delegate.
Map offline and retryable errors to Sync Pending, terminal full-item errors to Unable to Sync Full Item, and encrypted-key reset to a recovery state that requires an explicit user decision before re-upload.
Disabling sync must cancel future CloudKit reads and writes without deleting existing remote records.

- [ ] **Step 6: Configure capabilities and verify the boundary**

Add `iCloud.kr.donminzzi.clipboardkeyboard`, private CloudKit, and remote-notification capabilities only to the macOS and iPhone apps.
Do not add them to the keyboard or Share extension.
Keep `RequestsOpenAccess=false` and rerun the keyboard audit after regenerating the project.
Before signed CloudKit testing, verify the container belongs to the operator's personal Apple Developer account; if registration fails, stop for operator direction.

- [ ] **Step 7: Run automated sync tests and commit**

Run sequentially:

```bash
./scripts/generate-project.sh
swift test --package-path Packages/ClipboardCore
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
./scripts/audit-keyboard-boundary.sh
trunk fmt --no-fix --diff=full project.yml Packages/ClipboardCore Apps/macOS Apps/iOS Tests
trunk check --no-fix project.yml Packages/ClipboardCore Apps/macOS Apps/iOS Tests
```

Stage only Task 13 files, inspect all entitlement and record-field changes, then commit:

```bash
git commit -m "feat(sync): add pinned-only CloudKit transport"
```

### Task 14: Complete Large Assets, Conflicts, Deletion, and Cloud Reset

**Files:**

- Modify: `Packages/ClipboardCore/Sources/ClipboardCore/Sync/PinnedReplica.swift`
- Modify: `Packages/ClipboardCore/Sources/ClipboardCore/Sync/PendingMutationJournal.swift`
- Modify: `Apps/macOS/Infrastructure/CloudKit/MacCloudRecordCodec.swift`
- Modify: `Apps/macOS/Infrastructure/CloudKit/MacPinnedSyncEngine.swift`
- Create: `Apps/macOS/Infrastructure/CloudKit/MacEncryptedAssetStore.swift`
- Modify: `Apps/iOS/Infrastructure/CloudKit/PhoneCloudRecordCodec.swift`
- Modify: `Apps/iOS/Infrastructure/CloudKit/PhonePinnedSyncEngine.swift`
- Create: `Apps/iOS/Infrastructure/CloudKit/PhoneEncryptedAssetStore.swift`
- Create: `Apps/iOS/Infrastructure/CloudKit/CloudDeletionCoordinator.swift`
- Modify: `Apps/iOS/Features/Settings/PhoneSettingsView.swift`
- Create: `Tests/macOS/MacEncryptedAssetStoreTests.swift`
- Create: `Tests/macOS/MacSyncConflictTests.swift`
- Create: `Tests/iOS/PhoneEncryptedAssetStoreTests.swift`
- Create: `Tests/iOS/PhoneSyncConflictTests.swift`
- Create: `Tests/iOS/CloudDeletionCoordinatorTests.swift`

**Interfaces:**

- Produces: `EncryptedAssetStore.makeAsset(for:)` and `openAsset(_:contentKey:)` in each owning target.
- Produces: `CloudDeletionCoordinator.authenticateAndDeleteCloudData()`.
- Extends: sync engines with conflict-copy, deletion-wins, reset-generation, offline retry, and terminal asset state behavior.
- Consumes: the CloudKit record contract from Task 13 and replica merge rules from Task 4.

- [ ] **Step 1: Write failing threshold and encrypted-asset tests**

Test serialized payload sizes of exactly 524,288 bytes and 524,289 bytes.
Require the former to use encrypted inline values and the latter to use a `CKAsset` containing AES-GCM ciphertext plus a random per-item content key in `encryptedValues`.
Test ciphertext tampering, wrong content key, temporary-file cleanup, successful round trip, and terminal asset upload failure.

```swift
XCTAssertEqual(try codec.storageMode(forSerializedByteCount: 524_288), .encryptedInline)
XCTAssertEqual(try codec.storageMode(forSerializedByteCount: 524_289), .encryptedAsset)
let assetURL = try XCTUnwrap(asset.fileURL)
XCTAssertNil(try Data(contentsOf: assetURL).range(of: plainPayload))
```

- [ ] **Step 2: Implement complete large-text asset handling**

Serialize the entire pinned payload before selecting storage mode.
For large payloads, generate a random 256-bit content key, seal the complete serialized payload with AES-GCM into a protected temporary asset file, attach that ciphertext as `CKAsset`, and store the content key only in `encryptedValues`.
Delete local asset staging files after confirmed send, terminal failure, cancellation, reset, or download decode.
Never split, prefix, or silently downgrade a large item.

- [ ] **Step 3: Write failing conflict, tombstone, offline, and stale-device tests**

Cover bidirectional first sync, offline pin, offline delete, edit versus edit, edit versus delete, duplicate fetch, newer reset, stale device reconnect, local unsynchronized revision after remote reset, and content-free tombstone retention.
Assert keyboard removal happens before remote confirmation.
Assert a deleted item cannot return after stale-device reconnection.

- [ ] **Step 4: Wire replica outcomes into both sync adapters**

Apply remote changes through `PinnedReplica` before mutating local stores.
Persist conflict copies with a visible conflict badge, a new opaque item ID, and the original user category unchanged.
On delete, purge every content-bearing local revision, pending edit, decoded cache, export temporary file, snapshot item, and recovery value before retaining the content-free tombstone.
Keep Sync Pending and Deletion Pending until the corresponding `CKSyncEngine` sent event confirms them.
On a reset-generation increase, purge all older-generation content and prevent its journal replay.

- [ ] **Step 5: Implement authenticated Delete Cloud Data**

Use `LocalAuthentication` in the containing iPhone app before any reset mutation.
After successful authentication and destructive confirmation, increment the local library reset generation, clear local library and keyboard snapshot immediately, queue deletion for all content records, and keep exactly one content-free `LibraryReset` record.
Do not claim completion until CloudKit confirms every content deletion and the reset record save.
Disabling sync remains a separate non-destructive control.

- [ ] **Step 6: Run automated and two-device signed validation**

Run automated checks:

```bash
swift test --package-path Packages/ClipboardCore
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
./scripts/audit-keyboard-boundary.sh
trunk fmt --no-fix --diff=full Packages/ClipboardCore Apps/macOS/Infrastructure/CloudKit Apps/iOS/Infrastructure/CloudKit Apps/iOS/Features/Settings Tests
trunk check --no-fix Packages/ClipboardCore Apps/macOS/Infrastructure/CloudKit Apps/iOS/Infrastructure/CloudKit Apps/iOS/Features/Settings Tests
```

With signed builds and the personal private container, perform the two-device scenarios for both sides of the 512 KiB threshold, offline edit and delete, stale-device reconnect, sync disable, authenticated cloud deletion, and encrypted-key reset recovery.
Record CloudKit request IDs and error categories only; do not record content.

- [ ] **Step 7: Stage, review, and commit**

Inspect the staged diff specifically for plaintext asset writes, content-bearing tombstones, early success states, and stale journal replay.
Commit:

```bash
git commit -m "feat(sync): add encrypted assets and deletion state"
```

### Task 15: Close Security, Failure, Performance, and Release Gates

**Files:**

- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/search-5000.json`
- Create: `Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/search-queries.json`
- Create: `scripts/generate-search-fixtures.swift`
- Create: `scripts/security-audit.sh`
- Create: `scripts/measure-mac-idle.sh`
- Modify: `scripts/verify.sh`
- Create: `Tests/macOS/PrivacyBoundaryIntegrationTests.swift`
- Create: `Tests/macOS/MacSearchPerformanceTests.swift`
- Create: `Tests/iOS/ProtectedDataIntegrationTests.swift`
- Create: `Tests/Keyboard/KeyboardInsertionIntegrationTests.swift`
- Create: `Tests/Share/ShareLifecycleIntegrationTests.swift`
- Modify: `README.md`
- Create: `docs/notes/apple-mvp-release-evidence.md`

**Interfaces:**

- Produces: one full local verification command, `./scripts/verify.sh`.
- Produces: one read-only source and entitlement audit command, `./scripts/security-audit.sh`.
- Produces: `scripts/measure-mac-idle.sh`, which records five minutes of post-warm-up CPU and resident-memory samples without reading application content.
- Produces: deterministic 5,000-record and query fixtures regenerated by `scripts/generate-search-fixtures.swift`.
- Produces: a release-evidence template tied to hardware, operating-system build, application commit, Release configuration, and each manual gate.
- Consumes: every product target and contract from Tasks 1-14.

- [ ] **Step 1: Generate deterministic versioned performance fixtures**

Make `scripts/generate-search-fixtures.swift` use a fixed seed and produce exactly 5,000 records plus versioned prompt, code, Korean everyday-text, Unicode, whitespace, and no-match queries.
Write the fixture files through the generator, then rerun the generator and require byte-identical output.
Treat the script as the upstream source and never hand-edit the JSON.

Run:

```bash
swift scripts/generate-search-fixtures.swift
fixture_hash_before="$(shasum -a 256 Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/search-5000.json Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/search-queries.json | shasum -a 256 | awk '{print $1}')"
swift scripts/generate-search-fixtures.swift
fixture_hash_after="$(shasum -a 256 Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/search-5000.json Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures/search-queries.json | shasum -a 256 | awk '{print $1}')"
test "$fixture_hash_before" = "$fixture_hash_after"
```

- [ ] **Step 2: Add failing integration tests for every fail-closed boundary**

Cover recognized 1Password marker with every supported text type, ignored-app best-effort behavior, source-switch race, Keychain denial, corrupt records, disk-full injection, unreadable supported representation, unpinned zero CloudKit writes, App Group locked or corrupt snapshot, protected-data memory purge, Share partial write and cleanup, App Intent locked errors, and no-truncation progressively large inputs.

Use spies that make any forbidden payload read, plaintext write, CloudKit write, snapshot write, or content log fail the test immediately.

- [ ] **Step 3: Add deterministic search and insertion performance tests**

Load the versioned 5,000-record fixture in Release-compatible test settings, warm for 60 seconds in the manual performance run, and record query-to-first-result samples.
For automated tests, require correctness and collect timing without using a single noisy CI sample as a universal pass gate.
For the release evidence run, require the 95th percentile at or below 150 milliseconds.
Add keyboard insertion integration cases for multiline prompts, Unicode, emoji, and exact code indentation.
Make `scripts/measure-mac-idle.sh` wait for a 60-second warm-up, sample the signed Release app for five minutes, calculate median CPU, and calculate resident-memory growth between the first and last samples.
Require median CPU below 1 percent and resident-memory growth no greater than 10 MiB for the recorded release gate.

- [ ] **Step 4: Implement the read-only security audit**

Make `scripts/security-audit.sh` fail on production-source uses of `print`, `debugPrint`, `dump`, clipboard content in `Logger`, any iPhone pasteboard access outside the exact write-only `SystemPasteboardWriter`, every keyboard pasteboard API, CloudKit or networking in extensions, a keyboard write API, `RequestsOpenAccess` other than false, CloudKit entitlements in extensions, a missing App Group protection check, or a committed signing team.
Make the audit parse generated property lists and entitlements after `./scripts/generate-project.sh`.
Keep allowlisted framework uses explicit and path-scoped.

- [ ] **Step 5: Make `scripts/verify.sh` the sequential automated gate**

Run these commands in this order and stop on the first failure:

```bash
./scripts/generate-project.sh
swift test --package-path Packages/ClipboardCore
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardKeyboard -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ClipboardKeyboard.xcodeproj -scheme ClipboardKeyboardShare -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' CODE_SIGNING_ALLOWED=NO test
./scripts/security-audit.sh
trunk fmt --no-fix --diff=full project.yml Config Packages Apps Extensions Tests scripts README.md docs/specs docs/plans docs/notes
trunk check --no-fix project.yml Config Packages Apps Extensions Tests scripts README.md docs/specs docs/plans docs/notes
```

Every path argument is explicit.
Do not run these Apple builds concurrently.

- [ ] **Step 6: Execute and record the manual release gates**

Populate `docs/notes/apple-mvp-release-evidence.md` with the exact commit, development Mac hardware model and memory, macOS build, Xcode build, Release configuration, signed bundle identifiers, physical iPhone model and OS, CloudKit environment, command outputs, and pass or gap for every manual gate in the design.
At minimum, record confidential markers, best-effort ignored app and background-helper limitation, Private Copy success and conflict fallback, immediate app-switch race, Plain Text and RTF and HTML byte round trips, bidirectional Plain Text and Markdown and RTF and HTML pin and delete, both sides of 512 KiB, sync disable, Delete Cloud Data with stale device, Korean negative account candidates, progressively large text, five-minute idle CPU and memory growth, search p95, keyboard time to first interactive content, and keyboard peak resident memory.
Record the keyboard with Full Access disabled, network unavailable, device lock and unlock, a corrupt snapshot, and a stale-but-valid snapshot.
Record custom-keyboard substitution in secure fields, phone-pad fields, and at least one host that rejects third-party keyboards without presenting it as a product defect.
Mark an unexecuted gate \[PARTIAL\]; do not infer a pass.

- [ ] **Step 7: Update build and privacy documentation**

Document exact prerequisites, XcodeGen generation, unsigned verification, local signing configuration, App Group and CloudKit registration, and the four product targets in `README.md`.
Use only the approved product claims from the design.
State that application filtering is best effort, Universal Clipboard is outside product control, payloads are not unlimited, the custom keyboard is not available in every field, and CloudKit protection is not marketed as unconditional end-to-end encryption.

- [ ] **Step 8: Run the final fresh verification and inspect all state**

Run:

```bash
./scripts/verify.sh
git diff --check
git status --short --branch
```

Read the full output and count failures before making any completion claim.
If signed manual gates cannot run because the personal team or physical-device configuration remains unavailable, keep those rows \[PARTIAL\] and report the exact external blocker.

- [ ] **Step 9: Stage the final task, review, and commit**

Stage only Task 15 files.
Inspect `git diff --cached --check`, the full staged diff, fixture hashes, source-audit script, and release evidence.
Commit:

```bash
git commit -m "test: add Apple MVP release gates"
```

## Design Requirement Traceability

| Approved design requirement                                              | Implementation task       | Primary verification                                              |
| ------------------------------------------------------------------------ | ------------------------- | ----------------------------------------------------------------- |
| Native macOS, iPhone, keyboard, and Share targets                        | Task 1                    | Four sequential scheme builds and tests                           |
| Automatic capture and sync disabled by default                           | Tasks 6-8 and 13          | Coordinator, settings, and sync-enable tests                      |
| Privacy Gate before payload read or derivation                           | Tasks 2 and 6             | Read-order spies and confidential-marker integration tests        |
| Best-effort verified application ignore                                  | Tasks 2, 6, and 15        | Source-confidence race and manual password-manager tests          |
| 24-hour or 200-item unpinned local retention                             | Tasks 2 and 5             | Retention boundary and encrypted-store tests                      |
| Private Copy marker and 60-second pause                                  | Task 7                    | Service transaction tests and signed manual checks                |
| Original Plain Text, Markdown, RTF, HTML plus canonical insertion string | Task 3                    | Representation and round-trip tests                               |
| No character-count limit and no silent truncation                        | Tasks 3, 6, 9, 14, and 15 | Complete-read, large-input, file, and asset tests                 |
| Deterministic extraction, conservative Korean account candidates         | Tasks 3 and 9             | Versioned positive and negative fixtures                          |
| Encrypted local stores and no plaintext fallback                         | Tasks 5 and 8             | Keychain denial, ciphertext, disk scan, and file-protection tests |
| Only explicit pinned content reaches CloudKit                            | Tasks 4 and 13            | Pin-transition contract and unpinned-zero-write tests             |
| Private CloudKit encrypted fields and local search                       | Task 13                   | CKRecord field audit and no encrypted-field query tests           |
| Encrypted asset above 512 KiB                                            | Task 14                   | 524,288 and 524,289 byte boundary tests                           |
| Immutable revisions, conflict copies, deletion wins, tombstones, reset   | Tasks 4 and 14            | Pure replica and two-device stale-reconnect tests                 |
| Protected versioned App Group snapshot                                   | Task 10                   | Atomic replacement, file-protection, digest, and schema tests     |
| Full-Access-free read-only keyboard                                      | Task 10                   | Entitlement and forbidden-API audit plus insertion tests          |
| Explicit Share handoff and containing-app commit                         | Task 11                   | Lifecycle, partial write, validation, and cleanup tests           |
| Three locally authenticated App Intents                                  | Task 12                   | Static policy, injected behavior, and locked-device checks        |
| TXT, MD, RTF, HTML item import/export/share                              | Tasks 7 and 9             | Exact round-trip and cancellation tests                           |
| Content-free operational logging and no analytics SDK                    | Tasks 5 and 15            | Source audit and production dependency inspection                 |
| Manual security, performance, and product-claim gates                    | Task 15                   | Commit-tied release evidence with explicit gaps                   |

## Final Completion Gate

The Apple MVP implementation is complete only when all 15 task commits exist in order, `./scripts/verify.sh` passes from a clean checkout, the current design traceability table has no unmapped requirement, and every signed manual gate is either recorded as passed or reported as \[PARTIAL\] with a concrete external blocker.
A passing unsigned build does not prove App Group, Services, keyboard lock behavior, App Intents authentication, or CloudKit delivery.
Do not start the Media update or Android expansion in this plan.
