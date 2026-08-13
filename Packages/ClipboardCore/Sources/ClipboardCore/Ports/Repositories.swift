import Foundation

public protocol ClipPersisting: Sendable {
    associatedtype Clip: Sendable

    func save(_ clip: Clip) async throws
    func load(id: UUID) async throws -> Clip?
    func listMetadata() async throws -> [ClipMetadata]
    func delete(id: UUID) async throws
    func delete(ids: Set<UUID>) async throws
}
