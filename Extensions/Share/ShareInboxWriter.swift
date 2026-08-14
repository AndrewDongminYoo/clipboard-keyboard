import ClipboardCore
import Darwin
import Foundation

enum ShareInboxWriterError: Error, Equatable {
    case invalidItem
    case protectionFailed
    case writeFailed
}

protocol ShareInboxWriting: Sendable {
    func write(_ item: ShareInboxItem) async throws -> URL
}

struct ShareInboxFileOperations: @unchecked Sendable {
    let fileExists: (URL) -> Bool
    let createDirectory: (URL) throws -> Void
    let createEmpty: (URL) throws -> Void
    let setCompleteProtection: (URL) throws -> Void
    let protection: (URL) throws -> FileProtectionType?
    let writeAndSync: (Data, URL) throws -> Void
    let read: (URL) throws -> Data
    let replace: (URL, URL) throws -> Void
    let removeIfExists: (URL) throws -> Void

    static let live = ShareInboxFileOperations(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        createEmpty: { url in
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw ShareInboxWriterError.writeFailed
            }
            guard Darwin.close(descriptor) == 0 else {
                try? FileManager.default.removeItem(at: url)
                throw ShareInboxWriterError.writeFailed
            }
        },
        setCompleteProtection: { url in
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        },
        protection: { url in
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            if let protection = value as? FileProtectionType {
                return protection
            }
            if let rawValue = value as? String {
                return FileProtectionType(rawValue: rawValue)
            }
            return nil
        },
        writeAndSync: { data, url in
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        },
        read: { try Data(contentsOf: $0) },
        replace: { temporary, final in try FileManager.default.moveItem(at: temporary, to: final) },
        removeIfExists: { url in
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    )
}

actor ShareInboxWriter: ShareInboxWriting {
    static let appGroupIdentifier = "group.kr.donminzzi.clipboardkeyboard"

    private let directory: URL
    private let operations: ShareInboxFileOperations
    private let temporaryID: @Sendable () -> UUID
    private let beforePublish: @Sendable () async throws -> Void

    init(
        directory: URL,
        operations: ShareInboxFileOperations = .live,
        temporaryID: @escaping @Sendable () -> UUID = UUID.init,
        beforePublish: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.directory = directory
        self.operations = operations
        self.temporaryID = temporaryID
        self.beforePublish = beforePublish
    }

    static func live() throws -> ShareInboxWriter {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ShareInboxWriterError.writeFailed
        }
        return ShareInboxWriter(directory: container.appendingPathComponent("share-inbox", isDirectory: true))
    }

    func write(_ item: ShareInboxItem) async throws -> URL {
        try Task.checkCancellation()
        let encoded = try ShareInboxItemCodec().encode(item)
        guard ShareInboxItemValidator().validate(encoded) == .valid(item) else {
            throw ShareInboxWriterError.invalidItem
        }
        let finalURL = directory.appendingPathComponent(Self.finalFilename(for: item.id))
        guard !operations.fileExists(finalURL) else { throw ShareInboxWriterError.writeFailed }
        let temporaryURL = directory.appendingPathComponent(
            ".share-v1-\(item.id.uuidString.lowercased()).\(temporaryID().uuidString.lowercased()).tmp"
        )
        guard !operations.fileExists(temporaryURL) else { throw ShareInboxWriterError.writeFailed }
        var temporaryWasCreated = false
        var finalWasPublished = false
        do {
            try operations.createDirectory(directory)
            try operations.createEmpty(temporaryURL)
            temporaryWasCreated = true
            try operations.setCompleteProtection(temporaryURL)
            try verifyProtection(at: temporaryURL)
            try operations.writeAndSync(encoded, temporaryURL)
            try verifyProtection(at: temporaryURL)
            try verifyItem(item, at: temporaryURL)
            try Task.checkCancellation()
            try await beforePublish()
            try Task.checkCancellation()
            try operations.replace(temporaryURL, finalURL)
            finalWasPublished = true
            try operations.setCompleteProtection(finalURL)
            try verifyProtection(at: finalURL)
            try verifyItem(item, at: finalURL)
            return finalURL
        } catch is CancellationError {
            if temporaryWasCreated {
                try? operations.removeIfExists(temporaryURL)
            }
            if finalWasPublished {
                try? operations.removeIfExists(finalURL)
            }
            throw CancellationError()
        } catch {
            if temporaryWasCreated {
                try? operations.removeIfExists(temporaryURL)
            }
            if finalWasPublished {
                try? operations.removeIfExists(finalURL)
            }
            if let writerError = error as? ShareInboxWriterError {
                throw writerError
            }
            throw ShareInboxWriterError.writeFailed
        }
    }

    static func finalFilename(for id: UUID) -> String {
        "share-v1-\(id.uuidString.lowercased()).json"
    }

    private func verifyProtection(at url: URL) throws {
        guard try operations.protection(url) == .complete else {
            throw ShareInboxWriterError.protectionFailed
        }
    }

    private func verifyItem(_ expected: ShareInboxItem, at url: URL) throws {
        guard try ShareInboxItemValidator().validate(operations.read(url)) == .valid(expected) else {
            throw ShareInboxWriterError.invalidItem
        }
    }
}
