import Foundation
import UIKit

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let loaders = NSHashTable<ThumbnailLoader>.weakObjects()
    private init() {}

    func register(_ loader: ThumbnailLoader) { loaders.add(loader) }

    func invalidateAll() {
        ThumbnailLoader.clearMemoryCache()
        loaders.allObjects.forEach { $0.invalidateCache() }
        Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ModThumbnails", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
