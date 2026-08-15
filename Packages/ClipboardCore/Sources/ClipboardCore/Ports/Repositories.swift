import Foundation

public protocol ClipPersisting: Sendable {
    associatedtype Clip: Sendable

    func save(_ clip: Clip) async throws
    func load(id: UUID) async throws -> Clip?
    func listMetadata() async throws -> [ClipMetadata]
    func delete(id: UUID) async throws
    func delete(ids: Set<UUID>) async throws
}

public protocol PinnedLibrary: Sendable {
    func allItems() async throws -> [PinnedRevision]
    func search(_ query: String, limit: Int) async throws -> [PinnedRevision]
    func pin(_ payload: PinPayload) async throws -> PinnedRevision
    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision
    func delete(itemID: UUID) async throws -> PinnedTombstone
    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome
    func advanceResetGeneration() async throws -> LibraryResetGeneration
}
