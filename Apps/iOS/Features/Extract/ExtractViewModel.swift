import ClipboardCore
import Foundation

enum ExtractCandidateVariant: Equatable, Sendable {
    case original
    case digitsOnly
    case normalized
}

enum ExtractViewModelError: Error, Equatable {
    case unavailableVariant
    case invalidRepresentation
    case staleCandidate
}

@MainActor
final class ExtractViewModel: ObservableObject {
    @Published private(set) var sourceText: String?
    @Published private(set) var candidates: [ValueCandidate] = []
    @Published var selectedCandidate: ValueCandidate?
    @Published private(set) var errorMessage: String?

    private let library: any PinnedLibrary
    private let representations: @MainActor @Sendable (String) async throws -> [ClipRepresentation]
    private let pasteboardWriter: SystemPasteboardWriter
    private let extractor = ValueExtractor()
    private var intentRevision: UInt64 = 0

    init(
        library: any PinnedLibrary,
        representations: @escaping @MainActor @Sendable (String) async throws -> [ClipRepresentation],
        pasteboardWriter: SystemPasteboardWriter = SystemPasteboardWriter()
    ) {
        self.library = library
        self.representations = representations
        self.pasteboardWriter = pasteboardWriter
    }

    func acceptPastedText(_ text: String) {
        purge()
        guard !text.isEmpty else { return }
        let extracted = extractor.candidates(in: text)
        sourceText = text
        candidates = extracted
        selectedCandidate = extracted.first
    }

    func availableVariants(for candidate: ValueCandidate) -> [ExtractCandidateVariant] {
        var variants: [ExtractCandidateVariant] = [.original]
        if candidate.digitsOnly != nil {
            variants.append(.digitsOnly)
        }
        if candidate.normalized != nil {
            variants.append(.normalized)
        }
        return variants
    }

    func copyCandidate(_ candidate: ValueCandidate, variant: ExtractCandidateVariant) throws {
        guard candidates.contains(candidate) else {
            throw ExtractViewModelError.staleCandidate
        }
        do {
            try pasteboardWriter.write(value(for: candidate, variant: variant))
            purge()
        } catch {
            errorMessage = "Unable to copy the selected value."
            throw error
        }
    }

    func pinCandidate(_ candidate: ValueCandidate, variant: ExtractCandidateVariant) async throws {
        guard candidates.contains(candidate) else {
            throw ExtractViewModelError.staleCandidate
        }
        let value = try value(for: candidate, variant: variant)
        let intent = intentRevision
        do {
            let rendered = try await representations(value)
            guard intent == intentRevision, candidates.contains(candidate) else {
                throw ExtractViewModelError.staleCandidate
            }
            guard rendered.count == 1,
                  rendered[0].kind == .plainText,
                  rendered[0].originalBytes == Data(value.utf8),
                  !rendered[0].keyedDigest.isEmpty
            else {
                throw ExtractViewModelError.invalidRepresentation
            }
            let payload = PinPayload(
                representations: rendered,
                canonicalInsertionString: value,
                title: "Extracted Value",
                contentKind: .plainText,
                category: nil
            )
            _ = try await library.pin(payload)
            guard intent == intentRevision else { return }
            purge()
        } catch {
            guard intent == intentRevision else { throw error }
            if let protectedError = error as? EncryptedPhonePinnedStoreError,
               protectedError == .protectedDataUnavailable
            {
                protectedDataWillBecomeUnavailable()
            } else {
                errorMessage = "Unable to pin the selected value."
            }
            throw error
        }
    }

    func cancel() {
        purge()
    }

    func protectedDataWillBecomeUnavailable() {
        purge()
    }

    func viewDidDisappear() {
        purge()
    }

    private func value(for candidate: ValueCandidate, variant: ExtractCandidateVariant) throws -> String {
        switch variant {
        case .original:
            candidate.original
        case .digitsOnly:
            try candidate.digitsOnly.unwrap(or: ExtractViewModelError.unavailableVariant)
        case .normalized:
            try candidate.normalized.unwrap(or: ExtractViewModelError.unavailableVariant)
        }
    }

    private func purge() {
        intentRevision &+= 1
        sourceText = nil
        candidates.removeAll(keepingCapacity: false)
        selectedCandidate = nil
        errorMessage = nil
    }
}

private extension Optional {
    func unwrap(or error: any Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}
