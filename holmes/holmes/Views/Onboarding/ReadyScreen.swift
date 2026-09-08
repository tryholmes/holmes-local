import SwiftUI

struct ReadyScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let onComplete: () -> Void
    
    @State private var checkmarkScale: CGFloat = 0
    @State private var checkmarkOpacity: CGFloat = 0
    @State private var contentOpacity: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                ZStack {
                    NoirCharacterView(size: 100, glowColor: NoirColors.orangeAccent, glowRadius: 20)

                    // Success ring using orange accent
                    Circle()
                        .stroke(NoirColors.orangeAccent.opacity(0.5), lineWidth: 2)
                        .frame(width: 120, height: 120)
                }
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)
                
                VStack(spacing: 12) {
                    Text("You're All Set")
                        .font(NoirFonts.headline())
                        .foregroundStyle(NoirColors.charcoalDark)

                    Text("Holmes is now learning from\nyour desktop activity")
                        .font(NoirFonts.body())
                        .foregroundStyle(NoirColors.deepTeal)
                        .multilineTextAlignment(.center)
                }
                .opacity(contentOpacity)

                Divider()
                    .background(NoirColors.deepTeal.opacity(0.3))
                    .frame(maxWidth: 300)
                    .opacity(contentOpacity)

                VStack(spacing: 16) {
                    Text("Quick Reference")
                        .font(NoirFonts.caption())
                        .foregroundStyle(NoirColors.deepTeal)
                    
                    VStack(spacing: 12) {
                            HotkeyRow(keys: "^", secondKey: "Space", description: "Search")
                        HotkeyRow(keys: "⌥", secondKey: "Space", description: "Assistant")
                        HotkeyRow(keys: "⌘", secondKey: "\\", description: "Hide/Show")
                    }
                }
                .opacity(contentOpacity)
            }
            
            Spacer()
            
            NoirButton("Start Using Holmes", icon: "sparkles") {
                viewModel.completeOnboarding()
                onComplete()
            }
            .opacity(contentOpacity)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                contentOpacity = 1.0
            }
        }
    }
}

struct HotkeyRow: View {
    let keys: String
    let secondKey: String
    let description: String
    
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                KeyCap(text: keys)
                Text("+")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.deepTeal)
                KeyCap(text: secondKey)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.deepTeal)

            Text(description)
                .font(NoirFonts.caption())
                .foregroundColor(NoirColors.charcoalDark)
        }
    }
}

struct KeyCap: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NoirColors.deepTeal)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .pixelBevel(cornerRadius: 6)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        ReadyScreen(viewModel: OnboardingViewModel()) {}
    }
    .frame(width: 600, height: 700)
}
