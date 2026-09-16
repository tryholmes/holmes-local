import SwiftUI
import AppKit

/// Required account step. Used as the first onboarding step and, for people
/// who finished onboarding before accounts existed or who signed out, inside
/// its own small window at launch. There is no skip.
struct SignInScreen: View {
    @ObservedObject var auth: AuthService
    let onSignedIn: () -> Void

    @State private var mode: AuthMode
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var contentOpacity: CGFloat = 0

    static let privacyLine = "Holmes stores your email, region, macOS version, and Holmes version to count users. Everything else stays on this Mac."

    init(auth: AuthService, initialMode: AuthMode = .createAccount, onSignedIn: @escaping () -> Void) {
        self.auth = auth
        self._mode = State(initialValue: initialMode)
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Text("holmes")
                        .font(NoirFonts.brand(size: 48))
                        .foregroundStyle(NoirColors.charcoalDark)

                    Text(mode == .signIn ? "Sign in to continue" : "Create your Holmes account")
                        .font(NoirFonts.body())
                        .foregroundStyle(NoirColors.deepTeal)
                }

                modePicker

                VStack(spacing: 10) {
                    if mode == .createAccount {
                        NoirFormField("Name", text: $name)
                    }
                    NoirFormField("Email", text: $email)
                    NoirFormField("Password", text: $password, isSecure: true)

                    if mode == .createAccount {
                        Text("At least \(AuthValidation.minimumPasswordLength) characters.")
                            .font(NoirFonts.caption())
                            .foregroundStyle(NoirColors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onSubmit(submit)
                .disabled(auth.isWorking)

                if let errorMessage {
                    Text(errorMessage)
                        .font(NoirFonts.caption())
                        .foregroundStyle(NoirColors.error)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 340)
            .opacity(contentOpacity)

            Spacer()

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    if auth.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(NoirColors.accent)
                    }
                    NoirButton(auth.isWorking ? workingTitle : primaryTitle, icon: "arrow.right", action: submit)
                        .disabled(auth.isWorking)
                }

                Text(Self.privacyLine)
                    .font(NoirFonts.caption())
                    .foregroundStyle(NoirColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(contentOpacity)
            .padding(.bottom, 44)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: errorMessage)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                contentOpacity = 1.0
            }
        }
    }

    private var primaryTitle: String { mode == .signIn ? "Sign In" : "Create Account" }
    private var workingTitle: String { mode == .signIn ? "Signing In" : "Creating Account" }

    private var modePicker: some View {
        HStack(spacing: 3) {
            modeButton(.signIn, title: "Sign in")
            modeButton(.createAccount, title: "Create account")
        }
        .padding(3)
        .background(NoirColors.glassChrome)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .glassBorder(cornerRadius: 8)
        .disabled(auth.isWorking)
    }

    private func modeButton(_ target: AuthMode, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                mode = target
                errorMessage = nil
            }
        } label: {
            Text(title)
                .font(NoirFonts.font(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(mode == target ? NoirColors.ctaForeground : NoirColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(mode == target ? NoirColors.ctaBackground : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        guard !auth.isWorking else { return }
        if let problem = AuthValidation.problem(mode: mode, name: name, email: email, password: password) {
            errorMessage = problem
            return
        }
        errorMessage = nil
        let mode = self.mode
        Task { @MainActor in
            do {
                if mode == .signIn {
                    try await auth.signIn(email: email, password: password)
                } else {
                    try await auth.signUp(name: name, email: email, password: password)
                }
                password = ""
                onSignedIn()
            } catch {
                errorMessage = AuthService.failure(for: error, mode: mode).message
            }
        }
    }
}

/// The standalone sign in window for people past onboarding without a session.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    static let shared = SignInWindowController()

    private var window: NSWindow?
    private var onSignedIn: (() -> Void)?
    private var completed = false

    var isVisible: Bool { window?.isVisible ?? false }

    func show(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        completed = false

        let root = ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            SignInScreen(auth: .shared, initialMode: .signIn) { [weak self] in
                self?.finish()
            }
        }
        .frame(width: 480, height: 600)
        .preferredColorScheme(.dark)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        completed = true
        let finished = window
        window = nil
        finished?.close()
        let callback = onSignedIn
        onSignedIn = nil
        callback?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !completed else { return }
        // Signing in is required: closing the window quits, and the next
        // launch asks again.
        window = nil
        NSApp.terminate(nil)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        SignInScreen(auth: .shared) {}
    }
    .frame(width: 600, height: 700)
    .preferredColorScheme(.dark)
}
