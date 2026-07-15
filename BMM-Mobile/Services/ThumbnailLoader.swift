import Combine
import Foundation
import ImageIO
import UIKit

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private static let maximumTransferBytes = 8 * 1024 * 1024
    private static let pixelBucketInterval = 64
    private static let acceptedMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]
    fileprivate static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private var url: URL?
    private let session = TrustedDownloadSession()
    private var loadTask: Task<UIImage?, Never>?
    private var requestToken: UInt = 0
    private var loadingPixelBucket: Int?
    private var imagePixelBucket: Int?

    init(url: URL?) {
        self.url = url
        ThumbnailCache.shared.register(self)
    }
    deinit { loadTask?.cancel() }

    func replace(url: URL?) {
        guard self.url != url else { return }
        cancel()
        self.url = url
        image = nil
        imagePixelBucket = nil
    }

    func load(displaySize: CGSize) async {
        let pixelBucket = Self.pixelBucket(for: displaySize)
        await load(pixelBucket: pixelBucket)
    }

    func load(pixelBucket: Int) async {
        guard let url, TrustedDownloadSession.isTrusted(url) else { return }
        if let imagePixelBucket, imagePixelBucket >= pixelBucket { return }
        if isLoading, loadingPixelBucket == pixelBucket { return }
        let key = Self.cacheKey(for: url, pixelBucket: pixelBucket)
        if let cached = Self.memoryCache.object(forKey: key) {
            image = cached
            imagePixelBucket = pixelBucket
            return
        }

        beginRequest(pixelBucket: pixelBucket)
        let token = requestToken
        let cacheGeneration = ThumbnailCache.shared.generation
        isLoading = true
        let session = session.session!
        loadTask = Task.detached(priority: .utility) {
            await Self.loadImage(
                url: url,
                pixelBucket: pixelBucket,
                cacheKey: key as String,
                cacheGeneration: cacheGeneration,
                session: session
            )
        }
        let result = await loadTask?.value
        guard requestToken == token, self.url == url else { return }
        if let result {
            Self.memoryCache.setObject(result, forKey: key, cost: Self.cost(of: result))
            image = result
            imagePixelBucket = pixelBucket
        }
        isLoading = false
        loadingPixelBucket = nil
        loadTask = nil
    }

    func cancel() {
        requestToken &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        loadingPixelBucket = nil
    }

    func invalidateCache() {
        cancel()
        image = nil
        imagePixelBucket = nil
    }

    static func clearMemoryCache() { memoryCache.removeAllObjects() }

    func retry(displaySize: CGSize) async {
        cancel()
        image = nil
        await load(displaySize: displaySize)
    }

    private func beginRequest(pixelBucket: Int) {
        requestToken &+= 1
        loadTask?.cancel()
        loadingPixelBucket = pixelBucket
    }

    private static func loadImage(url: URL, pixelBucket: Int, cacheKey: String, cacheGeneration: UInt, session: URLSession) async -> UIImage? {
        if let entry = await ThumbnailDiskCache.shared.entry(for: cacheKey, ifGeneration: cacheGeneration) {
            if let image = downsample(data: entry.data, pixelBucket: pixelBucket) { return image }
            await ThumbnailDiskCache.shared.removeEntry(for: cacheKey, ifGeneration: cacheGeneration)
        }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse,
                  200..<300 ~= response.statusCode,
                  response.expectedContentLength <= Int64(maximumTransferBytes),
                  let mime = response.mimeType?.lowercased(), acceptedMIMETypes.contains(mime),
                  !Task.isCancelled else { return nil }
            var data = Data()
            data.reserveCapacity(min(maximumTransferBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < maximumTransferBytes else { return nil }
                data.append(byte)
            }
            guard let image = downsample(data: data, pixelBucket: pixelBucket) else { return nil }
            try? await ThumbnailDiskCache.shared.store(data, for: cacheKey, ifGeneration: cacheGeneration)
            return image
        } catch { return nil }
    }

    private static func downsample(data: Data, pixelBucket: Int) -> UIImage? {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        guard let source else { return nil }
        let options: CFDictionary = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixelBucket, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func cost(of image: UIImage) -> Int { Int(image.size.width * image.size.height * image.scale * image.scale * 4) }
    private static func cacheKey(for url: URL, pixelBucket: Int) -> NSString { "\(url.absoluteString)#\(pixelBucket)px" as NSString }
    static func pixelBucket(for displaySize: CGSize) -> Int {
        let pixels = max(1, Int(ceil(max(displaySize.width, displaySize.height) * UIScreen.main.scale)))
        return ((pixels + pixelBucketInterval - 1) / pixelBucketInterval) * pixelBucketInterval
    }
}
