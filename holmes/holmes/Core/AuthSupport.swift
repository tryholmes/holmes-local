import Foundation

// Pure helpers behind sign in and install tracking. Nothing here imports the
// Appwrite SDK, so holmes/tests/run-auth-validation-tests.sh can compile this
// file on its own.

// MARK: - Input validation

enum AuthMode: String, CaseIterable {
    case signIn
    case createAccount
}

enum AuthValidation {
    static let minimumPasswordLength = 8

    static func isValidEmail(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.count <= 254, !email.contains(" ") else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, local.count <= 64 else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return true
    }

    /// The first problem with the form, phrased for the user, or nil when the
    /// input is fine to send.
    static func problem(mode: AuthMode, name: String, email: String, password: String) -> String? {
        if mode == .createAccount, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter your name."
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty { return "Enter your email address." }
        if !isValidEmail(trimmedEmail) { return "That email address doesn\u{2019}t look right." }
        if password.isEmpty { return "Enter your password." }
        if mode == .createAccount, password.count < minimumPasswordLength {
            return "Use a password of at least \(minimumPasswordLength) characters."
        }
        return nil
    }
}

// MARK: - Error messages

enum AuthErrorMessages {
    static let offline = "Holmes can\u{2019}t reach the sign in server. Check your internet connection and try again."
    static let generic = "Something went wrong signing you in. Please try again."

    /// Maps an Appwrite error code and type to a user facing message. `code`
    /// is nil or 0 when the request never got an HTTP response.
    static func message(code: Int?, type: String?, mode: AuthMode) -> String {
        let type = type ?? ""
        switch type {
        case "user_invalid_credentials", "user_password_mismatch":
            return "That email and password don\u{2019}t match. Check them and try again."
        case "user_already_exists", "user_email_already_exists":
            return "An account with this email already exists. Sign in instead."
        case "password_recently_used", "password_personal_data":
            return "Choose a different password."
        case "user_blocked":
            return "This account has been disabled."
        case "general_rate_limit_exceeded":
            return "Too many attempts. Wait a minute, then try again."
        case "user_session_already_exists":
            return "You\u{2019}re already signed in."
        default:
            break
        }
        switch code ?? 0 {
        case 0:
            return offline
        case 401:
            return mode == .signIn
                ? "That email and password don\u{2019}t match. Check them and try again."
                : generic
        case 409:
            return "An account with this email already exists. Sign in instead."
        case 400:
            if type == "general_argument_invalid" || type.isEmpty {
                return mode == .createAccount
                    ? "Check your details. Passwords need at least \(AuthValidation.minimumPasswordLength) characters."
                    : "Check your email and password, then try again."
            }
            return generic
        case 429:
            return "Too many attempts. Wait a minute, then try again."
        case 500...599:
            return "The sign in server is having trouble. Try again in a moment."
        default:
            return generic
        }
    }
}

// MARK: - Device facts

struct DeviceFacts: Equatable {
    var holmesVersion: String
    var macosVersion: String
    var macModel: String
    var region: String
    var locale: String

    static func formatOSVersion(major: Int, minor: Int, patch: Int) -> String {
        "\(major).\(minor).\(patch)"
    }

    /// sysctl returns a NUL terminated C string; keep what precedes the first NUL.
    static func modelString(fromSysctlBytes bytes: [CChar]) -> String {
        let prefix = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "unknown" : value
    }

    static func normalized(_ value: String?, fallback: String = "unknown") -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// The JSON body for the "track" function. Email is never included; the
    /// function reads the verified user server side.
    func trackBody(event: String, installID: String) -> String {
        let payload: [String: String] = [
            "event": event,
            "install_id": installID,
            "holmes_version": holmesVersion,
            "macos_version": macosVersion,
            "mac_model": macModel,
            "region": region,
            "locale": locale,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

// MARK: - Install ping throttle

protocol CloudKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func date(forKey key: String) -> Date?
    func set(_ value: Any?, forKey key: String)
}

final class UserDefaultsCloudStore: CloudKeyValueStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func date(forKey key: String) -> Date? { defaults.object(forKey: key) as? Date }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// Decides when the install ping is due and records success. The first ping
/// goes out as soon as possible; after that at most once every 24 hours. A
/// failed send records nothing, so the next launch simply tries again.
final class InstallPingThrottle {
    static let installIDKey = "HolmesCloud.installID"
    static let lastSentKey = "HolmesCloud.installPingLastSent"
    static let interval: TimeInterval = 24 * 60 * 60

    private let store: CloudKeyValueStore
    private let now: () -> Date
    private let lock = NSLock()
    private var inFlight = false

    init(store: CloudKeyValueStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// A random UUID created the first time it is asked for, then reused.
    var installID: String {
        lock.lock(); defer { lock.unlock() }
        if let existing = store.string(forKey: Self.installIDKey), UUID(uuidString: existing) != nil {
            return existing
        }
        let fresh = UUID().uuidString
        store.set(fresh, forKey: Self.installIDKey)
        return fresh
    }

    var isDue: Bool {
        guard let last = store.date(forKey: Self.lastSentKey) else { return true }
        let elapsed = now().timeIntervalSince(last)
        // A clock moved backwards counts as due, so a bad date can't mute pings forever.
        return elapsed >= Self.interval || elapsed < 0
    }

    /// Runs `send` when due and not already running. Returns true only when a
    /// send happened and succeeded. Never throws.
    @discardableResult
    func runIfDue(_ send: () async -> Bool) async -> Bool {
        guard claim() else { return false }
        let ok = await send()
        release(succeeded: ok)
        return ok
    }

    private func claim() -> Bool {
        lock.withLock {
            guard !inFlight, isDue else { return false }
            inFlight = true
            return true
        }
    }

    private func release(succeeded: Bool) {
        lock.withLock {
            if succeeded { store.set(now(), forKey: Self.lastSentKey) }
            inFlight = false
        }
    }
}
