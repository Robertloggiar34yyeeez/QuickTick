import XCTest
@testable import QuicktickNative

final class SyncCryptoTests: XCTestCase {
    func testCredentialsRoundTripWithoutRememberingLocally() throws {
        let id = QuicktickSyncCrypto.generate()
        var snapshot = QuicktickSyncSnapshot.empty
        snapshot.rule34.credentials = .init(userId: "synthetic-user", apiKey: "synthetic-key", remember: false)
        snapshot.pornhub.auth = .init(username: "synthetic-name", session: "synthetic-session")
        let envelope = try QuicktickSyncCrypto.encrypt(snapshot, syncID: id).envelope
        let decoded = try QuicktickSyncCrypto.decrypt(QuicktickSyncSnapshot.self, envelope: envelope, syncID: id)
        XCTAssertEqual(decoded.rule34.credentials, snapshot.rule34.credentials)
        XCTAssertEqual(decoded.pornhub.auth, snapshot.pornhub.auth)
    }

    func testGeneratedIDsAndInvalidEnvelope() throws {
        let generated = QuicktickSyncCrypto.generate()
        XCTAssertEqual(try QuicktickSyncCrypto.parse(generated).secret.count, 32)
        XCTAssertThrowsError(try QuicktickSyncCrypto.parse("QT6-invalid.invalid"))
        XCTAssertThrowsError(try QuicktickSyncCrypto.decrypt(QuicktickSyncSnapshot.self, envelope: SyncEnvelope(v: 1, alg: "A256GCM", iv: "AA", data: "AA"), syncID: generated))
    }
    let syncID = "QT6-AAECAwQFBgcICQoLDA0ODw.ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"

    func testDerivationMatchesWebVector() throws {
        let material = try QuicktickSyncCrypto.derive(syncID)
        XCTAssertEqual(material.parsed.recordID, "AAECAwQFBgcICQoLDA0ODw")
        XCTAssertEqual(material.verifier, "fFAAZEZr-giKKrmWnXERj4O2hjwNq6DDvzK74KjPaD4")
    }

    func testDecryptsWebEnvelope() throws {
        let envelope = SyncEnvelope(v: 1, alg: "A256GCM", iv: "QEFCQ0RFRkdISUpL", data: Self.dataVector)
        let value = try QuicktickSyncCrypto.decrypt(QuicktickSyncSnapshot.self, envelope: envelope, syncID: syncID)
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.exclusions.tags, ["example_excluded"])
        XCTAssertEqual(value.preferences.value.sources["rule34"]?.into, ["animated"])
    }

    static let dataVector = "49v-9DkmHCtJyokdPeEVRt00K2gs7G7VaZj0K-JD0Em8eOwd31sDCLNgKqiJSaLUTC4oBrrQcDL35qaT-Pjz9zQC27GkHT2oA9SJ7rdbyBLP23hZCKoKjhMu6k3B3ZBvVf7AaRQPPagmbChLbR5oxoSRj7UM6iL8usioQeIyO_rncQ09VetTiijVaQXYKD1pCdnVe3pI0rY5tXxpuWeKone_M_TnyQWia8CEeKIbbKARXOqG_5wfI4--m3n5_rFuGx75_LRAKjRyxmsgCKU2ztrUsvsrTRXnQQb44XnDZ20or0bE9-l9kinhu9oekqnTHl5GreuhKQn4A4RjSUUJZY76KA2_J6AoRiPKLK5JfxYuA5L9CUaCW79BaCIleP_sXaKlMtrZ0O0LS_jKkcoP6pH_NJnDDKdH3NkROfxm-V5Xef4Dcph7_eA9vi3leD8jnR4MxVyt7qXhugcqD_tsv_WLjBQyrL9-jBEwZHUCJFgpIpVIkndl5Vi3nexcamAGnWjjuyXV1M1j0PY_G0eNaTYXdo6fPpUs8spa3N-foVnz_1SYlzF4lfX6WXivwpPesFuBw86L1iambpkpQ4q1nanLn2xW-Z_NaVaaNgkcc4KllioIrbiDYx7i4CRAlVSKltk5y5Hz9PtQBGdjmDjlq_FfAKHn47a_DkHI6K4znfDLwEhLwESqaNMHKfZvsN5qEBj6hoBgVccS30-9yCS7ZOkisA0C4SgfIVapmv9O5kXdWud2WISK_l2pFhaWTPW0713obex0wG43DsJtDC9c8Q1ARu8_0IKTkIZlhGPQKtA0eRi5NN4KzOlmUA"
}
