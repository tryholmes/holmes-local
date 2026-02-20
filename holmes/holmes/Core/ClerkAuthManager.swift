import Foundation
import Observation
import AuthenticationServices
import AppKit

// MARK: - Clerk Auth Errors

enum ClerkAuthError: LocalizedError {
    case invalidConfiguration
    case networkError(String)
    case clerkError(String)
    case sessionExpired
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Clerk is not configured. Please add your API keys to ClerkConfig.swift."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .clerkError(let msg):
            return msg
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .unknown(let msg):
            return msg
        }
    }
}

// MARK: - Clerk Response Models

private struct ClerkErrorResponse: Decodable {
    struct ClerkError: Decodable {
        let message: String
        let longMessage: String?
        let code: String?
    }
    let errors: [ClerkError]?
}

private struct ClerkSignInResponse: Decodable {
    struct Response: Decodable {
        let id: String
        let status: String?
        // supported_first_factors contains OAuth URLs
        let supportedFirstFactors: [FirstFactor]?
        struct FirstFactor: Decodable {
            let strategy: String?
            let authorizationUrl: String?
            let externalVerificationRedirectUrl: String?
        }
    }
    let response: Response?
    let client: ClerkClient?
}

private struct ClerkClient: Decodable {
    struct Session: Decodable {
        let id: String
        let userId: String?
        let lastActiveToken: LastActiveToken?
        struct LastActiveToken: Decodable {
            let jwt: String
        }
    }
    let sessions: [Session]?
    let lastActiveSessionId: String?
}

private struct ClerkClientResponse: Decodable {
    let client: ClerkClient?
}

private struct ClerkSignUpResponse: Decodable {
    struct SignUpResponse: Decodable {
        let id: String
        let status: String?
        let createdSessionId: String?
    }
    let response: SignUpResponse?
    let client: ClerkClient?
}

private struct ClerkMeResponse: Decodable {
    let id: String
    let emailAddresses: [EmailAddress]
    struct EmailAddress: Decodable {
        let emailAddress: String
    }
}

// MARK: - JWT Payload (for local expiry check)

private struct JWTPayload: Decodable {
    let exp: TimeInterval?
}

// MARK: - ClerkAuthManager

@Observable
@MainActor
final class ClerkAuthManager {

    static let shared = ClerkAuthManager()

    var isAuthenticated = false
    var currentUserEmail: String?
    var isLoading = false

    // Dev-mode browser token (required for pk_test_ instances)
    private var devBrowserToken: String?

    private init() {}

    // MARK: - Dev Browser Initialization (must call before any auth operation)

    func initializeDevBrowser() async {
        // Only needed for development instances (pk_test_)
        guard ClerkConfig.publishableKey.hasPrefix("pk_test_") else { return }
        guard devBrowserToken == nil else { return }

        var req = URLRequest(url: URL(string: "\(ClerkConfig.frontendAPIURL)/v1/dev_browser")!)
        req.httpMethod = "GET"

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return }

        struct DevBrowserResp: Decodable { let token: String }
        if let result = try? JSONDecoder().decode(DevBrowserResp.self, from: data) {
            devBrowserToken = result.token
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        await initializeDevBrowser()
        let baseURL = ClerkConfig.frontendAPIURL

        // Step 1: Create sign-in with identifier only
        var createReq = makeRequest("\(baseURL)/v1/client/sign_ins", method: "POST")
        createReq.httpBody = "identifier=\(email.urlEncoded)".data(using: .utf8)

        let (data1, resp1) = try await URLSession.shared.data(for: createReq)
        try throwIfError(resp1, data: data1)

        let signIn = try JSONDecoder.clerk.decode(ClerkSignInResponse.self, from: data1)
        guard let signInID = signIn.response?.id else {
            throw ClerkAuthError.unknown("Could not create sign-in session.")
        }

        // Step 2: Attempt first factor with password
        var attemptReq = makeRequest(
            "\(baseURL)/v1/client/sign_ins/\(signInID)/attempt_first_factor",
            method: "POST"
        )
        attemptReq.httpBody = "strategy=password&password=\(password.urlEncoded)".data(using: .utf8)

        let (data2, resp2) = try await URLSession.shared.data(for: attemptReq)
        try throwIfError(resp2, data: data2)

        let result = try JSONDecoder.clerk.decode(ClerkSignInResponse.self, from: data2)
        guard let token = result.client?.sessions?.first?.lastActiveToken?.jwt else {
            throw ClerkAuthError.unknown("Sign-in succeeded but no session token was returned.")
        }

        persistSession(token: token, email: email)
    }

