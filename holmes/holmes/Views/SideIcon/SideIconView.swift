import SwiftUI
import Lottie

enum IconState: Equatable {
    case dormant
    case listening
    case thinking
    case acting
    
    var opacity: CGFloat {
        switch self {
        case .dormant: return 0.4
        case .listening: return 0.7
        case .thinking: return 0.9
        case .acting: return 1.0
        }
    }
}

struct SideIconView: View {
    @Binding var state: IconState
    @Binding var isExpanded: Bool
    let onTap: () -> Void
    
    @State private var pulseScale: CGFloat = 1.0
    @State private var rotationAngle: Double = 0
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                backgroundGlow
                iconContent
                    .scaleEffect(pulseScale)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .opacity(state.opacity)
        .onAppear {
            startAnimations()
        }
        .onChange(of: state) { oldState, newState in
            startAnimations()
        }
    }
    
    private var backgroundGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        glowColor.opacity(0.3),
                        glowColor.opacity(0.1),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: 35
                )
            )
            .blur(radius: 8)
    }
    
    private var iconContent: some View {
        ZStack {
            Circle()
                .fill(NoirColors.deepTeal)
                .overlay(
                    Circle()
                        .stroke(NoirColors.charcoalDark, lineWidth: 2)
                )

            Image(systemName: iconName)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.creamWhite)
                .rotationEffect(.degrees(state == .thinking ? rotationAngle : 0))
        }
    }
    
    private var iconName: String {
        switch state {
        case .dormant: return "magnifyingglass"
        case .listening: return "waveform"
        case .thinking: return "gearshape"
        case .acting: return "bolt.fill"
        }
    }
    
    private var glowColor: Color {
        switch state {
        case .dormant:   return NoirColors.skyBlue
        case .listening: return NoirColors.midBlue
        case .thinking:  return NoirColors.warmBrown
        case .acting:    return NoirColors.orangeAccent
        }
    }
    
    private func startAnimations() {
        withAnimation(.default) {
            pulseScale = 1.0
            rotationAngle = 0
        }
        
        switch state {
        case .dormant:
            break
        case .listening:
            withAnimation(NoirAnimations.pulse) {
                pulseScale = 1.1
            }
        case .thinking:
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                rotationAngle = 360
            }
        case .acting:
            withAnimation(.easeInOut(duration: 0.3).repeatCount(3)) {
                pulseScale = 1.15
            }
        }
    }
}

// MARK: - Side Character View using Lottie

struct SideCharacterView: View {
    @Binding var isExpanded: Bool
    @Binding var isBlinking: Bool
    let onTap: () -> Void

    @State private var bobOffset: CGFloat = 0
    @State private var agent = HolmesAgent.shared

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isExpanded.toggle()
            }
            onTap()
        }) {
            ZStack(alignment: .topLeading) {
                Image("NoirCharacter")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 130, height: 130)
                    .rotationEffect(.degrees(-90))
                    .offset(y: bobOffset)
                    .shadow(color: NoirColors.charcoalDark.opacity(0.28), radius: 8, x: -4, y: 0)

                // Badge dot — shows when actionable context is detected
                if agent.hasNewContext {
                    Circle()
                        .fill(Color(hex: "E05252"))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(hex: "0A0F14"), lineWidth: 2))
                        .offset(x: 6, y: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: agent.hasNewContext)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 2.4)
                .repeatForever(autoreverses: true)
            ) {
                bobOffset = -5
            }
        }
    }
}

// Kept for any remaining references
struct LottieCharacterView: View {
    @Binding var isBlinking: Bool

    var body: some View {
        Image("NoirCharacter")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 110, height: 110)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        
        HStack(spacing: 40) {
            VStack {
                SideIconView(state: .constant(.dormant), isExpanded: .constant(false)) {}
                Text("Dormant").font(NoirFonts.caption())
            }
            VStack {
                SideIconView(state: .constant(.listening), isExpanded: .constant(false)) {}
                Text("Listening").font(NoirFonts.caption())
            }
        }
    }
    .frame(width: 350, height: 250)
}

#Preview("Character") {
    ZStack {
        Color.gray.opacity(0.5).ignoresSafeArea()
        SideCharacterView(isExpanded: .constant(false), isBlinking: .constant(false)) {}
    }
    .frame(width: 350, height: 250)
}
