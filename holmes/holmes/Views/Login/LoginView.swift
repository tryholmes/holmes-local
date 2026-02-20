import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var mode: LoginMode = .signIn

    enum LoginMode { case signIn, signUp }

    var body: some View {
        ZStack {
            NoirColors.charcoalGray.ignoresSafeArea()
            GrainOverlay(opacity: 0.05).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Character + title
                VStack(spacing: 12) {
                    NoirCharacterHeroView(size: 110)

                    Text("holmes")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(NoirColors.paperWhite)
                        .tracking(4)

                    Text("Zero Prompt AI for macOS")
                        .font(NoirFonts.caption())
                        .foregroundStyle(NoirColors.fogGray)
                }

                Spacer()

                // Form area
                VStack(spacing: 14) {
                    // Mode toggle
                    HStack(spacing: 0) {
                        modeTab("Sign In", target: .signIn)
                        modeTab("Create Account", target: .signUp)
                    }
                    .background(NoirColors.smokeGray.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    NoirFormField("Email", text: $email)
                    NoirFormField("Password", text: $password, isSecure: true)

                    if mode == .signUp {
                        NoirFormField("Confirm Password", text: .constant(""), isSecure: true)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Primary action — auto-accepts, no backend
                    Button {
                        Task { @MainActor in
                            ClerkAuthManager.shared.acceptWebSession(
                                token: "dev-bypass-token",
                                email: email.isEmpty ? "user@holmes.app" : email
                            )
                        }
                    } label: {
                        Text(mode == .signIn ? "Sign In" : "Create Account")
                            .font(NoirFonts.button())
                            .foregroundStyle(NoirColors.shadowBlack)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(NoirColors.paperWhite)
                            )
                    }
                    .buttonStyle(.plain)

                    // Google — auto-accepts too
                    Button {
                        Task { @MainActor in
                            ClerkAuthManager.shared.acceptWebSession(
                                token: "dev-bypass-google-token",
                                email: "google-user@holmes.app"
                            )
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("G")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.blue, .red, .yellow, .green],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Text("Continue with Google")
                                .font(NoirFonts.button())
                                .foregroundStyle(NoirColors.paperWhite)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(NoirColors.smokeGray.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(NoirColors.glassStroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
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
                .foregroundStyle(mode == target ? NoirColors.shadowBlack : NoirColors.fogGray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Group {
                        if mode == target {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(NoirColors.paperWhite)
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
