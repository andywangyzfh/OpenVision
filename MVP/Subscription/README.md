# ChatGPT plan integration

This module implements the documented **Sign in with ChatGPT open-source flow**. It does not reuse Codex client IDs, access private ChatGPT endpoints, read other applications' credentials, or fall back to billed API keys.

Contract verified against official documentation on 2026-10-17:

- [Registration, state, nonce, PKCE, issued client ID and identity validation](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Account-specific models and public Responses API](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Refresh, rotating credentials and sign-out](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Supported request fields and text/image inputs](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

The model catalog intentionally follows the SIWC documentation's `models / slug / display_name / visibility` schema, rather than the API-key catalog's `data / id` schema. Only server-visible models are offered; explicit text-only models are filtered. Final model capabilities and plan eligibility must still be checked with the user's account.

## Local checks

`swift run --package-path MVP/Subscription SubscriptionChecks`

Runs 35 checks without network access or user tokens: new/returning registration, PKCE, state and client substitution, identity scopes, text/image request contract, SSE framing including UTF-8 and CRLF, incomplete replies and late usage failures, refresh token preservation, revoked-session classification, and actual RS256/ES256 signature verification with tampering checks. The RSA fixture contains only a public key and a signed synthetic token; its ephemeral private key was discarded.

An XCTest target also provides conventional CI integration where XCTest is installed. On restricted command-line-only macOS installations, `swift run --disable-sandbox` may be needed to avoid SwiftPM's nested build sandbox; this does not disable the surrounding execution sandbox. Point Swift and Clang module caches to a writable temporary directory when required.

## iPhone validation gates

Local contract checks do **not** prove that authentication works on a physical iPhone. Before acceptance, validate:

1. `Continue with ChatGPT` opens the system authentication sheet, and the 127.0.0.1 listener receives the issued dynamic client registration callback. This particular iOS loopback/browser combination has not yet been tested on a device.
2. Denial, closing the sheet, timeout, backgrounding and cancellation during token exchange do not activate a late account.
3. Eligible ChatGPT plan scopes are actually granted. No model request is sent until authorization succeeds.
4. The account's live model catalog loads, then one text turn and one JPEG question reach `response.completed`.
5. Revoked/expired sessions require sign-in; disconnect removes local credentials, and failed remote revocation is shown to the user.

The MVP supports one registered ChatGPT account/workspace. It retains that issued client ID and the installation's stable host ID across sign-out; it rejects a reauthorization that returns a different identity. A newly issued client ID is retained as pending registration metadata **before** code exchange, so a failed/expired code can recover using the same registration. Pending metadata never activates an account.

Initial sign-in requires a signature-validated ID token. If a refresh response includes a new ID token, its signature and identity are validated again. If refresh omits it, the app retains the previously verified account identity and ID token; refresh can never introduce an unverified new identity. Omitted refresh scopes retain the prior grant, and an omitted replacement refresh token retains the last usable token. Multiple-account management is deferred.

Tokens are app-owned, stored in a device-only Keychain record while unlocked, and never logged. Conversations are supplied per request with `store:false`, `stream:true`; audio recognition and speech synthesis remain in the iPhone app, outside the SIWC inference endpoint.
