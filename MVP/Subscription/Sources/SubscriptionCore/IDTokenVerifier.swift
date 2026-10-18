import Foundation
import Security
import CryptoKit

/// Verifies ID-token signatures against discovery from the fixed OpenAI issuer.
/// Identity claims are never trusted merely because a JWT can be decoded.
public enum IDTokenVerifier {
    public struct Discovery: Decodable {
        public let issuer: String
        public let jwks_uri: URL
        public let revocation_endpoint: URL?
    }
    public static func discovery() async throws -> Discovery {
        let (data, response) = try await PlanHTTPTransport.session.data(from: URL(string: SubscriptionContract.issuer + "/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PlanError.invalidIdentity }
        let metadata = try JSONDecoder().decode(Discovery.self, from: data)
        guard metadata.issuer == SubscriptionContract.issuer, trusted(metadata.jwks_uri),
              metadata.revocation_endpoint.map(trusted) ?? true else { throw PlanError.invalidIdentity }
        return metadata
    }
    private static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil
    }
    public static func verify(_ token: String, clientID: String, nonce: String?) async throws -> [String: Any] {
        let metadata = try await discovery()
        let (keysData, response) = try await PlanHTTPTransport.session.data(from: metadata.jwks_uri)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PlanError.invalidIdentity }
        return try verify(token, clientID: clientID, nonce: nonce, jwks: keysData)
    }

    public static func verify(_ token: String, clientID: String, nonce: String?, jwks keysData: Data) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let kid = header["kid"] as? String, let algorithm = header["alg"] as? String,
              ["RS256", "ES256"].contains(algorithm), header["crit"] == nil,
              let signature = Data(base64URL: parts[2]), let claimsData = Data(base64URL: parts[1]) else {
            throw PlanError.invalidIdentity
        }
        guard let root = try JSONSerialization.jsonObject(with: keysData) as? [String: Any],
              let keys = root["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid }),
              key["alg"] == nil || key["alg"] as? String == algorithm,
              key["use"] == nil || key["use"] as? String == "sig" else { throw PlanError.invalidIdentity }
        let message = Data((parts[0] + "." + parts[1]).utf8)
        let verified: Bool
        if algorithm == "RS256" {
            guard key["kty"] as? String == "RSA", let n = key["n"] as? String,
                  let e = key["e"] as? String, let modulus = Data(base64URL: n),
                  let exponent = Data(base64URL: e), modulus.count >= 256 else { throw PlanError.invalidIdentity }
            let der = encode(tag: 0x30, value: integer(modulus) + integer(exponent))
            var error: Unmanaged<CFError>?
            guard let publicKey = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error) else { throw PlanError.invalidIdentity }
            verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, &error)
        } else {
            guard key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = key["x"] as? String, let y = key["y"] as? String,
                  let xd = Data(base64URL: x), let yd = Data(base64URL: y), xd.count == 32, yd.count == 32 else { throw PlanError.invalidIdentity }
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + xd + yd)
            verified = publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message)
        }
        guard verified, let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else { throw PlanError.invalidIdentity }
        try SubscriptionContract.validateClaims(claims, clientID: clientID, nonce: nonce)
        return claims
    }
    private static func integer(_ data: Data) -> Data {
        var bytes = data
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if (bytes.first ?? 0) & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(tag: 2, value: bytes)
    }
    private static func encode(tag: UInt8, value: Data) -> Data {
        var length: [UInt8] = []
        if value.count < 128 { length = [UInt8(value.count)] }
        else {
            var size = value.count
            while size > 0 { length.insert(UInt8(size & 255), at: 0); size >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + value
    }
}
