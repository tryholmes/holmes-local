import SwiftUI

/// Displays the noir character SVG with a soft glow and optional film grain.
struct NoirCharacterView: View {
    var size: CGFloat = 120
    var glowColor: Color = NoirColors.fogGray
    var glowRadius: CGFloat = 20

    var body: some View {
        ZStack {
            // Soft ambient glow behind the character
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(0.25), Color.clear],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.7
                    )
                )
                .frame(width: size * 1.4, height: size * 1.4)
                .blur(radius: glowRadius)

            Image("NoirCharacter")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.4, height: size * 1.4)
    }
}

/// Larger variant with an animated breathing glow — used in onboarding header.
struct NoirCharacterHeroView: View {
    var size: CGFloat = 140
    @State private var glowScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NoirColors.fogGray.opacity(0.18), Color.clear],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.8
                    )
                )
                .frame(width: size * 1.6, height: size * 1.6)
                .scaleEffect(glowScale)
                .blur(radius: 24)

            Image("NoirCharacter")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onAppear {
            withAnimation(NoirAnimations.breathing) {
                glowScale = 1.12
            }
        }
    }
}

#Preview {
    ZStack {
        NoirColors.charcoalGray.ignoresSafeArea()
        VStack(spacing: 40) {
            NoirCharacterHeroView(size: 140)
            NoirCharacterView(size: 80)
        }
    }
    .frame(width: 400, height: 500)
}
