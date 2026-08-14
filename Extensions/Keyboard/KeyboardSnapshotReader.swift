import ClipboardCore
import Foundation

enum SnapshotUnavailableReason: Equatable, Sendable {
    case missing
    case locked
    case corrupt
    case unsupported
    case revoked
}

enum SnapshotLoadResult: Equatable, Sendable {
    case available(KeyboardSnapshot)
    case refreshRecommended(KeyboardSnapshot)
    case unavailable(SnapshotUnavailableReason)
}

struct KeyboardSnapshotReadOperations: @unchecked Sendable {
    let exists: (URL) -> Bool
    let protection: (URL) throws -> FileProtectionType?
    let read: (URL) throws -> Data

    static let live = KeyboardSnapshotReadOperations(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        protection: { url in
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            if let protection = value as? FileProtectionType {
                return protection
            }
            if let rawValue = value as? String {
                return FileProtectionType(rawValue: rawValue)
            }
            return nil
        },
        read: { try Data(contentsOf: $0) }
    )
}

struct KeyboardSnapshotReader: Sendable {
    private enum SelectedSource {
        case primary(URL)
        case fallback(snapshotURL: URL, digestURL: URL)
    }

    private static let appGroupIdentifier = "group.kr.donminzzi.clipboardkeyboard"
    private static let fileName = "keyboard-snapshot-v1.json"
    private static let previousFileName = "keyboard-snapshot-v1.previous"
    private static let previousDigestFileName = "keyboard-snapshot-v1.previous.digest"
    private static let revocationFenceFileName = "keyboard-snapshot-v1.revoked"

    private let containerURL: @Sendable () -> URL?
    private let operations: KeyboardSnapshotReadOperations
    private let now: @Sendable () -> Date

    init(
        containerURL: @escaping @Sendable () -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        },
        operations: KeyboardSnapshotReadOperations = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerURL = containerURL
        self.operations = operations
        self.now = now
    }

    func load() -> SnapshotLoadResult {
        guard let containerURL = containerURL() else { return .unavailable(.missing) }
        let fileURL = containerURL.appendingPathComponent(Self.fileName)
        let previousURL = containerURL.appendingPathComponent(Self.previousFileName)
        let previousDigestURL = containerURL.appendingPathComponent(Self.previousDigestFileName)
        let fenceURL = containerURL.appendingPathComponent(Self.revocationFenceFileName)
        guard !operations.exists(fenceURL) else { return .unavailable(.revoked) }

        let source: SelectedSource = operations.exists(fileURL)
            ? .primary(fileURL)
            : .fallback(snapshotURL: previousURL, digestURL: previousDigestURL)
        let result = read(source)
        guard !operations.exists(fenceURL) else { return .unavailable(.revoked) }
        guard sourceIsStillSelected(source, primaryURL: fileURL) else {
            return .unavailable(.revoked)
        }
        let revalidatedResult = read(source)
        guard sourceIsStillSelected(source, primaryURL: fileURL),
              hasStableIdentity(result, revalidatedResult)
        else {
            return .unavailable(.revoked)
        }
        guard !operations.exists(fenceURL) else { return .unavailable(.revoked) }
        return result
    }

    private func read(_ source: SelectedSource) -> SnapshotLoadResult {
        switch source {
        case let .primary(url):
            read(url)
        case let .fallback(snapshotURL, digestURL):
            readFallback(snapshotURL, digestURL: digestURL)
        }
    }

    private func sourceIsStillSelected(_ source: SelectedSource, primaryURL: URL) -> Bool {
        switch source {
        case .primary:
            operations.exists(primaryURL)
        case .fallback:
            !operations.exists(primaryURL)
        }
    }

    private func hasStableIdentity(_ first: SnapshotLoadResult, _ second: SnapshotLoadResult) -> Bool {
        switch (snapshot(from: first), snapshot(from: second)) {
        case let (.some(firstSnapshot), .some(secondSnapshot)):
            firstSnapshot.generation == secondSnapshot.generation
                && firstSnapshot.contentDigest == secondSnapshot.contentDigest
        case (nil, nil):
            first == second
        default:
            false
        }
    }

    private func snapshot(from result: SnapshotLoadResult) -> KeyboardSnapshot? {
        switch result {
        case let .available(snapshot), let .refreshRecommended(snapshot):
            snapshot
        case .unavailable:
            nil
        }
    }

    private func readFallback(_ fileURL: URL, digestURL: URL) -> SnapshotLoadResult {
        guard operations.exists(fileURL), operations.exists(digestURL) else {
            return .unavailable(.missing)
        }
        guard isCompletelyProtected(digestURL), let expectedDigest = try? operations.read(digestURL) else {
            return .unavailable(.missing)
        }
        guard isCompletelyProtected(digestURL) else { return .unavailable(.missing) }
        let result = read(fileURL)
        let snapshot: KeyboardSnapshot
        switch result {
        case let .available(value), let .refreshRecommended(value):
            snapshot = value
        case .unavailable:
            return .unavailable(.missing)
        }
        guard expectedDigest == Data(snapshot.contentDigest.utf8) else {
            return .unavailable(.missing)
        }
        return result
    }

    private func read(_ fileURL: URL) -> SnapshotLoadResult {
        guard operations.exists(fileURL) else { return .unavailable(.missing) }
        guard isCompletelyProtected(fileURL) else { return .unavailable(.locked) }
        guard let data = try? operations.read(fileURL) else { return .unavailable(.locked) }
        guard isCompletelyProtected(fileURL) else { return .unavailable(.locked) }
        switch KeyboardSnapshotValidator().validate(data) {
        case let .valid(snapshot):
            return snapshot.refreshRecommended(at: now())
                ? .refreshRecommended(snapshot)
                : .available(snapshot)
        case .invalid(.unsupportedSchema):
            return .unavailable(.unsupported)
        case .invalid:
            return .unavailable(.corrupt)
        }
    }

    private func isCompletelyProtected(_ url: URL) -> Bool {
        (try? operations.protection(url)) == .complete
    }
}
