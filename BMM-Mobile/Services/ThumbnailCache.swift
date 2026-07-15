import Combine
import Foundation
import UIKit

actor ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    struct Entry {
        let data: Data
    }

    private let cacheLifetime: TimeInterval = 60 * 60 * 24 * 7
    private let maximumBytes = 8 * 1024 * 1024
    private var generation: UInt = 0

    func entry(for key: String) -> Entry? {
        let fileURL = fileURL(for: key)
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate,
              Date().timeIntervalSince(date) < cacheLifetime,
              let size = values.fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return Entry(data: data)
    }

    func currentGeneration() -> UInt { generation }

    func store(_ data: Data, for key: String, ifGeneration expectedGeneration: UInt) throws {
        guard generation == expectedGeneration else { return }
        let fileURL = fileURL(for: key)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    func invalidateAll() {
        generation &+= 1
        try? FileManager.default.removeItem(at: directory)
    }

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModThumbnails", isDirectory: true)
    }

    private func fileURL(for key: String) -> URL {
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(encoded).appendingPathExtension("image")
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
        ThumbnailLoader.clearMemoryCache()
        loaders.allObjects.forEach { $0.invalidateCache() }
        Task {
            await ThumbnailDiskCache.shared.invalidateAll()
            generation &+= 1
        }
    }
}
