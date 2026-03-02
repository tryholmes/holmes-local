import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var mode: LoginMode = .signIn

    enum LoginMode { case signIn, signUp }

    var body: some View {
        ZStack {
            NoirColors.skyBlue.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    NoirCharacterHeroView(size: 110)

                    Text("HOLMES")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(NoirColors.charcoalDark)
                        .tracking(5)

                    Text("Zero Prompt AI for macOS")
                        .font(NoirFonts.caption())
                        .foregroundStyle(NoirColors.deepTeal)
                }

                Spacer()

                // Form area
                VStack(spacing: 14) {
                    HStack(spacing: 0) {
                        modeTab("Sign In", target: .signIn)
                        modeTab("Create Account", target: .signUp)
                    }
                    .background(NoirColors.midBlue.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .pixelBevel(cornerRadius: 6)

                    NoirFormField("Email", text: $email)
                    NoirFormField("Password", text: $password, isSecure: true)

                    if mode == .signUp {
                        NoirFormField("Confirm Password", text: .constant(""), isSecure: true)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

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
                            .foregroundStyle(NoirColors.creamWhite)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(NoirColors.deepTeal)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .pixelBevel(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)

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
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(NoirColors.orangeAccent)
                            Text("Continue with Google")
                                .font(NoirFonts.button())
                                .foregroundStyle(NoirColors.charcoalDark)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(NoirColors.creamWhite)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .pixelBevel(cornerRadius: 6)
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
                .foregroundStyle(mode == target ? NoirColors.creamWhite : NoirColors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Group {
                        if mode == target {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(NoirColors.deepTeal)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(NoirColors.warmCream)
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
