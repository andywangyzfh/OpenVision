import Foundation

/// App-owned HTTP transport. Authentication records intentionally live in the app Keychain;
/// request/response caches, cookies and URL-loading credentials must not create extra copies.
public enum PlanHTTPTransport {
    public static let session: URLSession = makeSession()

    /// Alternate configurations support isolated URLProtocol tests. The same privacy and
    /// redirect policy is applied to every session, including the production singleton.
    public static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RejectHTTPRedirects(), delegateQueue: nil)
    }
}

/// OAuth bodies and bearer headers must never be replayed at a Location chosen by a response.
/// Return the original 3xx to the existing caller error path, even for same-origin redirects.
private final class RejectHTTPRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
