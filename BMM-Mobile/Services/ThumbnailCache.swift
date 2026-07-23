import Combine
import CryptoKit
import Foundation
import UIKit

actor ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    struct Entry {
        let data: Data
    }

    private let cacheLifetime: TimeInterval = 60 * 60 * 24 * 7
    private let maximumEntryBytes = 8 * 1024 * 1024
    private let maximumTotalBytes = 64 * 1024 * 1024
    private let maximumEntryCount = 160
    private var generation: UInt = 0

    /// Returns a disk-cached thumbnail only when it belongs to the active cache generation and remains fresh.
    func entry(for key: String, ifGeneration expectedGeneration: UInt) -> Entry? {
        guard adopt(expectedGeneration) else { return nil }
        enforceBudget()
        let fileURL = fileURL(for: key)
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let date = values.contentModificationDate,
               Date().timeIntervalSince(date) < cacheLifetime,
               let size = values.fileSize,
               size <= maximumEntryBytes else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL), generation == expectedGeneration else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return Entry(data: data)
    }

    /// Stores thumbnail bytes and metadata, then evicts least-recently-used entries beyond the disk budget.
    func store(_ data: Data, for key: String, ifGeneration expectedGeneration: UInt) throws {
        guard data.count <= maximumEntryBytes, adopt(expectedGeneration) else { return }
        let fileURL = fileURL(for: key)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        guard generation == expectedGeneration else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        enforceBudget()
    }

    /// Removes one stale or invalid thumbnail only if its caller still owns the active cache generation.
    func removeEntry(for key: String, ifGeneration expectedGeneration: UInt) {
        guard adopt(expectedGeneration) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Invalidates every thumbnail after a forced catalog refresh without blocking the UI.
    func invalidateAll(generation newGeneration: UInt) {
        guard newGeneration > generation else { return }
        generation = newGeneration
        try? FileManager.default.removeItem(at: directory)
    }

    /// Rejects delayed cache work after a global invalidation advances the generation counter.
    private func adopt(_ expectedGeneration: UInt) -> Bool {
        guard expectedGeneration >= generation else { return false }
        if expectedGeneration > generation {
            generation = expectedGeneration
            try? FileManager.default.removeItem(at: directory)
        }
        return true
    }

    /// Evicts oldest entries until the cache fits its configured byte budget.
    private func enforceBudget() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        var entries: [(url: URL, date: Date, size: Int)] = []
        for url in files {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate,
                  let size = values.fileSize,
                  size <= maximumEntryBytes,
                  now.timeIntervalSince(date) < cacheLifetime else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            entries.append((url, date, size))
        }

        entries.sort { $0.date < $1.date }
        var totalBytes = entries.reduce(0) { $0 + $1.size }
        var totalCount = entries.count
        for entry in entries where totalBytes > maximumTotalBytes || totalCount > maximumEntryCount {
            try? FileManager.default.removeItem(at: entry.url)
            totalBytes -= entry.size
            totalCount -= 1
        }
    }

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModThumbnails", isDirectory: true)
    }

    /// Derives a filesystem-safe cache filename from a URL-derived thumbnail key.
    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("image")
    }
}

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    @Published private(set) var generation: UInt = 0
    private let loaders = NSHashTable<ThumbnailLoader>.weakObjects()
    /// Keeps shared cache coordination behind the singleton instance.
    private init() {}

    /// Retains a weak reference so shared invalidation can reset every currently visible loader.
    func register(_ loader: ThumbnailLoader) { loaders.add(loader) }

    /// Advances the shared generation so active loaders ignore stale disk and memory-cache entries.
    func invalidateAll() {
        generation &+= 1
        let newGeneration = generation
        ThumbnailLoader.clearMemoryCache()
        loaders.allObjects.forEach { $0.invalidateCache() }
        Task {
            await ThumbnailDiskCache.shared.invalidateAll(generation: newGeneration)
        }
    }
}
