import Foundation
import CryptoKit

public enum PlanError: Error, LocalizedError, Equatable {
    case invalidCallback, denied, missingPermission, invalidIdentity, malformedResponse, incompleteStream
    case service(String)
    case reauthenticationRequired
    public var errorDescription: String? {
        switch self {
        case .invalidCallback: return "Invalid sign-in callback. Please start sign-in again."
        case .denied: return "ChatGPT authorization was cancelled or declined."
        case .missingPermission: return "ChatGPT plan usage was not authorized. Enable plan usage and sign in again."
        case .invalidIdentity: return "The ChatGPT identity could not be verified. Please sign in again."
        case .malformedResponse: return "ChatGPT returned an unreadable response."
        case .incompleteStream: return "The reply was interrupted. Please retry."
        case .service(let code): return "ChatGPT request failed (\(code)). Check your plan usage or sign in again."
        case .reauthenticationRequired: return "Your ChatGPT authorization expired or was revoked. Please sign in again."
        }
    }
}

public struct PlanModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct PlanTurn: Sendable {
    public let role: String
    public let text: String
    public let imageJPEG: Data?
    public init(role: String, text: String, imageJPEG: Data? = nil) {
        self.role = role; self.text = text; self.imageJPEG = imageJPEG
    }
}

public struct SignInAttempt: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let hostID: String
    public let redirectURI: String
    public let clientID: String?
    public init(hostID: String, port: UInt16, clientID: String? = nil) {
        state = Self.random(); nonce = Self.random(); verifier = Self.random()
        self.hostID = hostID; redirectURI = "http://127.0.0.1:\(port)/auth/callback"; self.clientID = clientID
    }
    private static func random() -> String {
        // SystemRandomNumberGenerator uses the platform's cryptographic RNG.
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URL
    }
    public var authorizationURL: URL {
        var components = URLComponents(string: SubscriptionContract.authorizeURL)!
        var items = [URLQueryItem(name: "client_id", value: clientID ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: hostID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: SubscriptionContract.scopes),
            .init(name: "resource", value: SubscriptionContract.resource), .init(name: "state", value: state),
            .init(name: "nonce", value: nonce), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)]
        if clientID == nil { items.append(.init(name: "agent_name_hint", value: "OpenVision Bilingual")) }
        components.queryItems = items
        return components.url!
    }
    public func callback(_ query: [URLQueryItem]) throws -> (code: String, clientID: String) {
        // Duplicate parameters are ambiguous and must never be accepted.
        let names = query.map(\.name)
        guard Set(names).count == names.count, query.first(where: { $0.name == "state" })?.value == state else {
            throw PlanError.invalidCallback
        }
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        if values["error"] != nil { throw PlanError.denied }
        guard let code = values["code"], !code.isEmpty else { throw PlanError.invalidCallback }
        let issued = values["client_id"] ?? clientID
        guard let issued, !issued.isEmpty, issued != "dynamic_agent_client",
              clientID == nil || clientID == issued else { throw PlanError.invalidCallback }
        return (code, issued)
    }
}

public enum SubscriptionContract {
    public static let issuer = "https://auth.openai.com"
    public static let authorizeURL = issuer + "/api/accounts/authorize"
    public static let tokenURL = issuer + "/api/accounts/oauth/token"
    public static let resource = "https://api.openai.com/v1"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    public static func refreshToken(replacement: String?, previous: String?) -> String? {
        if let replacement, !replacement.isEmpty { return replacement }
        return previous
    }

    public static func tokenError(status: Int, data: Data) -> PlanError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"]
        let code = error as? String ?? (error as? [String: Any])?["code"] as? String
        if code == "invalid_grant" || code == "invalid_token" { return .reauthenticationRequired }
        return .service("oauth_http_\(status)")
    }

    public static func validateScopes(_ granted: String) throws {
        let scopes = Set(granted.split(separator: " ").map(String.init))
        guard scopes.contains("chatgpt.tokens.use.direct"), scopes.contains("resource.invoke") else {
            throw PlanError.missingPermission
        }
    }

    public static func validateClaims(_ claims: [String: Any], clientID: String, nonce: String?, now: Date = Date()) throws {
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audience.contains(clientID),
              let sub = claims["sub"] as? String, !sub.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              nonce == nil || claims["nonce"] as? String == nonce else { throw PlanError.invalidIdentity }
    }

    public static func responseBody(model: String, instructions: String, turns: [PlanTurn]) throws -> Data {
        guard !model.isEmpty, !turns.isEmpty, turns.allSatisfy({ ["user", "assistant"].contains($0.role) }) else {
            throw PlanError.malformedResponse
        }
        let input: [[String: Any]] = turns.map { turn in
            var content: [[String: Any]] = [["type": turn.role == "assistant" ? "output_text" : "input_text", "text": turn.text]]
            if let photo = turn.imageJPEG, turn.role == "user" {
                content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + photo.base64EncodedString()])
            }
            return ["role": turn.role, "content": content]
        }
        return try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instructions,
            "input": input, "store": false, "stream": true])
    }

    public static func models(from data: Data) throws -> [PlanModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { throw PlanError.malformedResponse }
        return models.compactMap { model in
            guard model["visibility"] as? String == "list", let slug = model["slug"] as? String else { return nil }
            // Hide explicitly non-vision models; an absent capability is checked by the service.
            if let modalities = model["input_modalities"] as? [String], !modalities.contains("image") { return nil }
            return PlanModel(id: slug, name: model["display_name"] as? String ?? slug)
        }
    }
}

public extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let base = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
