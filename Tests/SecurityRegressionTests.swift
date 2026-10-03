import Foundation
import XCTest
import ZIPFoundation
@testable import BMMCore

final class SecurityRegressionTests: XCTestCase {
    private var root: URL!
    private var service: ModFileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = ModFileService(storageRootURL: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testDownloadURLAllowlist() {
        for value in ["https://github.com/a.zip", "https://api-bmi.dasguney.com/mods", "https://codeload.github.com/a"] {
            XCTAssertTrue(TrustedDownloadSession.isTrusted(URL(string: value)!))
        }
        for value in ["http://github.com/a", "https://github.com.evil.test/a", "https://github.com:444/a",
                      "https://user:password@github.com/a", "https://127.0.0.1/a", "file:///tmp/a"] {
            XCTAssertFalse(TrustedDownloadSession.isTrusted(URL(string: value)!))
        }
    }

    func testRedirectToUntrustedHostIsRejected() {
        let session = TrustedDownloadSession()
        let task = session.session.dataTask(with: URL(string: "https://github.com/a")!)
        let response = HTTPURLResponse(url: URL(string: "https://github.com/a")!, statusCode: 302,
                                       httpVersion: nil, headerFields: nil)!
        let completion = expectation(description: "Redirect validation")
        session.urlSession(session.session, task: task, willPerformHTTPRedirection: response,
                           newRequest: URLRequest(url: URL(string: "https://127.0.0.1/private")!)) { request in
            XCTAssertNil(request)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
        session.session.invalidateAndCancel()
    }

    func testBoundedDataRejectsChunkedOversizedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedResponseProtocol.self]
        let session = TrustedDownloadSession(configuration: configuration)
        defer { session.session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://github.com/image")!, maximumBytes: 4)
            XCTFail("An oversized response without Content-Length must be rejected")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
    }

    func testArchivePathsRejectTraversalAbsoluteAndControlCharacters() async throws {
        for path in ["../escape.lua", "/absolute.lua", "\\absolute.lua", "C:\\escape.lua", "a/../escape",
                     "a/./b", "nul\u{0}.lua", "", "/", Array(repeating: "a", count: 33).joined(separator: "/")] {
            do {
                _ = try await service.safeArchiveOutputURL(for: path, in: root)
                XCTFail("Accepted unsafe archive path: \(path)")
            } catch ModInstallError.unsafeArchive { }
        }
        let output = try await service.safeArchiveOutputURL(for: "mod\\main.lua", in: root)
        XCTAssertEqual(output.path, root.appendingPathComponent("mod/main.lua").path)
    }

    func testArchivePathCannotFollowExistingSymlink() async throws {
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        do {
            _ = try await service.safeArchiveOutputURL(for: "link/escape", in: root)
            XCTFail("Symlink traversal must be rejected")
        } catch ModInstallError.unsafeArchive { }
    }

    func testValidCompressedArchiveExtracts() async throws {
        let archiveURL = try makeArchive(path: "mod/main.lua", content: Data("return true".utf8))
        let destination = try makeDirectory("staging")
        try await service.extractZIPArchive(at: archiveURL, to: destination, mutationCheck: {})
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("mod/main.lua")), Data("return true".utf8))
    }

    func testForgedUncompressedSizeCannotBypassExtractionLimit() async throws {
        let archiveURL = try makeArchive(path: "main.lua", content: Data(repeating: 65, count: 100_000))
        try patchCentralDirectory(at: archiveURL, fieldOffset: 24, value: 1)
        let destination = try makeDirectory("staging")
        do {
            try await service.extractZIPArchive(at: archiveURL, to: destination, mutationCheck: {})
            XCTFail("Actual decompressed bytes must be bounded independently of ZIP metadata")
        } catch { }
        let values = try destination.appendingPathComponent("main.lua").resourceValues(forKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(values.fileSize ?? 0, 1)
    }

    func testCorruptChecksumIsRejected() async throws {
        let archiveURL = try makeArchive(path: "main.lua", content: Data("return true".utf8))
        try patchCentralDirectory(at: archiveURL, fieldOffset: 16, value: 0)
        let destination = try makeDirectory("staging")
        do {
            try await service.extractZIPArchive(at: archiveURL, to: destination, mutationCheck: {})
            XCTFail("Corrupted archive contents must be rejected")
        } catch { }
    }

    func testSymlinkArchiveEntryIsRejectedBeforeExtraction() async throws {
        let archiveURL = root.appendingPathComponent("link.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let content = Data("../escape".utf8)
        try archive.addEntry(with: "link", type: .symlink, uncompressedSize: Int64(content.count)) { _, _ in content }
        let destination = try makeDirectory("staging")
        do {
            try await service.extractZIPArchive(at: archiveURL, to: destination, mutationCheck: {})
            XCTFail("Symlink entries must be rejected")
        } catch ModInstallError.unsafeArchive { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testNewerCatalogRejectsStaleCachedDetails() throws {
        let current = try mod(["id": "mod", "version": "2", "updated_at": 200])
        XCTAssertFalse(current.canUseCachedDetail(try mod(["id": "mod", "version": "1", "updated_at": 100])))
        XCTAssertFalse(current.canUseCachedDetail(try mod(["id": "mod", "version": "1", "updated_at": 200])))
        XCTAssertFalse(current.canUseCachedDetail(try mod(["id": "other", "version": "2", "updated_at": 200])))
        XCTAssertTrue(current.canUseCachedDetail(try mod(["id": "MOD", "version": "2", "updated_at": 200])))
    }

    func testWebsiteLinksRejectCustomSchemesAndFallBackToHomepage() throws {
        XCTAssertNil(try mod(["id": "mod", "repo": "shortcuts://run-shortcut?name=evil"]).websiteURL)
        let value = try mod(["id": "mod", "repo": "file:///private/secret", "homepage": "https://example.com/mod"])
        XCTAssertEqual(value.websiteURL?.absoluteString, "https://example.com/mod")
    }

    func testDisableRejectsSymlinkMarkerWithoutTouchingTarget() async throws {
        let mods = try makeDirectory("Mods")
        let installed = try makeDirectory("Mods/mod")
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: installed.appendingPathComponent(".lovelyignore"), withDestinationURL: sentinel)
        do {
            try await service.setEnabled(false, modURL: installed, modsFolderURL: mods, gameFolderID: "game")
            XCTFail("A symlink marker must be rejected")
        } catch ModInstallError.invalidUpdateTarget { }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testCommittedDeletionRecoveryPreservesReinstalledMod() async throws {
        let mods = try makeDirectory("Mods")
        let installed = try makeDirectory("Mods/mod")
        let temporary = try makeDirectory("Mods/.deleting_test")
        try Data("new install".utf8).write(to: installed.appendingPathComponent("main.lua"))
        try writeJournal(kind: "deletion", values: ["modPath": installed.path, "temporaryPath": temporary.path,
                                                   "modsFolderPath": mods.path, "phase": "committed"])
        await service.recoverInterruptedUpdates(modsFolderURL: mods, gameFolderID: "game")
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("main.lua")), Data("new install".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testInterruptedUpdateRestoresOriginalAndRegistry() async throws {
        let mods = try makeDirectory("Mods")
        let destination = mods.appendingPathComponent("mod", isDirectory: true)
        let backup = try makeDirectory("Mods/.BMM Backups/mod-backup")
        try Data("original".utf8).write(to: backup.appendingPathComponent("main.lua"))
        let record = InstalledModRecord(gameFolderID: "game", name: "mod", path: destination.path,
                                        normalizedModPath: destination.path.lowercased(), dependencies: [],
                                        currentVersion: "1", orphaned: false, catalogID: "mod")
        let encodedRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        try writeJournal(kind: "update", values: ["destinationPath": destination.path, "backupPath": backup.path,
                                                 "modsFolderPath": mods.path, "originalRecord": encodedRecord,
                                                 "replacementRecord": encodedRecord, "phase": "originalMoved"])
        await service.recoverInterruptedUpdates(modsFolderURL: mods, gameFolderID: "game")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("main.lua")), Data("original".utf8))
        let records = try await service.updateRecords(for: [InstalledMod(id: destination, name: "mod")], gameFolderID: "game")
        XCTAssertEqual(records.first?.currentVersion, "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    private func makeDirectory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mod(_ values: [String: Any]) throws -> CatalogMod {
        try JSONDecoder().decode(CatalogMod.self, from: JSONSerialization.data(withJSONObject: values))
    }

    private func makeArchive(path: String, content: Data) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(content.count), compressionMethod: .deflate) { position, size in
            content.subdata(in: Int(position)..<min(content.count, Int(position) + size))
        }
        return url
    }

    private func patchCentralDirectory(at url: URL, fieldOffset: Int, value: UInt32) throws {
        var data = try Data(contentsOf: url)
        guard let range = data.range(of: Data([0x50, 0x4b, 0x01, 0x02])) else { throw CocoaError(.fileReadCorruptFile) }
        let offset = range.lowerBound + fieldOffset
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        try data.write(to: url)
    }

    private func writeJournal(kind: String, values: [String: Any]) throws {
        let directory = try makeDirectory("BMM Mobile/\(kind)-transactions")
        var journal = values
        journal["id"] = UUID().uuidString
        journal["gameFolderID"] = "game"
        journal["modsFolderIdentity"] = ""
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent("transaction.json"))
    }
}

private final class OversizedResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 5))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
