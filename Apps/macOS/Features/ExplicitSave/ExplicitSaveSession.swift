import ClipboardCore
import Foundation

struct ExplicitSaveToken: Equatable, Sendable {
    let changeCount: Int
    let expiresAt: Date
}

struct ExplicitSaveSummary: Equatable, Sendable, CustomStringConvertible {
    let representationKinds: [RepresentationKind]
    let totalByteCount: Int

    var description: String {
        "kinds=\(representationKinds.map(\.rawValue).joined(separator: ","));bytes=\(totalByteCount)"
    }
}

struct ExplicitSaveRequest: Equatable, Sendable {
    let token: ExplicitSaveToken
    let summary: ExplicitSaveSummary
}

enum ExplicitSaveSessionError: Error, Equatable {
    case noPendingSave
    case invalidToken
    case expired
}

@MainActor
final class ExplicitSaveSession {
    typealias ExpirySleep = @Sendable (TimeInterval) async throws -> Void

    private let confirmationInterval: TimeInterval
    private let expirySleep: ExpirySleep
    private var pending: (token: ExplicitSaveToken, representations: [RawTextRepresentation])?
    private var expiryTask: Task<Void, Never>?
    private var generation: UInt = 0

    init(
        confirmationInterval: TimeInterval = 30,
        expirySleep: @escaping ExpirySleep = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.confirmationInterval = confirmationInterval
        self.expirySleep = expirySleep
    }

    deinit {
        expiryTask?.cancel()
    }

    var hasPendingBytes: Bool {
        pending != nil
    }

    func begin(changeCount: Int, representations: [RawTextRepresentation], now: Date) -> ExplicitSaveRequest {
        cancel()
        let token = ExplicitSaveToken(changeCount: changeCount, expiresAt: now.addingTimeInterval(confirmationInterval))
        pending = (token, representations)
        generation &+= 1
        let expiryGeneration = generation
        let expirySleep = expirySleep
        let confirmationInterval = confirmationInterval
        expiryTask = Task { [weak self] in
            do {
                try await expirySleep(confirmationInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expire(generation: expiryGeneration)
        }
        return ExplicitSaveRequest(
            token: token,
            summary: ExplicitSaveSummary(
                representationKinds: representations.map(\.kind),
                totalByteCount: representations.reduce(0) { $0 + $1.data.count }
            )
        )
    }

    func takeForConfirmation(token: ExplicitSaveToken, now: Date) throws -> [RawTextRepresentation] {
        guard let pending else {
            throw ExplicitSaveSessionError.noPendingSave
        }
        purge()
        guard pending.token == token else {
            throw ExplicitSaveSessionError.invalidToken
        }
        guard now <= token.expiresAt else {
            throw ExplicitSaveSessionError.expired
        }
        return pending.representations
    }

    func pasteboardDidChange(to changeCount: Int) {
        guard let pending, pending.token.changeCount != changeCount else { return }
        purge()
    }

    func cancel() {
        purge()
    }

    private func expire(generation: UInt) {
        guard generation == self.generation else { return }
        purge()
    }

    private func purge() {
        generation &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        pending = nil
    }
}
