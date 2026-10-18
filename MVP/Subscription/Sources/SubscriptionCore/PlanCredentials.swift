import Foundation

public struct PlanCredentials: Codable, Sendable {
    public var clientID: String
    public var subject: String
    public var label: String
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String
    public var scopes: String
    public var expiresAt: Date

    public init(clientID: String, subject: String, label: String, accessToken: String, refreshToken: String?, idToken: String, scopes: String, expiresAt: Date) {
        self.clientID = clientID; self.subject = subject; self.label = label
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.idToken = idToken
        self.scopes = scopes; self.expiresAt = expiresAt
    }

    /// Merge one authenticated refresh reply. New identity claims must already have passed
    /// IDTokenVerifier; omitted ID tokens retain the previously verified identity.
    public func refreshed(with reply: TokenReply, signatureVerifiedClaims claims: [String: Any]?, now: Date = Date()) throws -> Self {
        let scopes = reply.scope ?? self.scopes
        try SubscriptionContract.validateScopes(scopes)
        guard reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty,
              reply.expires_in.isFinite, reply.expires_in > 0 else { throw PlanError.invalidIdentity }
        var value = self
        if let idToken = reply.id_token {
            guard !idToken.isEmpty, let claims, claims["sub"] as? String == subject else { throw PlanError.invalidIdentity }
            value.idToken = idToken
            value.label = claims["email"] as? String ?? label
        }
        value.accessToken = reply.access_token
        value.refreshToken = SubscriptionContract.refreshToken(replacement: reply.refresh_token, previous: refreshToken)
        value.scopes = scopes
        value.expiresAt = now.addingTimeInterval(reply.expires_in)
        return value
    }
}

public struct TokenReply: Decodable, Sendable {
    public let access_token: String
    public let refresh_token: String?
    public let id_token: String?
    public let token_type: String
    public let expires_in: Double
    public let scope: String?
}
