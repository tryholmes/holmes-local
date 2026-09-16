import Foundation
import Appwrite

struct AuthUser: Equatable {
    let id: String
    let name: String
    let email: String
}

struct AuthFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension Notification.Name {
    /// Posted after Settings signs the user out; AppDelegate shows sign in again.
    static let holmesDidSignOut = Notification.Name("HolmesDidSignOut")
}

/// Email and password accounts through Appwrite. Signing in is required to use
/// Holmes; the SDK persists the session, so this only asks once per Mac.
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published private(set) var currentUser: AuthUser?
    @Published private(set) var isWorking = false

    private let account = Account(HolmesCloud.client)
    private static let lastEmailKey = "HolmesCloud.lastSignedInEmail"

    var isSignedIn: Bool { currentUser != nil }

    /// Restores the session the SDK stored on a previous launch. Returns true
    /// when the user is signed in. Offline with a stored session counts as
    /// signed in so Holmes still works without a connection.
    @discardableResult
    func restoreSession() async -> Bool {
        do {
            currentUser = try await fetchUser()
            return true
        } catch let error as AppwriteError where (error.code ?? 0) > 0 && (error.code ?? 0) < 500 {
            currentUser = nil
            return false
        } catch {
            guard HolmesCloud.hasStoredSession else {
                currentUser = nil
                return false
            }
            let email = UserDefaults.standard.string(forKey: Self.lastEmailKey) ?? ""
            currentUser = AuthUser(id: "", name: "", email: email)
            return true
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

    func signOut() async {
        do {
            _ = try await account.deleteSession(sessionId: "current")
        } catch {
            print("[Auth] Remote sign out failed, clearing the local session anyway: \(error.localizedDescription)")
        }
        HolmesCloud.clearStoredSession()
        currentUser = nil
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

    private func finishSignIn(mode: AuthMode) async throws {
        do {
            currentUser = try await fetchUser()
        } catch {
            throw Self.failure(for: error, mode: mode)
        }
        HolmesCloud.sendSignInEvent()
    }

    private func fetchUser() async throws -> AuthUser {
        let user = try await account.get()
        UserDefaults.standard.set(user.email, forKey: Self.lastEmailKey)
        return AuthUser(id: user.id, name: user.name, email: user.email)
    }

    nonisolated static func failure(for error: Error, mode: AuthMode) -> AuthFailure {
        if let failure = error as? AuthFailure { return failure }
        if let appwrite = error as? AppwriteError {
            return AuthFailure(message: AuthErrorMessages.message(code: appwrite.code, type: appwrite.type, mode: mode))
        }
        // Anything that isn't an Appwrite response is a transport failure.
        return AuthFailure(message: AuthErrorMessages.offline)
    }
}
