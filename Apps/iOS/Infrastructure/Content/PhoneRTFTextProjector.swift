import Foundation
import UIKit

enum PhoneRTFTextProjectorError: Error, Equatable {
    case invalidRTF
}

struct PhoneRTFTextProjector: Sendable {
    func project(_ data: Data) throws -> String {
        do {
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
        } catch {
            throw PhoneRTFTextProjectorError.invalidRTF
        }
    }
}
