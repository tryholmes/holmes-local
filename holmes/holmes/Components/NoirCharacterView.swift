import SwiftUI

/// Displays the Holmes character with a warm sky-blue ambient glow.
struct NoirCharacterView: View {
    var size: CGFloat = 120
    var glowColor: Color = NoirColors.skyBlue
    var glowRadius: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(0.45), Color.clear],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.75
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

/// Hero variant with animated breathing glow — used in onboarding.
struct NoirCharacterHeroView: View {
    var size: CGFloat = 140
    @State private var glowScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NoirColors.warmBrown.opacity(0.22), Color.clear],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.85
                    )
                )
                .frame(width: size * 1.6, height: size * 1.6)
                .scaleEffect(glowScale)
                .blur(radius: 22)

            Image("NoirCharacter")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onAppear {
            withAnimation(NoirAnimations.breathing) {
                glowScale = 1.1
            }
        }
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        VStack(spacing: 40) {
            NoirCharacterHeroView(size: 140)
            NoirCharacterView(size: 80)
        }
    }
    .frame(width: 400, height: 500)
}
