import UIKit

enum SystemPasteboardWriterError: Error, Equatable {
    case writeFailed
}

@MainActor
struct SystemPasteboardWriter {
    private let writeString: (String) -> Bool

    init(writeString: @escaping (String) -> Bool = { value in
        UIPasteboard.general.string = value
        return true
    }) {
        self.writeString = writeString
    }

    func write(_ value: String) throws {
        guard writeString(value) else {
            throw SystemPasteboardWriterError.writeFailed
        }
    }
}
