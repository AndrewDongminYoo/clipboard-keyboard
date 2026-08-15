import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class PhoneCloudDataDeleterTests: XCTestCase {
    func testDeleteRecreatesZoneAndSavesExactlyOneResetInOrder() async throws {
        let calls = CloudDataDeletionCalls()
        let expected = reset(1)
        let deleter = PhoneCloudDataDeleter(
            operations: PhoneCloudDataDeletionOperations(
                verifyAccount: { await calls.append("account") },
                deleteZone: { await calls.append("delete-zone") },
                recreateZone: { await calls.append("recreate-zone") },
                saveReset: { reset in
                    XCTAssertEqual(reset, expected)
                    await calls.append("save-reset")
                }
            )
        )

        try await deleter.deleteAllContentKeepingReset(expected)

        let recorded = await calls.snapshot()
        XCTAssertEqual(recorded, ["account", "delete-zone", "recreate-zone", "save-reset"])
    }

    func testDeleteFailureCannotRecreateZoneOrReportResetSaved() async {
        let calls = CloudDataDeletionCalls()
        let deleter = PhoneCloudDataDeleter(
            operations: PhoneCloudDataDeletionOperations(
                verifyAccount: { await calls.append("account") },
                deleteZone: {
                    await calls.append("delete-zone")
                    throw CloudDeletionCoordinatorError.operationFailed
                },
                recreateZone: { await calls.append("recreate-zone") },
                saveReset: { _ in await calls.append("save-reset") }
            )
        )

        await XCTAssertThrowsCloudDeletionError(try await deleter.deleteAllContentKeepingReset(reset(2)))

        let recorded = await calls.snapshot()
        XCTAssertEqual(recorded, ["account", "delete-zone"])
    }

    private func reset(_ suffix: Int) -> LibraryResetGeneration {
        LibraryResetGeneration(
            resetID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            generation: Int64(suffix),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(suffix)),
            deviceID: "test-device"
        )
    }
}

private actor CloudDataDeletionCalls {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

@MainActor
private func XCTAssertThrowsCloudDeletionError(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
