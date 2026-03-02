import SwiftUI
import Foundation

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    let onTap: () -> Void
    
    var body: some View {
        if viewModel.hasNotch {
            notchContent
                .onAppear {
                    viewModel.startIdleAnimation()
                }
                .onDisappear {
                    viewModel.stopIdleAnimation()
                }
        }
    }
    
    @ViewBuilder
    private var notchContent: some View {
        switch viewModel.state {
        case .idle:
            HoverResponsiveNotchView(
                breathingPhase: viewModel.breathingPhase,
                isHovered: viewModel.isHovered,
                title: "Holmes is listening",
                subtitle: "Monitoring workspace activity",
                onTap: onTap
            )
            .onHover { hovering in
                viewModel.isHovered = hovering
            }
            
        case .active(let taskName, let progress):
            ActiveNotchView(
                taskName: taskName,
                progress: progress,
                onTap: onTap
            )

        case .notification(let title, let subtitle, let symbol):
            NotificationNotchView(
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                onTap: onTap
            )
            
        case .expanded:
            ExpandedNotchView(
                onCollapse: { viewModel.collapse() },
                onTap: onTap
            )
        }
    }
}

struct NotificationNotchView: View {
    let title: String
    let subtitle: String
    let symbol: String
    let onTap: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 36, height: 36)

                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.white.opacity(0.6), radius: 6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, Color.cyan.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(width: 560, height: 56)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.8))
                    
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.15),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.7),
                                    Color.blue.opacity(0.5),
                                    Color.cyan.opacity(0.7)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 2
                        )
                    
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cyan.opacity(0.5), lineWidth: 3)
                        .blur(radius: 6)
                }
            )
            .shadow(color: Color.cyan.opacity(0.4), radius: 20, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
            .scaleEffect(pulse ? 1.0 : 0.98)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: pulse)
        }
        .buttonStyle(.plain)
        .onAppear {
            pulse = true
        }
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
    }
}

struct IdleNotchView: View {
    let breathingPhase: CGFloat
    let isHovered: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                // WIDE futuristic bar extending from notch sides
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.75 + Darwin.sin(Double(breathingPhase)) * 0.05),
                                    Color.black.opacity(0.85 + Darwin.sin(Double(breathingPhase)) * 0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    // Silver glow overlay
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.15),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 580, height: isHovered ? 32 : 28)
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.8),
                                        Color.white.opacity(0.6),
                                        Color.white.opacity(0.8)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 2
                            )
                        
                        // BRIGHT animated silver glow
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                Color.white.opacity(0.6 + Darwin.sin(Double(breathingPhase)) * 0.3),
                                lineWidth: 3
                            )
                            .blur(radius: 8)
                        
                        // Extra outer glow
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                Color.white.opacity(0.3),
                                lineWidth: 4
                            )
                            .blur(radius: 12)
                    }
                )
                .shadow(color: Color.white.opacity(0.6), radius: 20, x: 0, y: 0)
                .shadow(color: Color.white.opacity(0.4), radius: 30, x: 0, y: 0)
                .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HoverResponsiveNotchView: View {
    let breathingPhase: CGFloat
    let isHovered: Bool
    let title: String
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            IdleNotchView(breathingPhase: breathingPhase, isHovered: isHovered, onTap: onTap)

            if isHovered {
                HoverExpandedNotchView(title: title, subtitle: subtitle, onTap: onTap)
                    .offset(y: 22)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovered)
    }
}

struct HoverExpandedNotchView: View {
    let title: String
    let subtitle: String
    let onTap: () -> Void
    @State private var blink = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Holmes logo on left with silver glow
                Image("HolmesLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.white.opacity(0.6), radius: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, Color.cyan.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                
                // Futuristic glowing green indicator on right
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.green.opacity(blink ? 0.5 : 0.2),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 16
                            )
                        )
                        .frame(width: 32, height: 32)
                    
                    // Core dot with white center
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white,
                                    Color.green
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 6
                            )
                        )
                        .frame(width: 10, height: 10)
                        .opacity(blink ? 1.0 : 0.4)
                        .shadow(color: Color.green.opacity(blink ? 1.0 : 0.4), radius: blink ? 8 : 3)
                }
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: blink)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(width: 560, height: 56)
            .background(
                ZStack {
                    // Multi-layer blur
                    VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                    
                    // Deep glass background
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.8))
                    
                    // Silver tint overlay
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.06),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    // BRIGHT futuristic silver border
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.9),
                                    Color.white.opacity(0.7),
                                    Color.white.opacity(0.9)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 2.5
                        )
                    
                    // BRIGHT animated silver glow
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.7), lineWidth: 4)
                        .blur(radius: 10)
                    
                    // Extra outer glow layer
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.4), lineWidth: 6)
                        .blur(radius: 16)
                }
            )
            .shadow(color: Color.white.opacity(0.7), radius: 25, x: 0, y: 0)
            .shadow(color: Color.white.opacity(0.5), radius: 35, x: 0, y: 0)
            .shadow(color: Color.green.opacity(0.2), radius: 16, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
        }
        .buttonStyle(.plain)
        .onAppear {
            blink = true
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ActiveNotchView: View {
    let taskName: String
    let progress: Double
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.yellow.opacity(0.2))
                            .frame(width: 28, height: 28)
                        
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.yellow, Color.orange],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: Color.yellow.opacity(0.6), radius: 6)
                    }
                    
                    Text(taskName)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .lineLimit(1)
                    
                    Spacer()
                }
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.black.opacity(0.4))
                        
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, Color.white.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * progress)
                            .shadow(color: Color.white.opacity(0.6), radius: 4)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(width: 560)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.8))
                    
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.15),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.7),
                                    Color.blue.opacity(0.5),
                                    Color.cyan.opacity(0.7)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 2
                        )
                    
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cyan.opacity(0.5), lineWidth: 3)
                        .blur(radius: 6)
                }
            )
            .shadow(color: Color.cyan.opacity(0.4), radius: 20, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ExpandedNotchView: View {
    let onCollapse: () -> Void
    let onTap: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Holmes")
                    .font(NoirFonts.caption())
                    .foregroundStyle(NoirColors.paperWhite)
                
                Spacer()
                
                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NoirColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            
            HStack(spacing: 16) {
                QuickActionButton(icon: "pause.fill", label: "Pause") {}
                QuickActionButton(icon: "gearshape.fill", label: "Settings") {}
                QuickActionButton(icon: "questionmark.circle.fill", label: "Help") {}
            }
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(NoirColors.charcoalGray.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NoirColors.glassStroke, lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(NoirColors.paperWhite)
                
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NoirColors.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NoirColors.smokeGray.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        
        VStack(spacing: 40) {
            IdleNotchView(breathingPhase: 0, isHovered: false) {}
            ActiveNotchView(taskName: "Organizing files...", progress: 0.65) {}
            ExpandedNotchView(onCollapse: {}) {}
        }
        .padding()
    }
    .frame(width: 400, height: 500)
}
