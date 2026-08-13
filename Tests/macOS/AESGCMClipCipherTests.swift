import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import XCTest

final class AESGCMClipCipherTests: XCTestCase {
    func testRoundTripEncryptsAllContent() throws {
        let envelope = makeEnvelope()
        let cipher = AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 11, count: 32)))

        let sealed = try cipher.seal(envelope)

        XCTAssertNil(sealed.range(of: Data(envelope.canonicalInsertionString.utf8)))
        XCTAssertNil(sealed.range(of: Data(envelope.title.utf8)))
        XCTAssertEqual(try cipher.open(sealed), envelope)
    }

    func testRejectsCiphertextBitFlip() throws {
        let cipher = AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 11, count: 32)))
        var sealed = try cipher.seal(makeEnvelope())
        sealed[sealed.index(before: sealed.endIndex)] ^= 0x01

        XCTAssertThrowsError(try cipher.open(sealed)) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .authenticationFailed)
        }
    }

    func testRejectsWrongKey() throws {
        let sealed = try AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 11, count: 32))).seal(makeEnvelope())
        let wrongCipher = AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 12, count: 32)))

        XCTAssertThrowsError(try wrongCipher.open(sealed)) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .authenticationFailed)
        }
    }

    func testRejectsTamperedEnvelopeIDAAD() throws {
        let cipher = AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 11, count: 32)))
        var sealed = try cipher.seal(makeEnvelope())
        sealed[1] ^= 0x01

        XCTAssertThrowsError(try cipher.open(sealed)) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .authenticationFailed)
        }
    }

    func testRejectsCorruptShortRecordWithoutLeakingContent() {
        let cipher = AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 11, count: 32)))

        XCTAssertThrowsError(try cipher.open(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .corruptRecord)
            XCTAssertEqual(String(describing: error), "corruptRecord")
        }
    }

    private func makeEnvelope() -> ClipEnvelope {
        ClipEnvelope(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            retentionClass: .localHistory,
            sourceConfidence: .inferredStableForeground,
            representations: [ClipRepresentation(kind: .plainText, originalBytes: Data("secret-original".utf8), keyedDigest: Data([1, 2, 3]))],
            canonicalInsertionString: "secret-canonical",
            title: "secret-title",
            contentKind: .plainText,
            category: .everyday,
            preview: "secret-preview",
            valueCandidates: [ValueCandidate(kind: .emailAddress, original: "secret@example.com", normalized: "secret@example.com", context: "secret-context")]
        )
    }
}
