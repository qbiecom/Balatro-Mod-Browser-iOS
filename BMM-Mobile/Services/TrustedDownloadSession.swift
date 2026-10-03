import Foundation

/// BMI downloads may originate at the API or one of its explicitly approved HTTPS CDNs.
/// Private addresses, credential-bearing URLs, and arbitrary redirect destinations are rejected.
nonisolated final class TrustedDownloadSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let trustedHosts: Set<String> = [
        "api-bmi.dasguney.com",
        "cdn.dasguney.com",
        "github.com",
        "api.github.com",
        "codeload.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
        "gitlab.com"
    ]

    private(set) var session: URLSession!

    override convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Allows only HTTPS download URLs whose host is explicitly approved for BMI installations.
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              trustedHosts.contains(host) else { return false }
        return true
    }

    /// Bounds the actual transfer, including chunked responses with no declared length.
    func data(from url: URL, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await data(for: URLRequest(url: url), maximumBytes: maximumBytes)
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, Self.isTrusted(url) else { throw ModInstallError.untrustedDownloadURL }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url, Self.isTrusted(finalURL),
              200..<300 ~= response.statusCode else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, response)
    }

    /// Rejects redirects that leave the approved-host allowlist before the URL session follows them.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, Self.isTrusted(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
