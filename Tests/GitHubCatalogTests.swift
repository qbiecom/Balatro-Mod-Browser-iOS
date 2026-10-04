import Foundation
import XCTest
@testable import BMMCore

final class GitHubCatalogTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)

    func testMetadataPreservesLegacyIDFolderAndDependencies() throws {
        let metadata = try JSONDecoder().decode(GitHubIndexMetadata.self, from: metadataData())
        let mod = try metadata.catalogMod(id: "frostice482@Amulet", revision: revision)
        XCTAssertEqual(mod.id, "frostice482@Amulet")
        XCTAssertEqual(mod.installFolderName, "Amulet")
        XCTAssertEqual(mod.version, "4d67d18")
        XCTAssertEqual(mod.requiresSteamodded, false)
        XCTAssertEqual(mod.requiresTalisman, false)
        XCTAssertEqual(mod.updatedAt?.value, 1790794977)
        XCTAssertEqual(mod.downloadURL, "https://github.com/frostice482/amulet/archive/refs/heads/main.zip")
        XCTAssertTrue(mod.thumbnailURL!.absoluteString.contains(revision))
        XCTAssertNil(mod.downloads)
    }

    func testOptionalThumbnailAndZeroTimestamp() throws {
        var json = try JSONSerialization.jsonObject(with: metadataData()) as! [String: Any]
        json["last-updated"] = 0
        let metadata = try JSONDecoder().decode(GitHubIndexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        let mod = try metadata.catalogMod(id: "frostice482@Amulet", revision: revision, hasThumbnail: false)
        XCTAssertNil(mod.thumbnailURL)
        XCTAssertNil(mod.updatedAt)
    }

    func testPinnedContentURLRejectsTraversalAndInvalidRevision() throws {
        for id in ["..", ".", "author/mod", "author\\mod", "bad\u{0}"] {
            XCTAssertThrowsError(try GitHubCatalogService.contentURL(id: id, filename: "meta.json", revision: revision))
        }
        XCTAssertThrowsError(try GitHubCatalogService.contentURL(id: "mod", filename: "meta.json", revision: "main"))
        let url = try GitHubCatalogService.contentURL(id: "Author@A #1", filename: "description.md", revision: revision)
        XCTAssertNil(url.fragment)
        XCTAssertTrue(url.absoluteString.contains("%23"))
    }

    func testTreeFingerprintChangesForDescriptionOrThumbnailEdits() throws {
        let first = try GitHubCatalogService.catalogFiles(from: treeData())
        let changed = try GitHubCatalogService.catalogFiles(from: treeData(descriptionSHA: String(repeating: "b", count: 40)))
        XCTAssertNotEqual(first["frostice482@Amulet"], changed["frostice482@Amulet"])
        XCTAssertEqual(first.count, 1)
    }

    func testIncompleteOrSymlinkTreeCannotReplaceCachedCatalog() throws {
        XCTAssertThrowsError(try GitHubCatalogService.catalogFiles(from: treeData(truncated: true)))
        XCTAssertThrowsError(try GitHubCatalogService.catalogFiles(from: treeData(mode: "120000")))
        let missing = try JSONSerialization.data(withJSONObject: ["truncated": false, "tree": [entry("mods/test/meta.json")]])
        XCTAssertThrowsError(try GitHubCatalogService.catalogFiles(from: missing))
    }

    func testDescriptionFormattingAndLegacyCacheMigration() throws {
        let metadata = try JSONDecoder().decode(GitHubIndexMetadata.self, from: metadataData())
        let mod = try metadata.catalogMod(id: "frostice482@Amulet", revision: revision)
            .replacingDescription(with: "# Amulet\n\nA **high scoring** mod. [Guide](https://example.com)\n![image](https://example.com/image.png)")
        XCTAssertEqual(mod.cleanedSummary, "A high scoring mod. Guide")
        let data = Data(#"{"records":{},"details":{},"latestCatalogUpdate":null,"catalogRefreshedAt":0,"downloadsRefreshedAt":0}"#.utf8)
        let cache = try JSONDecoder().decode(CatalogFileCache.Snapshot.self, from: data)
        XCTAssertNil(cache.sourceRevision)
        XCTAssertNil(cache.sourceFileHashes)
        XCTAssertNotNil(cache.catalogRefreshedAt)
    }

    func testFetchReusesUnchangedMetadataAndLoadsPinnedDescription() async throws {
        let protocolSession = session()
        defer { protocolSession.session.invalidateAndCancel() }
        let client = GitHubCatalogService(session: protocolSession)
        let first = try await client.fetch(records: [:], fileHashes: [:])
        XCTAssertEqual(first.records.count, 1)
        XCTAssertTrue(first.skippedEntries.isEmpty)
        let second = try await client.fetch(records: first.records, fileHashes: first.fileHashes)
        XCTAssertEqual(second.records["frostice482@amulet"]?.version, "4d67d18")
        let detail = try await client.detail(for: second.records["frostice482@amulet"]!, revision: second.revision)
        XCTAssertEqual(detail.cleanedSummary, "A test description.")
        XCTAssertEqual(IndexProtocol.requestCount(ending: "/meta.json"), 1)
        XCTAssertFalse(IndexProtocol.requestedURLs().contains { $0.contains("api-bmi") })
        XCTAssertTrue(IndexProtocol.requestedURLs().filter { $0.contains("raw.githubusercontent.com") }.allSatisfy { $0.contains(revision) })
    }

    func testMalformedEntryKeepsCachedRecordAndRetriesNextRefresh() async throws {
        let protocolSession = session()
        defer { protocolSession.session.invalidateAndCancel() }
        let client = GitHubCatalogService(session: protocolSession)
        let initial = try await client.fetch(records: [:], fileHashes: [:])
        IndexProtocol.useMalformedMetadata()
        let refreshed = try await client.fetch(records: initial.records, fileHashes: [:])
        XCTAssertEqual(refreshed.records.count, 1)
        XCTAssertEqual(refreshed.skippedEntries, ["frostice482@Amulet"])
        XCTAssertNil(refreshed.fileHashes["frostice482@amulet"])
    }

    func testLiveCommunityIndexAndAmuletDownload() async throws {
        guard ProcessInfo.processInfo.environment["BMM_TEST_LIVE_INDEX"] == "1" else { throw XCTSkip("Live network smoke test is enabled in the build workflow") }
        let session = TrustedDownloadSession()
        defer { session.session.invalidateAndCancel() }
        let client = GitHubCatalogService(session: session)
        let snapshot = try await client.fetch(records: [:], fileHashes: [:])
        print("Live index: \(snapshot.records.count) usable mods; \(snapshot.skippedEntries.count) malformed entries skipped; revision \(snapshot.revision)")
        XCTAssertGreaterThan(snapshot.records.count, 100)
        let amulet = try XCTUnwrap(snapshot.records["frostice482@amulet"])
        let url = try XCTUnwrap(amulet.downloadURL.flatMap(URL.init(string:)))
        XCTAssertTrue(TrustedDownloadSession.isTrusted(url))
        let detail = try await client.detail(for: amulet, revision: snapshot.revision)
        XCTAssertFalse(detail.cleanedSummary?.isEmpty ?? true)
        // Verify the archive redirect and ZIP signature without downloading the whole mod.
        let (bytes, response) = try await session.session.bytes(from: url)
        defer { bytes.task.cancel() }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var magic = Data()
        for try await byte in bytes { magic.append(byte); if magic.count == 4 { break } }
        XCTAssertEqual(magic, Data([0x50, 0x4b, 0x03, 0x04]))
    }

    private func session() -> TrustedDownloadSession {
        IndexProtocol.reset(metadata: metadataData(), tree: try! treeData())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IndexProtocol.self]
        return TrustedDownloadSession(configuration: configuration)
    }

    private func metadataData() -> Data {
        Data(#"{"title":"Amulet","author":"frostice482","repo":"https://github.com/frostice482/amulet","downloadURL":"https://github.com/frostice482/amulet/archive/refs/heads/main.zip","folderName":"Amulet","version":"4d67d18","categories":["Technical"],"requires-steamodded":false,"requires-talisman":false,"last-updated":1790794977}"#.utf8)
    }

    private func entry(_ path: String, mode: String = "100644", sha: String? = nil) -> [String: String] {
        ["path": path, "mode": mode, "type": "blob", "sha": sha ?? revision]
    }

    private func treeData(truncated: Bool = false, mode: String = "100644", descriptionSHA: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["truncated": truncated, "tree": [
            entry("mods/frostice482@Amulet/meta.json", mode: mode),
            entry("mods/frostice482@Amulet/description.md", sha: descriptionSHA),
            entry("mods/frostice482@Amulet/thumbnail.jpg")]])
    }
}

private final class IndexProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var metadata = Data()
    private static var tree = Data()
    private static var urls: [String] = []
    static func reset(metadata: Data, tree: Data) {
        lock.lock(); defer { lock.unlock() }
        self.metadata = metadata; self.tree = tree; urls = []
    }
    static func useMalformedMetadata() { lock.lock(); defer { lock.unlock() }; metadata = Data("{invalid".utf8) }
    static func requestedURLs() -> [String] { lock.lock(); defer { lock.unlock() }; return urls }
    static func requestCount(ending: String) -> Int { requestedURLs().filter { $0.hasSuffix(ending) }.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let url = request.url!
        Self.urls.append(url.absoluteString)
        let data: Data
        if url.path.hasSuffix("/commits/main") { data = Data(("{\"sha\":\"" + String(repeating: "a", count: 40) + "\"}").utf8) }
        else if url.path.contains("/git/trees/") { data = Self.tree }
        else if url.path.hasSuffix("/meta.json") { data = Self.metadata }
        else { data = Data("# Amulet\n\nA test description.".utf8) }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
