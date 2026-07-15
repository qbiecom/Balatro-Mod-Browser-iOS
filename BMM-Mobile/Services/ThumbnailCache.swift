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

    func removeEntry(for key: String, ifGeneration expectedGeneration: UInt) {
        guard adopt(expectedGeneration) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    func invalidateAll(generation newGeneration: UInt) {
        guard newGeneration > generation else { return }
        generation = newGeneration
        try? FileManager.default.removeItem(at: directory)
    }

    private func adopt(_ expectedGeneration: UInt) -> Bool {
        guard expectedGeneration >= generation else { return false }
        if expectedGeneration > generation {
            generation = expectedGeneration
            try? FileManager.default.removeItem(at: directory)
        }
        return true
    }

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
    private init() {}

    func register(_ loader: ThumbnailLoader) { loaders.add(loader) }

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
