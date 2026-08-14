import CryptoKit
import Foundation

public enum ShareInboxItemKind: String, Codable, Equatable, Sendable {
    case text
    case url
}

public enum ShareInboxItemValidationFailure: Error, Equatable, Sendable {
    case malformed
    case unsupportedSchema
    case digestMismatch
    case emptyData
    case invalidUTF8
    case invalidURL
}

public enum ShareInboxItemValidationResult: Equatable, Sendable {
    case valid(ShareInboxItem)
    case invalid(ShareInboxItemValidationFailure)
}

public struct ShareInboxItem: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let kind: ShareInboxItemKind
    public let data: Data
    public let digest: String

    public init(
        schemaVersion: Int,
        id: UUID,
        createdAt: Date,
        kind: ShareInboxItemKind,
        data: Data,
        digest: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.data = data
        self.digest = digest
    }

    @available(macOS 10.15, iOS 13.0, *)
    public static func make(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: ShareInboxItemKind,
        data: Data
    ) throws -> ShareInboxItem {
        try validatePayload(kind: kind, data: data)
        return try ShareInboxItem(
            schemaVersion: currentSchemaVersion,
            id: id,
            createdAt: createdAt,
            kind: kind,
            data: data,
            digest: digest(
                schemaVersion: currentSchemaVersion,
                id: id,
                createdAt: createdAt,
                kind: kind,
                data: data
            )
        )
    }

    @available(macOS 10.15, iOS 13.0, *)
    public static func digest(
        schemaVersion: Int,
        id: UUID,
        createdAt: Date,
        kind: ShareInboxItemKind,
        data: Data
    ) throws -> String {
        let unsigned = UnsignedShareInboxItem(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            kind: kind,
            data: data
        )
        return try SHA256.hash(data: ShareInboxItemCodec.encoder.encode(unsigned)).hexString
    }

    fileprivate static func validatePayload(kind: ShareInboxItemKind, data: Data) throws {
        guard !data.isEmpty else { throw ShareInboxItemValidationFailure.emptyData }
        guard let value = String(data: data, encoding: .utf8) else {
            throw ShareInboxItemValidationFailure.invalidUTF8
        }
        if kind == .url {
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false
            else {
                throw ShareInboxItemValidationFailure.invalidURL
            }
        }
    }
}

public struct ShareInboxItemCodec: Sendable {
    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public init() {}

    public func encode(_ item: ShareInboxItem) throws -> Data {
        try Self.encoder.encode(item)
    }

    public func decode(_ data: Data) throws -> ShareInboxItem {
        try Self.decoder.decode(ShareInboxItem.self, from: data)
    }
}

@available(macOS 10.15, iOS 13.0, *)
public struct ShareInboxItemValidator: Sendable {
    public init() {}

    public func validate(_ data: Data) -> ShareInboxItemValidationResult {
        let item: ShareInboxItem
        do {
            item = try ShareInboxItemCodec().decode(data)
        } catch {
            return .invalid(.malformed)
        }
        guard item.schemaVersion == ShareInboxItem.currentSchemaVersion else {
            return .invalid(.unsupportedSchema)
        }
        let expectedDigest: String
        do {
            expectedDigest = try ShareInboxItem.digest(
                schemaVersion: item.schemaVersion,
                id: item.id,
                createdAt: item.createdAt,
                kind: item.kind,
                data: item.data
            )
        } catch {
            return .invalid(.malformed)
        }
        guard item.digest == expectedDigest else { return .invalid(.digestMismatch) }
        do {
            try ShareInboxItem.validatePayload(kind: item.kind, data: item.data)
        } catch let failure as ShareInboxItemValidationFailure {
            return .invalid(failure)
        } catch {
            return .invalid(.malformed)
        }
        return .valid(item)
    }
}

private struct UnsignedShareInboxItem: Encodable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let kind: ShareInboxItemKind
    let data: Data
}

@available(macOS 10.15, iOS 13.0, *)
private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
