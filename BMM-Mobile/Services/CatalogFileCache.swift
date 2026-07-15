import Foundation

/// One atomically persisted BMI cache. Records are keyed exclusively by normalized catalog ID.
actor CatalogFileCache {
    struct Snapshot: Codable {
        let records: [String: CatalogMod]
        let details: [String: DetailCacheEntry]
        let latestCatalogUpdate: FlexibleTimestamp?
        let catalogRefreshedAt: Date?
        let downloadsRefreshedAt: Date?
    }

    private let fileURL: URL
    private var latestRevision = 0

    init(fileManager: FileManager = .default) {
        fileURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BMM Mobile", isDirectory: true)
            .appendingPathComponent("bmi-catalog-cache.json")
    }

    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: Snapshot, revision: Int) throws {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    func remove(revision: Int) throws {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
