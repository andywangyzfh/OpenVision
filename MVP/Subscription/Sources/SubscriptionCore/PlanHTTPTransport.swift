import Foundation

/// App-owned HTTP transport. Authentication records intentionally live in the app Keychain;
/// request/response caches, cookies and URL-loading credentials must not create extra copies.
public enum PlanHTTPTransport {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}
