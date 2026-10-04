import Foundation

struct SyncGetResponse: Codable, Sendable {
    var exists: Bool
    var payload: SyncEnvelope?
    var updatedAt: Int64?
}

actor QuicktickSyncService {
    let api: QuicktickAPIClient
    init(api: QuicktickAPIClient) { self.api = api }

    func pull(syncID: String) async throws -> (QuicktickSyncSnapshot?, Int64?) {
        let material = try QuicktickSyncCrypto.derive(syncID)
        let data = try await api.sync(action: "get", recordID: material.parsed.recordID, verifier: material.verifier)
        let response = try JSONDecoder().decode(SyncGetResponse.self, from: data)
        guard response.exists, let envelope = response.payload else { return (nil, response.updatedAt) }
        return (try QuicktickSyncCrypto.decrypt(QuicktickSyncSnapshot.self, envelope: envelope, syncID: syncID), response.updatedAt)
    }

    func push(syncID: String, snapshot: QuicktickSyncSnapshot) async throws {
        let encrypted = try QuicktickSyncCrypto.encrypt(snapshot, syncID: syncID)
        _ = try await api.sync(action: "put", recordID: encrypted.recordID, verifier: encrypted.verifier, payload: encrypted.envelope)
    }
}
