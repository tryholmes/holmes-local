import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var mode: LoginMode = .signIn
    @State private var errorMessage: String? = nil
    @State private var isLoading = false

    enum LoginMode { case signIn, signUp }

    var body: some View {
        ZStack {
            // Apple glass full-window background
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    NoirCharacterHeroView(size: 110)

                    Text("HOLMES")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(NoirColors.textPrimary)
                        .tracking(5)

                    Text("Zero Prompt AI for macOS")
                        .font(NoirFonts.caption())
                        .foregroundStyle(NoirColors.goldAccent)
                }

                Spacer()

                // Form area
                VStack(spacing: 14) {
                    HStack(spacing: 0) {
                        modeTab("Sign In", target: .signIn)
                        modeTab("Create Account", target: .signUp)
                    }
                    .background(NoirColors.glassChrome)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .glassBorder(cornerRadius: 8)

                    NoirFormField("Email", text: $email)
                    NoirFormField("Password", text: $password, isSecure: true)

                    if mode == .signUp {
                        NoirFormField("Confirm Password", text: $confirmPassword, isSecure: true)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Button {
                        Task { @MainActor in
                            errorMessage = nil
                            isLoading = true
                            defer { isLoading = false }
                            do {
                                if mode == .signIn {
                                    try await ClerkAuthManager.shared.signIn(email: email, password: password)
                                } else {
                                    guard password == confirmPassword else {
                                        errorMessage = "Passwords do not match."
                                        return
                                    }
                                    try await ClerkAuthManager.shared.signUp(email: email, password: password)
                                }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Text(mode == .signIn ? "Sign In" : "Create Account")
                            .font(NoirFonts.button())
                            .foregroundStyle(Color.black.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(NoirColors.goldAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(Color.black.opacity(0.6))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)

                    Button {
                        Task { @MainActor in
                            errorMessage = nil
                            isLoading = true
                            defer { isLoading = false }
                            do {
                                try await ClerkAuthManager.shared.signInWithGoogle()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("G")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(NoirColors.goldAccent)
                            Text("Continue with Google")
                                .font(NoirFonts.button())
                                .foregroundStyle(NoirColors.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(NoirColors.glassElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .glassBorder(cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)

                    if let msg = errorMessage {
                        Text(msg)
                            .font(NoirFonts.caption())
                            .foregroundStyle(Color.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 48)
                .animation(.easeInOut(duration: 0.2), value: mode)

                Spacer()
            }
        }
        .frame(width: 520, height: 620)
    }

    private func modeTab(_ title: String, target: LoginMode) -> some View {
        Button { withAnimation { mode = target } } label: {
            Text(title)
                .font(NoirFonts.button())
                .foregroundStyle(mode == target ? Color.black.opacity(0.75) : NoirColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Group {
                        if mode == target {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(NoirColors.goldAccent)
                        } else {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.clear)
                        }
                    }
                )
                .padding(2)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LoginView()
}
