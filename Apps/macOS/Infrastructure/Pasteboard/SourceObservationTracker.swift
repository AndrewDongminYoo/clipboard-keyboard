import AppKit
import ClipboardCore
import Foundation
import Security

struct SourceSnapshot: Equatable, Sendable {
    let identity: ApplicationIdentity?
    let activationGeneration: UInt
    let helperAmbiguous: Bool
}

enum SourceSnapshotError: Error {
    case lookupFailed
}

@MainActor
protocol SourceSnapshotProviding: AnyObject {
    func snapshot() throws -> SourceSnapshot
}

@MainActor
protocol SourceObservationTracking: AnyObject {
    func beginInterval()
    func finishInterval() -> SourceObservation
}

@MainActor
final class SourceObservationTracker: SourceObservationTracking {
    private let provider: any SourceSnapshotProviding
    private var beginning: Result<SourceSnapshot, SourceSnapshotError>?

    init(provider: any SourceSnapshotProviding = WorkspaceSourceSnapshotProvider()) {
        self.provider = provider
    }

    func beginInterval() {
        beginning = Result { try provider.snapshot() }.mapError { _ in .lookupFailed }
    }

    func finishInterval() -> SourceObservation {
        defer { beginning = nil }
        guard let beginning,
              case let .success(first) = beginning,
              let second = try? provider.snapshot(),
              let identity = first.identity,
              identity == second.identity,
              first.activationGeneration == second.activationGeneration,
              !first.helperAmbiguous,
              !second.helperAmbiguous
        else {
            return .init(identity: nil, confidence: .unknown)
        }
        return .init(identity: identity, confidence: .inferredStableForeground)
    }
}

@MainActor
final class WorkspaceSourceSnapshotProvider: SourceSnapshotProviding {
    private final class ActivationEpoch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt = 0

        func increment() {
            lock.withLock { value &+= 1 }
        }

        func current() -> UInt {
            lock.withLock { value }
        }
    }

    private nonisolated(unsafe) let workspace: NSWorkspace
    private let activationEpoch = ActivationEpoch()
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        let activationEpoch = activationEpoch
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { _ in
            activationEpoch.increment()
        }
    }

    deinit {
        if let observer {
            workspace.notificationCenter.removeObserver(observer)
        }
    }

    func snapshot() throws -> SourceSnapshot {
        guard let application = workspace.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier
        else {
            throw SourceSnapshotError.lookupFailed
        }
        let helperAmbiguous = application.activationPolicy != .regular
        let identity = try signingIdentity(processIdentifier: application.processIdentifier, bundleIdentifier: bundleIdentifier)
        return .init(
            identity: identity,
            activationGeneration: activationEpoch.current(),
            helperAmbiguous: helperAmbiguous
        )
    }

    private func signingIdentity(processIdentifier: pid_t, bundleIdentifier: String) throws -> ApplicationIdentity {
        let attributes = [kSecGuestAttributePid: processIdentifier] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            throw SourceSnapshotError.lookupFailed
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw SourceSnapshotError.lookupFailed
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
              !teamIdentifier.isEmpty,
              !signingIdentifier.isEmpty
        else {
            throw SourceSnapshotError.lookupFailed
        }
        return ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier
        )
    }
}
