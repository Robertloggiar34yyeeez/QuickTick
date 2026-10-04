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
        guard response.exists else { return (nil, response.updatedAt) }
        guard let envelope = response.payload else { throw QuicktickSyncCryptoError.invalidEnvelope }
        return (try QuicktickSyncCrypto.decrypt(QuicktickSyncSnapshot.self, envelope: envelope, syncID: syncID), response.updatedAt)
    }

    func push(syncID: String, snapshot: QuicktickSyncSnapshot) async throws {
        let encrypted = try QuicktickSyncCrypto.encrypt(snapshot, syncID: syncID)
        let data = try await api.sync(action: "put", recordID: encrypted.recordID, verifier: encrypted.verifier, payload: encrypted.envelope)
        struct PutResponse: Decodable { let ok: Bool }
        guard try JSONDecoder().decode(PutResponse.self, from: data).ok else { throw APIError.server("The server did not save the cloud profile.") }
    }
}
