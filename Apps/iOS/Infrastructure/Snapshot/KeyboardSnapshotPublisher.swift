import ClipboardCore
import Foundation

@MainActor
protocol KeyboardSnapshotPublishing: AnyObject {
    func publish(items: [PinnedRevision], generation: Int64, lastCloudRefresh: Date?) throws
    func armRevocationFence() throws
    func completeDestructivePublication(items: [PinnedRevision], generation: Int64, lastCloudRefresh: Date?) throws
    func clear(generation: Int64) throws
}

@MainActor
final class NoopKeyboardSnapshotPublisher: KeyboardSnapshotPublishing {
    func publish(items _: [PinnedRevision], generation _: Int64, lastCloudRefresh _: Date?) throws {}
    func armRevocationFence() throws {}
    func completeDestructivePublication(
        items _: [PinnedRevision], generation _: Int64, lastCloudRefresh _: Date?
    ) throws {}
    func clear(generation _: Int64) throws {}
}

enum KeyboardSnapshotPublisherError: Error, Equatable {
    case appGroupUnavailable
    case invalidSnapshot
    case protectionFailed
    case publicationFailed
    case revocationFenceUnavailable
    case cleanupFailed
}

@MainActor
final class KeyboardSnapshotPublisher: KeyboardSnapshotPublishing {
    nonisolated static let appGroupIdentifier = "group.kr.donminzzi.clipboardkeyboard"
    nonisolated static let fileName = "keyboard-snapshot-v1.json"
    nonisolated static let previousFileName = "keyboard-snapshot-v1.previous"
    nonisolated static let previousDigestFileName = "keyboard-snapshot-v1.previous.digest"
    nonisolated static let revocationFenceFileName = "keyboard-snapshot-v1.revoked"
    private nonisolated static let revocationMarker = Data("revoked-v1".utf8)

    private let containerURL: () -> URL?
    private let operations: PhonePinnedFileOperations
    private let now: @Sendable () -> Date
    private var hasVerifiedScrubRevocation = false

