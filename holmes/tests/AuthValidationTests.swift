import Foundation

final class MemoryCloudStore: CloudKeyValueStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func date(forKey key: String) -> Date? { values[key] as? Date }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

@main
struct AuthValidationTests {
    static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        // Email format.
        for good in ["a@b.co", "holmes.smoketest+1@example.com", "  person@mail.example.org  ", "x_y@sub.domain.io"] {
            expect(AuthValidation.isValidEmail(good), "Valid email rejected: \(good)")
        }
        for bad in ["", "plain", "@example.com", "a@", "a@b", "a@b.", "a@.com", "a b@c.com", "a@@b.com", "a@b.c", "a@b.c0m"] {
            expect(!AuthValidation.isValidEmail(bad), "Invalid email accepted: \(bad)")
        }

        // Form problems, in order.
        expect(AuthValidation.problem(mode: .createAccount, name: " ", email: "a@b.co", password: "12345678") == "Enter your name.",
               "Create account needs a name")
        expect(AuthValidation.problem(mode: .signIn, name: "", email: "a@b.co", password: "x") == nil,
               "Sign in needs no name and no minimum length")
        expect(AuthValidation.problem(mode: .signIn, name: "", email: "", password: "x") == "Enter your email address.",
               "Empty email is reported")
        expect(AuthValidation.problem(mode: .signIn, name: "", email: "nope", password: "x")?.contains("look right") == true,
               "Malformed email is reported")
        expect(AuthValidation.problem(mode: .signIn, name: "", email: "a@b.co", password: "") == "Enter your password.",
               "Empty password is reported")
        expect(AuthValidation.problem(mode: .createAccount, name: "Ann", email: "a@b.co", password: "1234567")?.contains("at least 8") == true,
               "Seven character password is too short")
        expect(AuthValidation.problem(mode: .createAccount, name: "Ann", email: "a@b.co", password: "12345678") == nil,
               "Eight character password is fine")

        // Error mapping.
        let invalid = AuthErrorMessages.message(code: 401, type: "user_invalid_credentials", mode: .signIn)
        expect(invalid.contains("don\u{2019}t match"), "Invalid credentials message")
        let exists = AuthErrorMessages.message(code: 409, type: "user_already_exists", mode: .createAccount)
        expect(exists.contains("already exists") && exists.contains("Sign in"), "Existing user is told to sign in")
        expect(AuthErrorMessages.message(code: 409, type: nil, mode: .createAccount) == exists, "Bare 409 means existing user")
        expect(AuthErrorMessages.message(code: 400, type: "general_argument_invalid", mode: .createAccount).contains("at least 8"),
               "Invalid argument on sign up mentions password length")
        expect(AuthErrorMessages.message(code: nil, type: nil, mode: .signIn) == AuthErrorMessages.offline, "No response means offline")
        expect(AuthErrorMessages.message(code: 0, type: "", mode: .createAccount) == AuthErrorMessages.offline, "Code 0 means offline")
        expect(AuthErrorMessages.message(code: 429, type: "general_rate_limit_exceeded", mode: .signIn).contains("Too many attempts"),
               "Rate limit message")
        expect(AuthErrorMessages.message(code: 429, type: nil, mode: .signIn).contains("Too many attempts"), "Bare 429 is rate limit")
        expect(AuthErrorMessages.message(code: 401, type: "", mode: .signIn).contains("don\u{2019}t match"), "Bare 401 on sign in")
        expect(AuthErrorMessages.message(code: 503, type: "general_server_error", mode: .signIn).contains("having trouble"),
               "Server errors are named")
        expect(AuthErrorMessages.message(code: 418, type: "something_new", mode: .signIn) == AuthErrorMessages.generic,
               "Unknown errors fall back to generic")

        // Device facts formatting.
        expect(DeviceFacts.formatOSVersion(major: 15, minor: 3, patch: 1) == "15.3.1", "OS version is major.minor.patch")
        expect(DeviceFacts.formatOSVersion(major: 26, minor: 0, patch: 0) == "26.0.0", "Zero parts are kept")
        let model: [CChar] = Array("Mac15,6".utf8CString) + [0, 0]
        expect(DeviceFacts.modelString(fromSysctlBytes: model) == "Mac15,6", "sysctl model stops at NUL")
        expect(DeviceFacts.modelString(fromSysctlBytes: [0]) == "unknown", "Empty model is unknown")
        expect(DeviceFacts.normalized(nil) == "unknown" && DeviceFacts.normalized(" US ") == "US", "Normalization")
        let facts = DeviceFacts(holmesVersion: "0.1.3", macosVersion: "15.3.1", macModel: "Mac15,6", region: "US", locale: "en_US")
        let body = facts.trackBody(event: "install", installID: "11111111-2222-3333-4444-555555555555")
        let decoded = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: String] ?? [:]
        expect(decoded == ["event": "install", "install_id": "11111111-2222-3333-4444-555555555555",
                           "holmes_version": "0.1.3", "macos_version": "15.3.1", "mac_model": "Mac15,6",
                           "region": "US", "locale": "en_US"], "Track body has exactly the documented fields")
        expect(!body.contains("email"), "Track body never carries an email")

        // Install id is created once.
        let store = MemoryCloudStore()
        let clock = TestClock()
        let throttle = InstallPingThrottle(store: store, now: { clock.now })
        let id = throttle.installID
        expect(id.count == 36 && UUID(uuidString: id) != nil, "Install id is a 36 character UUID")
        expect(throttle.installID == id, "Install id is stable")
        expect(InstallPingThrottle(store: store).installID == id, "Install id survives a new launch")

        // Throttle: first send, once per day, retry after failure.
        var sends = 0
        expect(throttle.isDue, "First ping is due")
        let failedSend = await throttle.runIfDue { sends += 1; return false }
        expect(failedSend == false, "Failed send reports false")
        expect(store.date(forKey: InstallPingThrottle.lastSentKey) == nil && throttle.isDue, "Failure records nothing and stays due")
        let goodSend = await throttle.runIfDue { sends += 1; return true }
        expect(goodSend, "Successful send reports true")
        expect(sends == 2 && !throttle.isDue, "Success records the date")
        clock.advance(hours: 23)
        let earlySend = await throttle.runIfDue { sends += 1; return true }
        expect(earlySend == false && sends == 2, "Not due again within a day")
        clock.advance(hours: 1)
        expect(throttle.isDue, "Due again after 24 hours")
        let nextDaySend = await throttle.runIfDue { sends += 1; return true }
        expect(nextDaySend && sends == 3, "Second day sends once")
        clock.advance(hours: -5)
        expect(throttle.isDue, "A clock moved backwards counts as due")

        // Throttle: no overlapping sends.
        let fresh = InstallPingThrottle(store: MemoryCloudStore(), now: { clock.now })
        var overlapping = 0
        let first = Task { await fresh.runIfDue { overlapping += 1; try? await Task.sleep(nanoseconds: 200_000_000); return true } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = await fresh.runIfDue { overlapping += 1; return true }
        let firstResult = await first.value
        expect(firstResult && !second && overlapping == 1, "A send in flight blocks a second one")

        print("Passed \(checks) auth validation, error mapping, device facts and install ping checks")
    }
}
