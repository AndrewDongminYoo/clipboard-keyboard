import Foundation

public struct PrivacyGate: Sendable {
    public init() {}

    public func evaluate(_ metadata: PasteboardEventMetadata, policy: CapturePolicy) -> PrivacyDecision {
        guard policy.consentGranted else {
            return .drop(.consentNotGranted)
        }

        let declaredTypes = Set(metadata.declaredTypeIdentifiers)
        if declaredTypes.contains(policy.privateCopyMarkerTypeIdentifier) {
            return .drop(.privateCopyMarker)
        }
        if !declaredTypes.isDisjoint(with: policy.confidentialTypeIdentifiers) {
            return .drop(.confidentialType)
        }
        guard !metadata.capturePauseActive else {
            return .drop(.capturePaused)
        }
        guard metadata.source.confidence == .inferredStableForeground else {
            return .drop(.unknownSource)
        }
        if let identity = metadata.source.identity, policy.ignoredApplications.contains(identity) {
            return .drop(.ignoredApplication)
        }
        guard !declaredTypes.isDisjoint(with: policy.supportedPrimaryTextTypeIdentifiers) else {
            return .drop(.unsupportedPrimaryTextType)
        }
        return .authorizeRead(changeCount: metadata.changeCount)
    }
}
