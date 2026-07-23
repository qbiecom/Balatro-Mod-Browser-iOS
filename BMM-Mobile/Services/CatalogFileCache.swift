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

    /// Locates the catalog snapshot in the app's durable Application Support directory.
    init(fileManager: FileManager = .default) {
        fileURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BMM Mobile", isDirectory: true)
            .appendingPathComponent("bmi-catalog-cache.json")
    }

    /// Decodes the last persisted catalog snapshot, if the cache file exists.
    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
    }

    /// Persists a snapshot only when its caller's revision is still current.
    func save(_ snapshot: Snapshot, revision: Int) throws {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// Removes the on-disk snapshot as part of an explicitly invalidated cache generation.
    func remove(revision: Int) throws {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