    init(
        containerURL: @escaping () -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: KeyboardSnapshotPublisher.appGroupIdentifier
            )
        },
        operations: PhonePinnedFileOperations = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerURL = containerURL
        self.operations = operations
        self.now = now
    }

    func publish(items: [PinnedRevision], generation: Int64, lastCloudRefresh: Date?) throws {
        let (containerURL, snapshot) = try publicationInput(
            items: items,
            generation: generation,
            lastCloudRefresh: lastCloudRefresh
        )
        try publishNondestructive(snapshot, in: containerURL)
    }

    func armRevocationFence() throws {
        guard let containerURL = containerURL() else {
            throw KeyboardSnapshotPublisherError.appGroupUnavailable
        }
        let fenceURL = containerURL.appendingPathComponent(Self.revocationFenceFileName)
        if validRevocationFence(at: fenceURL) {
            hasVerifiedScrubRevocation = false
            return
        }
        let temporaryURL = containerURL.appendingPathComponent(".\(UUID().uuidString).revocation.tmp")
        defer { try? operations.removeIfExists(temporaryURL) }
        do {
            try operations.createDirectory(containerURL)
            try writeProtectedBytes(Self.revocationMarker, to: temporaryURL)
            try operations.replace(temporaryURL, fenceURL)
            try operations.setCompleteProtection(fenceURL)
            try verifyProtectedBytes(Self.revocationMarker, at: fenceURL)
            hasVerifiedScrubRevocation = false
        } catch {
            if validRevocationFence(at: fenceURL) {
                hasVerifiedScrubRevocation = false
                return
            }
            try scrubContentBearingArtifacts(in: containerURL)
            hasVerifiedScrubRevocation = true
        }
    }

    func completeDestructivePublication(
        items: [PinnedRevision],
        generation: Int64,
        lastCloudRefresh: Date?
    ) throws {
        let (containerURL, snapshot) = try publicationInput(
            items: items,
            generation: generation,
            lastCloudRefresh: lastCloudRefresh
        )
        let fenceURL = containerURL.appendingPathComponent(Self.revocationFenceFileName)
        guard validRevocationFence(at: fenceURL) || hasVerifiedScrubRevocation else {
            throw KeyboardSnapshotPublisherError.revocationFenceUnavailable
        }
        try publishAuthoritative(snapshot, in: containerURL)
        let previousURL = containerURL.appendingPathComponent(Self.previousFileName)
        let previousDigestURL = containerURL.appendingPathComponent(Self.previousDigestFileName)
        try removeAndVerify(previousURL)
        try removeAndVerify(previousDigestURL)
        try removeAndVerify(fenceURL)
        hasVerifiedScrubRevocation = false
    }

    func clear(generation: Int64) throws {
        try armRevocationFence()
        try completeDestructivePublication(items: [], generation: generation, lastCloudRefresh: nil)
    }

    private func publicationInput(
        items: [PinnedRevision],
        generation: Int64,
        lastCloudRefresh: Date?
    ) throws -> (URL, KeyboardSnapshot) {
        guard let containerURL = containerURL() else {
            throw KeyboardSnapshotPublisherError.appGroupUnavailable
        }
        let snapshotItems = items.map {
            KeyboardSnapshotItem(
                id: $0.itemID,
                title: $0.payload.title,
                category: $0.payload.category,
                canonicalInsertionString: $0.payload.canonicalInsertionString
            )
        }
        let snapshot = try KeyboardSnapshot.make(
            items: snapshotItems,
            generation: generation,
            createdAt: now(),
            lastSuccessfulCloudRefresh: lastCloudRefresh
        )
        return (containerURL, snapshot)
    }

    private func publishNondestructive(_ snapshot: KeyboardSnapshot, in containerURL: URL) throws {
        let finalURL = containerURL.appendingPathComponent(Self.fileName)
        let previousURL = containerURL.appendingPathComponent(Self.previousFileName)
        let previousDigestURL = containerURL.appendingPathComponent(Self.previousDigestFileName)
        let temporaryURL = containerURL.appendingPathComponent(".\(UUID().uuidString).snapshot.tmp")
        defer { try? operations.removeIfExists(temporaryURL) }

        do {
            try operations.createDirectory(containerURL)
            try preparePreviousFallback(
                finalURL: finalURL,
                previousURL: previousURL,
                previousDigestURL: previousDigestURL,
                containerURL: containerURL
            )
            let encoded = try KeyboardSnapshotCodec().encode(snapshot)
            try writeProtectedSnapshot(encoded, to: temporaryURL)
            try operations.replace(temporaryURL, finalURL)
            try operations.setCompleteProtection(finalURL)
            try verifySnapshot(snapshot, at: finalURL)
            try removeAndVerify(previousURL)
            try removeAndVerify(previousDigestURL)
        } catch let error as KeyboardSnapshotPublisherError {
            throw error
        } catch {
            throw KeyboardSnapshotPublisherError.publicationFailed
        }
    }

    private func publishAuthoritative(_ snapshot: KeyboardSnapshot, in containerURL: URL) throws {
        let finalURL = containerURL.appendingPathComponent(Self.fileName)
        let temporaryURL = containerURL.appendingPathComponent(".\(UUID().uuidString).authoritative.tmp")
        defer { try? operations.removeIfExists(temporaryURL) }
        do {
            let encoded = try KeyboardSnapshotCodec().encode(snapshot)
            try writeProtectedSnapshot(encoded, to: temporaryURL)
            do {
                try operations.replace(temporaryURL, finalURL)
            } catch {
                guard validSnapshot(snapshot, at: finalURL) else {
                    throw KeyboardSnapshotPublisherError.publicationFailed
                }
            }
            try operations.setCompleteProtection(finalURL)
            try verifySnapshot(snapshot, at: finalURL)
        } catch let error as KeyboardSnapshotPublisherError {
            throw error
        } catch {
            throw KeyboardSnapshotPublisherError.publicationFailed
        }
    }

    private func preparePreviousFallback(
        finalURL: URL,
        previousURL: URL,
        previousDigestURL: URL,
        containerURL: URL
    ) throws {
        guard let previousData = validDataIfPresent(at: finalURL) else {
            if validPreviousFallbackData(at: previousURL, digestURL: previousDigestURL) == nil {
                try removeAndVerify(previousURL)
                try removeAndVerify(previousDigestURL)
            }
            return
        }
        guard case let .valid(previousSnapshot) = KeyboardSnapshotValidator().validate(previousData) else {
            throw KeyboardSnapshotPublisherError.invalidSnapshot
        }
        let temporaryURL = containerURL.appendingPathComponent(".\(UUID().uuidString).previous.tmp")
        let digestTemporaryURL = containerURL.appendingPathComponent(".\(UUID().uuidString).previous-digest.tmp")
        defer {
            try? operations.removeIfExists(temporaryURL)
            try? operations.removeIfExists(digestTemporaryURL)
        }
        try writeProtectedSnapshot(previousData, to: temporaryURL)
        try operations.replace(temporaryURL, previousURL)
        try operations.setCompleteProtection(previousURL)
        guard case .valid = try KeyboardSnapshotValidator().validate(operations.read(previousURL)) else {
            throw KeyboardSnapshotPublisherError.invalidSnapshot
        }
        try verifyProtection(at: previousURL)
        let digest = Data(previousSnapshot.contentDigest.utf8)
        try writeProtectedBytes(digest, to: digestTemporaryURL)
        try operations.replace(digestTemporaryURL, previousDigestURL)
        try operations.setCompleteProtection(previousDigestURL)
        try verifyProtectedBytes(digest, at: previousDigestURL)
    }

    private func writeProtectedSnapshot(_ data: Data, to url: URL) throws {
        try writeProtectedBytes(data, to: url)
        guard case .valid = try KeyboardSnapshotValidator().validate(operations.read(url)) else {
            throw KeyboardSnapshotPublisherError.invalidSnapshot
        }
    }

    private func writeProtectedBytes(_ data: Data, to url: URL) throws {
        try operations.createEmpty(url)
        try operations.setCompleteProtection(url)
        try verifyProtection(at: url)
        try operations.write(data, url)
        try verifyProtectedBytes(data, at: url)
    }

    private func verifyProtectedBytes(_ expected: Data, at url: URL) throws {
        try verifyProtection(at: url)
        guard try operations.read(url) == expected else {
            throw KeyboardSnapshotPublisherError.publicationFailed
        }
    }

    private func verifySnapshot(_ expected: KeyboardSnapshot, at url: URL) throws {
        try verifyProtection(at: url)
        guard case let .valid(snapshot) = try KeyboardSnapshotValidator().validate(operations.read(url)),
              snapshot.contentDigest == expected.contentDigest
        else {
            throw KeyboardSnapshotPublisherError.invalidSnapshot
        }
    }

    private func verifyProtection(at url: URL) throws {
        guard try operations.protection(url) == .complete else {
            throw KeyboardSnapshotPublisherError.protectionFailed
        }
    }

    private func validDataIfPresent(at url: URL) -> Data? {
        guard operations.fileExists(url),
              (try? operations.protection(url)) == .complete,
              let data = try? operations.read(url),
              case .valid = KeyboardSnapshotValidator().validate(data)
        else {
            return nil
        }
        return data
    }

    private func validSnapshot(_ expected: KeyboardSnapshot, at url: URL) -> Bool {
        guard let data = validDataIfPresent(at: url),
              case let .valid(snapshot) = KeyboardSnapshotValidator().validate(data)
        else {
            return false
        }
        return snapshot.contentDigest == expected.contentDigest
    }

    private func validPreviousFallbackData(at url: URL, digestURL: URL) -> Data? {
        guard let data = validDataIfPresent(at: url),
              operations.fileExists(digestURL),
              (try? operations.protection(digestURL)) == .complete,
              let digest = try? operations.read(digestURL),
              case let .valid(snapshot) = KeyboardSnapshotValidator().validate(data),
              digest == Data(snapshot.contentDigest.utf8)
        else {
            return nil
        }
        return data
    }

    private func validRevocationFence(at url: URL) -> Bool {
        guard operations.fileExists(url),
              (try? operations.protection(url)) == .complete,
              (try? operations.read(url)) == Self.revocationMarker
        else {
            return false
        }
        return true
    }

    private func removeAndVerify(_ url: URL) throws {
        do {
            try operations.removeIfExists(url)
        } catch {
            guard !operations.fileExists(url) else {
                throw KeyboardSnapshotPublisherError.cleanupFailed
            }
        }
        guard !operations.fileExists(url) else {
            throw KeyboardSnapshotPublisherError.cleanupFailed
        }
    }

    private func scrubContentBearingArtifacts(in containerURL: URL) throws {
        let urls = [
            containerURL.appendingPathComponent(Self.previousDigestFileName),
            containerURL.appendingPathComponent(Self.previousFileName),
            containerURL.appendingPathComponent(Self.fileName),
        ]
        for url in urls {
            do {
                try operations.removeIfExists(url)
            } catch {
                continue
            }
        }
        guard urls.allSatisfy({ !operations.fileExists($0) }) else {
            hasVerifiedScrubRevocation = false
            throw KeyboardSnapshotPublisherError.revocationFenceUnavailable
        }
    }
}
