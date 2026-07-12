import Combine
import Foundation
import UIKit

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private static let cacheLifetime: TimeInterval = 60 * 60 * 24 * 7
    private static let memoryCache = NSCache<NSString, UIImage>()
    private let url: URL?

    init(url: URL?) { self.url = url }

    func load() async {
        guard image == nil, !isLoading, let url else { return }
        let key = url.absoluteString as NSString
        if let cached = Self.memoryCache.object(forKey: key) {
            image = cached
            return
        }

        isLoading = true
        defer { isLoading = false }
        let fileURL = Self.fileURL(for: url)
        if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate,
           Date().timeIntervalSince(date) < Self.cacheLifetime,
           let data = try? Data(contentsOf: fileURL), let cached = UIImage(data: data) {
            Self.memoryCache.setObject(cached, forKey: key)
            image = cached
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode,
                  let downloaded = UIImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
            Self.memoryCache.setObject(downloaded, forKey: key)
            image = downloaded
        } catch { return }
    }

    func retry() async {
        image = nil
        isLoading = false
        await load()
    }

    private static func fileURL(for url: URL) -> URL {
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModThumbnails", isDirectory: true)
        return directory.appendingPathComponent(encoded).appendingPathExtension("image")
    }
}
