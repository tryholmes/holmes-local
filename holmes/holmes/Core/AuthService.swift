import Foundation
import Appwrite

struct AuthUser: Equatable {
    let id: String
    let name: String
    let email: String
    /// True once the person opened the link in the verification email.
    let isVerified: Bool
}

struct AuthFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension Notification.Name {
    /// Posted after Settings signs the user out; AppDelegate shows sign in again.
    static let holmesDidSignOut = Notification.Name("HolmesDidSignOut")
}

/// Email and password accounts through Appwrite. Signing in with a verified
/// email is required to use Holmes; the SDK persists the session, so this only
/// asks once per Mac. New accounts get a verification email and wait on it.
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published private(set) var currentUser: AuthUser?
    @Published private(set) var isWorking = false
    /// When the last verification email went out, for the Resend cooldown.
    @Published private(set) var lastVerificationSentAt: Date?

    private let account = Account(HolmesCloud.client)
    private static let lastEmailKey = "HolmesCloud.lastSignedInEmail"
    private static let lastVerifiedKey = "HolmesCloud.lastSignedInVerified"

    /// Signed in with a verified email, so Holmes may start.
    var isSignedIn: Bool { currentUser?.isVerified == true }

    /// Signed in, but the email still needs verifying before Holmes starts.
    var needsVerification: Bool {
        guard let user = currentUser else { return false }
        return !user.isVerified
    }

    /// Restores the session the SDK stored on a previous launch. Returns true
    /// when the user is signed in with a verified email. Offline with a stored
    /// session counts as signed in when that account was verified last time,
    /// so Holmes still works without a connection.
    @discardableResult
    func restoreSession() async -> Bool {
        do {
            let user = try await fetchUser()
            currentUser = user
            return user.isVerified
        } catch let error as AppwriteError where (error.code ?? 0) > 0 && (error.code ?? 0) < 500 {
            currentUser = nil
            return false
        } catch {
            guard HolmesCloud.hasStoredSession else {
                currentUser = nil
                return false
            }
            let email = UserDefaults.standard.string(forKey: Self.lastEmailKey) ?? ""
            let verified = UserDefaults.standard.bool(forKey: Self.lastVerifiedKey)
            currentUser = AuthUser(id: "", name: "", email: email, isVerified: verified)
            return verified
        }
    }

    func signIn(email: String, password: String) async throws {
        try validate(mode: .signIn, name: "", email: email, password: password)
        isWorking = true
        defer { isWorking = false }
        try await createSession(email: normalized(email), password: password, mode: .signIn)
        try await finishSignIn(mode: .signIn)
    }

    func signUp(name: String, email: String, password: String) async throws {
        try validate(mode: .createAccount, name: name, email: email, password: password)
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await account.create(
                userId: ID.unique(),
                email: normalized(email),
                password: password,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            throw Self.failure(for: error, mode: .createAccount)
        }
        try await createSession(email: normalized(email), password: password, mode: .createAccount)
        try await finishSignIn(mode: .createAccount)
    }

    /// Emails a fresh verification link. Throws a user facing failure.
    func sendVerificationEmail() async throws {
        do {
            _ = try await account.createEmailVerification(url: EmailVerification.redirectURL)
            lastVerificationSentAt = Date()
        } catch {
            throw Self.verificationFailure(for: error)
        }
    }

    /// Asks Appwrite whether the email was verified since the last check.
    /// Returns true once it is, and records the sign in for analytics then.
    @discardableResult
    func refreshVerification() async -> Bool {
        guard let user = currentUser, !user.isVerified else { return isSignedIn }
        guard let fresh = try? await fetchUser() else { return false }
        currentUser = fresh
        if fresh.isVerified { HolmesCloud.sendSignInEvent() }
        return fresh.isVerified
    }

    func signOut() async {
        do {
            _ = try await account.deleteSession(sessionId: "current")
        } catch {
            print("[Auth] Remote sign out failed, clearing the local session anyway: \(error.localizedDescription)")
        }
        HolmesCloud.clearStoredSession()
        UserDefaults.standard.removeObject(forKey: Self.lastVerifiedKey)
        currentUser = nil
        lastVerificationSentAt = nil
    }

    // MARK: Helpers

    private func validate(mode: AuthMode, name: String, email: String, password: String) throws {
        if let problem = AuthValidation.problem(mode: mode, name: name, email: email, password: password) {
            throw AuthFailure(message: problem)
        }
    }

    private func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createSession(email: String, password: String, mode: AuthMode) async throws {
        do {
            _ = try await account.createEmailPasswordSession(email: email, password: password)
        } catch let error as AppwriteError where error.type == "user_session_already_exists" {
            // A stale session is still stored; replace it with this account's.
            _ = try? await account.deleteSession(sessionId: "current")
            do {
                _ = try await account.createEmailPasswordSession(email: email, password: password)
            } catch {
                throw Self.failure(for: error, mode: mode)
            }
        } catch {
            throw Self.failure(for: error, mode: mode)
        }
    }

    /// Only a verified account counts as a sign in. Otherwise a verification
    /// email goes out (unless one just did) and the caller shows the waiting
    /// screen; the sign in is recorded when the link is opened.
    private func finishSignIn(mode: AuthMode) async throws {
        let user: AuthUser
        do {
            user = try await fetchUser()
        } catch {
            throw Self.failure(for: error, mode: mode)
        }
        currentUser = user
        if user.isVerified {
            HolmesCloud.sendSignInEvent()
        } else if EmailVerification.secondsUntilResend(lastSent: lastVerificationSentAt, now: Date()) == 0 {
            // The waiting screen offers Resend, so a failed send isn't fatal.
            try? await sendVerificationEmail()
        }
    }

    private func fetchUser() async throws -> AuthUser {
        let user = try await account.get()
        UserDefaults.standard.set(user.email, forKey: Self.lastEmailKey)
        UserDefaults.standard.set(user.emailVerification, forKey: Self.lastVerifiedKey)
        return AuthUser(id: user.id, name: user.name, email: user.email, isVerified: user.emailVerification)
    }

    nonisolated static func failure(for error: Error, mode: AuthMode) -> AuthFailure {
        if let failure = error as? AuthFailure { return failure }
        if let appwrite = error as? AppwriteError {
            return AuthFailure(message: AuthErrorMessages.message(code: appwrite.code, type: appwrite.type, mode: mode))
        }
        // Anything that isn't an Appwrite response is a transport failure.
        return AuthFailure(message: AuthErrorMessages.offline)
    }

    nonisolated static func verificationFailure(for error: Error) -> AuthFailure {
        if let failure = error as? AuthFailure { return failure }
        guard let appwrite = error as? AppwriteError else { return AuthFailure(message: AuthErrorMessages.offline) }
        switch appwrite.code ?? 0 {
        case 0: return AuthFailure(message: AuthErrorMessages.offline)
        case 429: return AuthFailure(message: AuthErrorMessages.message(code: 429, type: appwrite.type, mode: .signIn))
        default: return AuthFailure(message: EmailVerification.sendFailed)
        }
    }
}