    // MARK: - Sign Up

    func signUp(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        await initializeDevBrowser()
        let baseURL = ClerkConfig.frontendAPIURL

        var req = makeRequest("\(baseURL)/v1/client/sign_ups", method: "POST")
        req.httpBody = "email_address=\(email.urlEncoded)&password=\(password.urlEncoded)".data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfError(resp, data: data)

        let result = try JSONDecoder.clerk.decode(ClerkSignUpResponse.self, from: data)

        switch result.response?.status {
        case "complete":
            guard let token = result.client?.sessions?.first?.lastActiveToken?.jwt else {
                throw ClerkAuthError.unknown("Account created but no session returned.")
            }
            persistSession(token: token, email: email)

        case "missing_requirements":
            // Email verification required — Clerk sent a verification email
            throw ClerkAuthError.clerkError("Check your email to verify your account, then sign in.")

        default:
            throw ClerkAuthError.unknown("Sign-up status unknown: \(result.response?.status ?? "nil")")
        }
    }

    // MARK: - Google OAuth

    func signInWithGoogle() async throws {
        isLoading = true
        defer { isLoading = false }

        await initializeDevBrowser()
        let baseURL = ClerkConfig.frontendAPIURL
        let redirectURL = "holmes://oauth/callback"

        // Step 1: Create sign-in with Google strategy to get authorization URL
        var req = makeRequest("\(baseURL)/v1/client/sign_ins", method: "POST")
        req.httpBody = [
            "strategy=oauth_google",
            "redirect_url=\(redirectURL.urlEncoded)",
            "action_complete_redirect_url=\(redirectURL.urlEncoded)"
        ].joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfError(resp, data: data)

        let result = try JSONDecoder.clerk.decode(ClerkSignInResponse.self, from: data)

        // Find the Google OAuth authorization URL from supported_first_factors
        let googleFactor = result.response?.supportedFirstFactors?.first(where: {
            $0.strategy == "oauth_google"
        })
        let authURLString = googleFactor?.authorizationUrl
            ?? googleFactor?.externalVerificationRedirectUrl

        guard let urlString = authURLString, let authURL = URL(string: urlString) else {
            // Fallback: build the Clerk-hosted OAuth URL directly
            let fallback = "\(baseURL)/v1/oauth/google/authorize?redirect_url=\(redirectURL.urlEncoded)"
            guard let fallbackURL = URL(string: fallback) else {
                throw ClerkAuthError.unknown("Could not get Google OAuth URL from Clerk.")
            }
            try await openAndCompleteOAuth(url: fallbackURL, baseURL: baseURL)
            return
        }

        try await openAndCompleteOAuth(url: authURL, baseURL: baseURL)
    }

    private func openAndCompleteOAuth(url: URL, baseURL: String) async throws {
        // Step 2: Open in system browser via ASWebAuthenticationSession
        let callbackURL = try await openOAuthSession(url: url, callbackScheme: "holmes")

        // Step 3: Extract rotating_token_nonce from callback URL
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let nonce = components?.queryItems?.first(where: { $0.name == "rotating_token_nonce" })?.value

        // Step 4: Fetch client state (with nonce if available)
        var clientComponents = URLComponents(string: "\(baseURL)/v1/client")!
        if let nonce {
            clientComponents.queryItems = [URLQueryItem(name: "rotating_token_nonce", value: nonce)]
        }
        let clientReq = makeRequest(clientComponents.url!.absoluteString, method: "GET")
        let (clientData, clientResp) = try await URLSession.shared.data(for: clientReq)
        try throwIfError(clientResp, data: clientData)

        let clientResult = try JSONDecoder.clerk.decode(ClerkClientResponse.self, from: clientData)
        guard let token = clientResult.client?.sessions?.first?.lastActiveToken?.jwt else {
            throw ClerkAuthError.unknown("OAuth succeeded but no session token found.")
        }

        // Get email from callback params or fallback
        let email = components?.queryItems?.first(where: { $0.name == "email" })?.value
            ?? "google-user@oauth"
        persistSession(token: token, email: email)
    }

