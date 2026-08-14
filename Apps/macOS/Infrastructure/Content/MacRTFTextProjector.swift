import AppKit
import Foundation

enum MacRTFTextProjectorError: Error, Equatable {
    case invalidRTF
}

struct MacRTFTextProjector: Sendable {
    func project(_ data: Data) throws -> String {
        do {
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
        } catch {
            throw MacRTFTextProjectorError.invalidRTF
        }
    }
}
