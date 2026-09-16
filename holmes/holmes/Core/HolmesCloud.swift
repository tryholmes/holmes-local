import Foundation
import Appwrite
import AppwriteEnums

/// The only network service Holmes talks to besides the local model: Appwrite,
/// for the account and a tiny usage count. What is sent is exactly
/// `DeviceFacts.trackBody`: an install id, the Holmes and macOS versions, the
/// Mac model, region and locale. Screen, voice and task content never leave
/// this Mac.
enum HolmesCloud {
    static let endpoint = "https://sfo.cloud.appwrite.io/v1"
    static let projectID = "holmes"
    static let trackFunctionID = "track"

    static let client: Client = Client()
        .setEndpoint(endpoint)
        .setProject(projectID)

    private static let throttle = InstallPingThrottle(store: UserDefaultsCloudStore())

    static var installID: String { throttle.installID }

    // MARK: Device facts

    static var deviceFacts: DeviceFacts {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceFacts(
            holmesVersion: DeviceFacts.normalized(
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
            macosVersion: DeviceFacts.formatOSVersion(
                major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion),
            macModel: macModel(),
            region: DeviceFacts.normalized(Locale.current.region?.identifier),
            locale: DeviceFacts.normalized(Locale.current.identifier)
        )
    }

    private static func macModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return DeviceFacts.modelString(fromSysctlBytes: bytes)
    }

    // MARK: Events

    /// Fire and forget. Sends once per install, then at most once a day. A
    /// failure is only logged; the next launch tries again.
    static func sendInstallPing() {
        Task.detached(priority: .utility) {
            await throttle.runIfDue { await track(event: "install") }
        }
    }

    /// Fire and forget, after a successful sign in or account creation.
    static func sendSignInEvent() {
        Task.detached(priority: .utility) {
            _ = await track(event: "signin")
        }
    }

    @discardableResult
    static func track(event: String) async -> Bool {
        let body = deviceFacts.trackBody(event: event, installID: installID)
        do {
            let execution = try await Functions(client).createExecution(
                functionId: trackFunctionID,
                body: body,
                async: false,
                path: "/",
                method: .pOST,
                headers: ["content-type": "application/json"]
            )
            let ok = (200..<300).contains(execution.responseStatusCode)
                && execution.responseBody.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
            if !ok {
                print("[HolmesCloud] \(event) event not accepted (status \(execution.responseStatusCode))")
            }
            return ok
        } catch {
            print("[HolmesCloud] \(event) event failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Stored session

    /// The SDK keeps the session cookie in UserDefaults under the endpoint host.
    private static var cookieKey: String { URL(string: endpoint)?.host ?? "" }

    /// True when a session cookie is stored locally. Used only when the server
    /// can't be reached, so an offline launch doesn't lock a signed in user out.
    static var hasStoredSession: Bool {
        let cookies = UserDefaults.standard.stringArray(forKey: cookieKey) ?? []
        return cookies.contains { cookie in
            cookie.hasPrefix("a_session_\(projectID)=")
                && !cookie.hasPrefix("a_session_\(projectID)=;")
                && !cookie.lowercased().contains("max-age=0")
        }
    }

    static func clearStoredSession() {
        UserDefaults.standard.removeObject(forKey: cookieKey)
    }
}
