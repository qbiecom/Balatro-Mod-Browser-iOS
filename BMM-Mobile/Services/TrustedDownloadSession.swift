import Foundation

/// BMI downloads may originate at the API or one of its explicitly approved HTTPS CDNs.
/// Private addresses, credential-bearing URLs, and arbitrary redirect destinations are rejected.
nonisolated final class TrustedDownloadSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let trustedHosts: Set<String> = [
        "api-bmi.dasguney.com",
        "cdn.dasguney.com",
        "github.com",
        "objects.githubusercontent.com",
        "github-releases.githubusercontent.com"
    ]

    private(set) var session: URLSession!

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              trustedHosts.contains(host) else { return false }
        return true
    }

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
