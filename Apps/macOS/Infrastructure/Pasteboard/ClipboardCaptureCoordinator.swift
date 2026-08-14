import ClipboardCore
import Foundation

@MainActor
protocol ClipEnvelopeBuilding: AnyObject {
    func makeEnvelope(
        from content: ResolvedTextContent,
        sourceConfidence: SourceConfidence,
        retentionClass: RetentionClass
    ) throws -> ClipEnvelope
}

@MainActor
final class MacClipEnvelopeBuilder: ClipEnvelopeBuilding {
    private let digestProvider: (Data) throws -> Data
    private let now: () -> Date

    init(digestProvider: @escaping (Data) throws -> Data, now: @escaping () -> Date = Date.init) {
        self.digestProvider = digestProvider
        self.now = now
    }

    func makeEnvelope(
        from content: ResolvedTextContent,
        sourceConfidence: SourceConfidence,
        retentionClass: RetentionClass
    ) throws -> ClipEnvelope {
        let representations = try content.originals.map { original in
            try ClipRepresentation(
                kind: original.kind,
                originalBytes: original.data,
                keyedDigest: digestProvider(original.data)
            )
        }
        let insertionString = content.insertionString
        let firstLine = insertionString.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = String(firstLine.prefix(80))
        let preview = String(insertionString.prefix(500))
        let kinds = Set(content.originals.map(\.kind))
        let contentKind: ContentKind = if kinds.contains(.rtf) || kinds.contains(.html) {
            .richText
        } else if kinds.contains(.markdown) {
            .markdown
        } else {
            .plainText
        }
        return ClipEnvelope(
            id: UUID(),
            capturedAt: now(),
            retentionClass: retentionClass,
            sourceConfidence: sourceConfidence,
            representations: representations,
            canonicalInsertionString: insertionString,
            title: title,
            contentKind: contentKind,
            category: nil,
            preview: preview,
            valueCandidates: ValueExtractor().candidates(in: insertionString)
        )
    }
}

@MainActor
final class ClipboardCaptureCoordinator {
    typealias Commit = @MainActor (ClipEnvelope) async throws -> Void

    private let pasteboard: any MacPasteboardReading
    private let sourceTracker: any SourceObservationTracking
    private let policy: CapturePolicy
    private let envelopeBuilder: any ClipEnvelopeBuilding
    private let commit: Commit
    private let now: () -> Date
    private var lastObservedChangeCount: Int?
    private var capturePauseDeadline: Date?
    let explicitSaveSession: ExplicitSaveSession

    init(
        pasteboard: any MacPasteboardReading,
        sourceTracker: any SourceObservationTracking,
        policy: CapturePolicy,
        envelopeBuilder: any ClipEnvelopeBuilding,
        explicitSaveSession: ExplicitSaveSession = .init(),
        commit: @escaping Commit,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.sourceTracker = sourceTracker
        self.policy = policy
        self.envelopeBuilder = envelopeBuilder
        self.explicitSaveSession = explicitSaveSession
        self.commit = commit
        self.now = now
        sourceTracker.beginInterval()
    }

    func poll() async {
        let metadata = pasteboard.readMetadata()
        let source = sourceTracker.finishInterval()
        sourceTracker.beginInterval()
        explicitSaveSession.pasteboardDidChange(to: metadata.changeCount)
        guard metadata.changeCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = metadata.changeCount

        let eventMetadata = PasteboardEventMetadata(
            changeCount: metadata.changeCount,
            declaredTypeIdentifiers: metadata.declaredTypeIdentifiers,
            source: source,
            capturePauseActive: isCapturePaused
        )
        guard case let .authorizeRead(changeCount) = PrivacyGate().evaluate(eventMetadata, policy: policy),
              let representations = try? pasteboard.readSupportedRepresentations(for: changeCount),
              let content = try? RepresentationResolver().resolve(representations),
              let envelope = try? envelopeBuilder.makeEnvelope(
                  from: content,
                  sourceConfidence: source.confidence,
                  retentionClass: .localHistory
              )
        else { return }
        try? await commit(envelope)
    }

    func beginExplicitSave() async -> ExplicitSaveRequest? {
        let metadata = pasteboard.readMetadata()
        let source = sourceTracker.finishInterval()
        sourceTracker.beginInterval()
        explicitSaveSession.pasteboardDidChange(to: metadata.changeCount)
        guard explicitSaveAuthorizes(metadata, source: source) else {
            explicitSaveSession.cancel()
            return nil
        }
        do {
            let representations = try pasteboard.readSupportedRepresentations(for: metadata.changeCount)
            return explicitSaveSession.begin(changeCount: metadata.changeCount, representations: representations, now: now())
        } catch {
            explicitSaveSession.cancel()
            return nil
        }
    }

    func confirmExplicitSave(token: ExplicitSaveToken) async -> Bool {
        let metadata = pasteboard.readMetadata()
        _ = sourceTracker.finishInterval()
        sourceTracker.beginInterval()
        explicitSaveSession.pasteboardDidChange(to: metadata.changeCount)
        guard metadata.changeCount == token.changeCount else { return false }
        do {
            let representations = try explicitSaveSession.takeForConfirmation(token: token, now: now())
            let content = try RepresentationResolver().resolve(representations)
            let envelope = try envelopeBuilder.makeEnvelope(
                from: content,
                sourceConfidence: .unknown,
                retentionClass: .localHistory
            )
            try await commit(envelope)
            return true
        } catch {
            explicitSaveSession.cancel()
            return false
        }
    }

    func pauseCapture(for duration: TimeInterval) {
        capturePauseDeadline = now().addingTimeInterval(max(0, duration))
    }

    func resumeCapture() {
        capturePauseDeadline = nil
    }

    private var isCapturePaused: Bool {
        guard let capturePauseDeadline else { return false }
        return now() < capturePauseDeadline
    }

    private func explicitSaveAuthorizes(_ metadata: MacPasteboardMetadata, source: SourceObservation) -> Bool {
        guard policy.consentGranted else { return false }
        let declaredTypes = Set(metadata.declaredTypeIdentifiers)
        guard !declaredTypes.contains(policy.privateCopyMarkerTypeIdentifier),
              declaredTypes.isDisjoint(with: policy.confidentialTypeIdentifiers),
              !isCapturePaused
        else { return false }
        if source.confidence == .inferredStableForeground,
           let identity = source.identity,
           policy.ignoredApplications.contains(identity)
        {
            return false
        }
        return !declaredTypes.isDisjoint(with: policy.supportedPrimaryTextTypeIdentifiers)
    }
}