    // MARK: - Validate Stored Session (local JWT expiry check — no API call)

    func validateStoredSession() async -> Bool {
        guard let token = KeychainManager.load(
            service: ClerkConfig.keychainService,
            account: ClerkConfig.sessionTokenAccount
        ) else {
            return false
        }

        // Decode JWT payload to check expiry locally
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64Padded: String(parts[1])),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: payloadData),
              let exp = payload.exp else {
            clearSession()
            return false
        }

        guard Date().timeIntervalSince1970 < exp else {
            clearSession()
            return false
        }

        // Token still valid — restore user state
        currentUserEmail = KeychainManager.load(
            service: ClerkConfig.keychainService,
            account: ClerkConfig.userEmailAccount
        )
        isAuthenticated = true
        return true
    }

    // MARK: - Web-based session (called by WKWebView after hosted sign-in)

    func acceptWebSession(token: String, email: String) {
        persistSession(token: token, email: email)
    }

    // MARK: - Sign Out

    func signOut() {
        clearSession()
    }

    // MARK: - OAuth Session

    private func openOAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    // User cancelled is not a real error
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: ClerkAuthError.clerkError("Sign-in was cancelled."))
                    } else {
                        continuation.resume(throwing: ClerkAuthError.networkError(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: ClerkAuthError.unknown("No callback URL received."))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = OAuthPresentationContext.shared
            session.start()
        }
    }

    // MARK: - Private Helpers

    private func makeRequest(_ urlString: String, method: String) -> URLRequest {
        // Append __clerk_db_jwt as query param for dev instances
        var finalURL = urlString
        if let token = devBrowserToken {
            let sep = urlString.contains("?") ? "&" : "?"
            finalURL += "\(sep)__clerk_db_jwt=\(token)"
        }
        var req = URLRequest(url: URL(string: finalURL)!)
        req.httpMethod = method
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Use dev browser token as Bearer if available, otherwise fall back to publishable key
        let bearer = devBrowserToken ?? ClerkConfig.publishableKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func throwIfError(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClerkAuthError.networkError("No HTTP response received.")
        }

        if (200...299).contains(http.statusCode) { return }

        // Parse Clerk's error body for real message
        if let clerkErr = try? JSONDecoder.clerk.decode(ClerkErrorResponse.self, from: data),
           let firstError = clerkErr.errors?.first {
            let msg = firstError.longMessage ?? firstError.message
            throw ClerkAuthError.clerkError(msg)
        }

        switch http.statusCode {
        case 429:
            throw ClerkAuthError.clerkError("Too many attempts. Please wait a moment and try again.")
        case 401, 403:
            throw ClerkAuthError.clerkError("Authentication failed. Check your credentials.")
        case 404:
            throw ClerkAuthError.invalidConfiguration
        default:
            throw ClerkAuthError.unknown("Request failed (HTTP \(http.statusCode)).")
        }
    }

    private func persistSession(token: String, email: String) {
        KeychainManager.save(token, service: ClerkConfig.keychainService, account: ClerkConfig.sessionTokenAccount)
        KeychainManager.save(email, service: ClerkConfig.keychainService, account: ClerkConfig.userEmailAccount)
        isAuthenticated = true
        currentUserEmail = email
    }

    private func clearSession() {
        KeychainManager.delete(service: ClerkConfig.keychainService, account: ClerkConfig.sessionTokenAccount)
        KeychainManager.delete(service: ClerkConfig.keychainService, account: ClerkConfig.userEmailAccount)
        isAuthenticated = false
        currentUserEmail = nil
    }
}

// MARK: - OAuth Presentation Context

final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

private extension Data {
    init?(base64Padded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}

private extension JSONDecoder {
    static let clerk: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
