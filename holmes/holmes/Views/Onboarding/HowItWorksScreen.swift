import SwiftUI

struct HowItWorksScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var cardsOpacity: CGFloat = 0
    @State private var cardsOffset: CGFloat = 20
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 40) {
                Text("How Holmes Works")
                    .font(NoirFonts.headline())
                    .foregroundColor(NoirColors.charcoalDark)
                
                HStack(spacing: 24) {
                    FeatureCard(
                        icon: "command",
                        shortcut: "^Space",
                        title: "Search",
                        description: "Control+Space\nfor quick commands"
                    )
                    
                    FeatureCard(
                        icon: "option",
                        shortcut: "⌥Space",
                        title: "Assistant",
                        description: "Option+Space\nfor full panel"
                    )
                    
                    FeatureCard(
                        icon: "bolt.fill",
                        shortcut: "Auto",
                        title: "Automatic",
                        description: "I learn patterns\nand act for you"
                    )
                }
                .opacity(cardsOpacity)
                .offset(y: cardsOffset)
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                NoirButton("Back", style: .ghost) {
                    viewModel.previousStep()
                }
                
                NoirButton("Continue", icon: "arrow.right") {
                    viewModel.nextStep()
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                cardsOpacity = 1.0
                cardsOffset = 0
            }
        }
    }
}

struct FeatureCard: View {
    let icon: String
    let shortcut: String
    let title: String
    let description: String
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(NoirColors.deepTeal)
                    .frame(width: 72, height: 72)
                    .pixelBevel(cornerRadius: 6)

                VStack(spacing: 4) {
                    // The tile fill (deepTeal) resolves to white: dark glyph + label.
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.black.opacity(0.82))

                    Text(shortcut)
                        .font(NoirFonts.font(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.black.opacity(0.6))
                }
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(NoirFonts.title())
                    .foregroundColor(NoirColors.charcoalDark)

                Text(description)
                    .font(NoirFonts.caption())
                    .foregroundColor(NoirColors.deepTeal)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .frame(width: 140)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        HowItWorksScreen(viewModel: OnboardingViewModel())
    }
    .frame(width: 600, height: 700)
}
