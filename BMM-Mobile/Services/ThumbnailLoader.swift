import Combine
import Foundation
import ImageIO
import UIKit

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private static let cacheLifetime: TimeInterval = 60 * 60 * 24 * 7
    private static let maximumTransferBytes = 8 * 1024 * 1024
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
    }

    func load(displaySize: CGSize) async {
        guard image == nil, !isLoading, let url, TrustedDownloadSession.isTrusted(url) else { return }
        let key = Self.cacheKey(for: url, displaySize: displaySize)
        if let cached = Self.memoryCache.object(forKey: key) { image = cached; return }

        loadTask?.cancel()
        isLoading = true
        let session = session.session!
        loadTask = Task.detached(priority: .utility) {
            await Self.loadImage(url: url, displaySize: displaySize, session: session)
        }
        let result = await loadTask?.value
        guard !Task.isCancelled, self.url == url else { return }
        if let result {
            Self.memoryCache.setObject(result, forKey: key, cost: Self.cost(of: result))
            image = result
        }
        isLoading = false
        loadTask = nil
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    func invalidateCache() {
        cancel()
        image = nil
    }

    static func clearMemoryCache() { memoryCache.removeAllObjects() }

    func retry(displaySize: CGSize) async {
        cancel()
        image = nil
        await load(displaySize: displaySize)
    }

    private static func loadImage(url: URL, displaySize: CGSize, session: URLSession) async -> UIImage? {
        let fileURL = fileURL(for: url)
        if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
           let date = values.contentModificationDate,
           Date().timeIntervalSince(date) < cacheLifetime,
           let size = values.fileSize, size <= maximumTransferBytes,
           let image = downsample(fileURL: fileURL, displaySize: displaySize) {
            return image
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
            guard let image = downsample(data: data, displaySize: displaySize) else { return nil }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return image
        } catch { return nil }
    }

    private static func downsample(data: Data? = nil, fileURL: URL? = nil, displaySize: CGSize) -> UIImage? {
        let source: CGImageSource?
        if let data { source = CGImageSourceCreateWithData(data as CFData, nil) }
        else if let fileURL { source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) }
        else { source = nil }
        guard let source else { return nil }
        let pixels = max(1, Int(max(displaySize.width, displaySize.height) * UIScreen.main.scale))
        let options: CFDictionary = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func cost(of image: UIImage) -> Int { Int(image.size.width * image.size.height * image.scale * image.scale * 4) }
    private static func cacheKey(for url: URL, displaySize: CGSize) -> NSString { "\(url.absoluteString)#\(Int(displaySize.width))x\(Int(displaySize.height))" as NSString }
    private static func fileURL(for url: URL) -> URL { let encoded = Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-"); let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ModThumbnails", isDirectory: true); return directory.appendingPathComponent(encoded).appendingPathExtension("image") }
}
