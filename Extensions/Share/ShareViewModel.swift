import ClipboardCore
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol ShareItemProviding: AnyObject {
    var registeredTypeIdentifiers: [String] { get }
    var canLoadStringObject: Bool { get }
    var canLoadURLObject: Bool { get }
    func loadStringObject(forTypeIdentifier typeIdentifier: String) async throws -> String
    func loadURLObject(forTypeIdentifier typeIdentifier: String) async throws -> URL
}

enum ShareViewState: Equatable {
    case idle
    case loading
    case ready
    case writing
    case writeFailed
    case rejected
    case cancelled
    case failed
}

enum ShareCompletion: Equatable {
    case queuedForContainingApp
}

@MainActor
final class ShareViewModel: ObservableObject {
    @Published private(set) var state: ShareViewState = .idle
    @Published private(set) var preview = ""
    @Published private(set) var completion: ShareCompletion?

    private let writer: any ShareInboxWriting
    private let previewLimit: Int
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var item: ShareInboxItem?
    private var loadTask: Task<ShareLoadedItem, Error>?
    private var pinTask: Task<URL, Error>?
    private var lifecycleEpoch: UInt64 = 0

    init(
        writer: any ShareInboxWriting,
        previewLimit: Int = 240,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.writer = writer
        self.previewLimit = previewLimit
        self.now = now
        self.makeID = makeID
    }

    func open(providers: [any ShareItemProviding]) async {
        purgeDecodedContent()
        completion = nil
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        guard providers.count == 1,
              let selected = Self.selectRepresentation(from: providers[0].registeredTypeIdentifiers)
        else {
            state = .rejected
            return
        }
        state = .loading
        let provider = providers[0]
        let task = Task { try await Self.load(selected, from: provider) }
        loadTask = task
        do {
            let loaded = try await task.value
            try Task.checkCancellation()
            guard epoch == lifecycleEpoch else { return }
            let item = try ShareInboxItem.make(
                id: makeID(),
                createdAt: now(),
                kind: loaded.kind,
                data: loaded.data
            )
            self.item = item
            preview = Self.boundedPreview(loaded.semanticValue, limit: previewLimit)
            state = .ready
        } catch is CancellationError {
            guard epoch == lifecycleEpoch else { return }
            purgeDecodedContent()
            state = .cancelled
        } catch {
            guard epoch == lifecycleEpoch else { return }
            purgeDecodedContent()
            state = .failed
        }
        if epoch == lifecycleEpoch {
            loadTask = nil
        }
    }

    func pin() async throws {
        guard pinTask == nil else { return }
        guard let item, state == .ready || state == .writeFailed else {
            throw ShareInboxWriterError.invalidItem
        }
        try Task.checkCancellation()
        let epoch = lifecycleEpoch
        state = .writing
        let task = Task { try await writer.write(item) }
        pinTask = task
        do {
            _ = try await task.value
            guard epoch == lifecycleEpoch else { return }
            pinTask = nil
            completion = .queuedForContainingApp
            purgeDecodedContent()
        } catch {
            guard epoch == lifecycleEpoch else { throw error }
            pinTask = nil
            if error is CancellationError {
                purgeDecodedContent()
                state = .cancelled
                throw CancellationError()
            }
            state = .writeFailed
            throw error
        }
    }

    func cancel() {
        lifecycleEpoch &+= 1
        loadTask?.cancel()
        loadTask = nil
        pinTask?.cancel()
        pinTask = nil
        completion = nil
        purgeDecodedContent()
        state = .cancelled
    }

    func expire() {
        cancel()
    }

    func protectedDataWillBecomeUnavailable() {
        cancel()
    }

    private func purgeDecodedContent() {
        item = nil
        preview = ""
    }

    private static func selectRepresentation(
        from identifiers: [String]
    ) -> ShareSelectedRepresentation? {
        let hasVetoedType = identifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .fileURL) || type.conforms(to: .image)
        }
        guard !hasVetoedType else {
            return nil
        }
        if identifiers.contains(ShareSelectedRepresentation.webURLIdentifier) {
            return .url
        }
        if let identifier = identifiers.first(where: ShareSelectedRepresentation.plainTextIdentifiers.contains) {
            return .text(identifier)
        }
        return nil
    }

    private static func load(
        _ selection: ShareSelectedRepresentation,
        from provider: any ShareItemProviding
    ) async throws -> ShareLoadedItem {
        switch selection {
        case let .text(identifier):
            guard provider.canLoadStringObject else { throw ShareInboxWriterError.invalidItem }
            let value = try canonicalText(await provider.loadStringObject(forTypeIdentifier: identifier))
            return ShareLoadedItem(kind: .text, data: Data(value.utf8), semanticValue: value)
        case .url:
            guard provider.canLoadURLObject else { throw ShareInboxWriterError.invalidItem }
            let url = try await provider.loadURLObject(
                forTypeIdentifier: ShareSelectedRepresentation.webURLIdentifier
            )
            guard !url.isFileURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false
            else {
                throw ShareInboxWriterError.invalidItem
            }
            let value = url.absoluteString
            return ShareLoadedItem(kind: .url, data: Data(value.utf8), semanticValue: value)
        }
    }

    private static func canonicalText(_ value: String) -> String {
        value.first == "\u{FEFF}" ? String(value.dropFirst()) : value
    }

    private static func boundedPreview(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\u{2026}"
    }
}

private enum ShareSelectedRepresentation: Sendable {
    static let webURLIdentifier = "public.url"
    static let plainTextIdentifiers: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-external-plain-text",
        "public.utf16-plain-text",
        "public.plain-text",
    ]

    case text(String)
    case url
}

private struct ShareLoadedItem: Sendable {
    let kind: ShareInboxItemKind
    let data: Data
    let semanticValue: String
}
