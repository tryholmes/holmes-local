import SwiftUI

struct WelcomeScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var iconScale: CGFloat = 0.82
    @State private var iconOpacity: CGFloat = 0
    @State private var textOpacity: CGFloat = 0
    @State private var buttonOpacity: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                NoirCharacterHeroView(size: 140)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                VStack(spacing: 10) {
                    Text("holmes")
                        .font(NoirFonts.brand(size: 60))
                        .foregroundStyle(NoirColors.charcoalDark)

                    Text("Zero Prompt AI for macOS")
                        .font(NoirFonts.body())
                        .foregroundStyle(NoirColors.deepTeal)
                }
                .opacity(textOpacity)

                Text("I learn from your actions and help\nbefore you even ask.")
                    .font(NoirFonts.body())
                    .foregroundStyle(NoirColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .opacity(textOpacity)
            }

            Spacer()

            NoirButton("Get Started", icon: "arrow.right") {
                viewModel.nextStep()
            }
            .opacity(buttonOpacity)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.22)) {
                textOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.4)) {
                buttonOpacity = 1.0
            }
        }
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        WelcomeScreen(viewModel: OnboardingViewModel())
    }
    .frame(width: 600, height: 700)
}
