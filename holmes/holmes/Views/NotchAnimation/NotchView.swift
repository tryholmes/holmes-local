// Notch chrome adapted from notchify (MIT, © 2026 fr0sty):
// https://github.com/fr0sty1122/notchify — the `NotchShape` (concave top corners
// flaring into a flat top edge, convex rounded bottom) and the top-anchored
// "grows out of the physical notch" layout + fluid resize springs. Holmes fills it
// with its own content (task + live context + progress, and context banners).
// See THIRD_PARTY_NOTICES.md.

import SwiftUI
import Foundation

// MARK: - Animation curves (notchify baseline)

extension Animation {
    /// Island opening, closing, and resizing — a fluid, interruptible spring.
    static let notchResize = Animation.smooth(duration: 0.44, extraBounce: 0.13)
    /// Swapping the content inside the notch.
    static let notchContent = Animation.smooth(duration: 0.34, extraBounce: 0.06)
}

// MARK: - NotchShape (notchify baseline)

/// Concave top corners that flare outward into a flat top edge (like the real
/// MacBook notch), with convex rounded bottom corners — so an expanded panel
/// looks like it grew straight out of the notch.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topR = min(topCornerRadius, 9, rect.width / 2, rect.height)
        let bottomR = min(bottomCornerRadius, (rect.width - 2 * topR) / 2, rect.height - topR)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - bottomR))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + bottomR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topR - bottomR, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - bottomR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - NotchView (entry)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    let onTap: () -> Void

    var body: some View {
        // Everything hangs from the TOP edge — the physical notch — and grows
        // DOWNWARD. No re-centering, no floating: the window is pinned top-flush
        // and the content stays glued to the notch.
        ZStack(alignment: .top) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.notchResize, value: viewModel.state)
        .animation(.notchResize, value: viewModel.isHovered)
        .onAppear { viewModel.startIdleAnimation() }
        .onDisappear { viewModel.stopIdleAnimation() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            CollapsedNotchBar(
                notchSize: viewModel.notchSize,
                contextLine: viewModel.contextLine,
                breathingPhase: viewModel.breathingPhase,
                isHovered: viewModel.isHovered,
                onTap: onTap)
            .onHover { viewModel.isHovered = $0 }

        case .active(let taskName, let context, let progress):
            NotchTaskCard(
                notchWidth: viewModel.notchSize.width,
                taskName: taskName,
                context: context,
                progress: progress,
                onTap: onTap)

        case .notification(let title, let subtitle, let symbol):
            NotchBannerCard(
                notchWidth: viewModel.notchSize.width,
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                onTap: onTap)

        case .expanded:
            NotchBannerCard(
                notchWidth: viewModel.notchSize.width,
                title: "Holmes",
                subtitle: viewModel.contextLine.isEmpty ? "Monitoring workspace activity" : viewModel.contextLine,
                symbol: "sparkles",
                onTap: onTap)
        }
    }
}

// MARK: - Collapsed bar (hugs the real notch)

/// A black bar sized to the REAL notch. On a notch Mac it blends into the notch;
/// a faint animated underline glow signals Holmes is alive. Hovering reveals the
/// current live-context line in a small pill that drops below the notch.
struct CollapsedNotchBar: View {
    let notchSize: CGSize
    let contextLine: String
    let breathingPhase: CGFloat
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The notch-hugging bar itself.
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: notchSize.width, height: notchSize.height)

                // Alive-glow: a thin cyan underline that breathes.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.cyan.opacity(0.35 + Darwin.sin(Double(breathingPhase)) * 0.25))
                    .frame(width: max(24, notchSize.width * 0.5), height: 2)
                    .shadow(color: Color.cyan.opacity(0.6), radius: 4)
                    .padding(.bottom, 2)
            }
            .clipShape(NotchShape(topCornerRadius: 6, bottomCornerRadius: 10))

            // Hover reveal: the current context, dropping out of the notch.
            if isHovered, !contextLine.isEmpty {
                Text(contextLine)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        NotchShape(topCornerRadius: 8, bottomCornerRadius: 14)
                            .fill(Color.black.opacity(0.92))
                            .overlay(
                                NotchShape(topCornerRadius: 8, bottomCornerRadius: 14)
                                    .stroke(Color.cyan.opacity(0.35), lineWidth: 1))
                    )
                    .padding(.top, 1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Task card (grows out of the notch while Holmes acts)

/// The active-run card: WHAT Holmes is doing on top, the live CONTEXT beneath,
/// and a progress bar — all inside a NotchShape that flares down from the notch.
struct NotchTaskCard: View {
    let notchWidth: CGFloat
    let taskName: String
    let context: String
    let progress: Double
    let onTap: () -> Void

    private var cardWidth: CGFloat { max(360, notchWidth + 150) }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(colors: [Color.yellow, Color.orange],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: Color.yellow.opacity(0.5), radius: 5)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(taskName)
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    if !context.isEmpty {
                        Text(context)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.cyan.opacity(0.75))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [Color.cyan, Color.blue],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * progress))
                        .shadow(color: Color.cyan.opacity(0.6), radius: 4)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: cardWidth)
        .background(notchPanelBackground)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }
}

// MARK: - Banner card (context reveal / result / one-off action)

struct NotchBannerCard: View {
    let notchWidth: CGFloat
    let title: String
    let subtitle: String
    let symbol: String
    let onTap: () -> Void

    private var cardWidth: CGFloat { max(360, notchWidth + 150) }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.white.opacity(0.14)).frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.cyan.opacity(0.5), radius: 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [Color.white, Color.cyan.opacity(0.85)],
                                       startPoint: .leading, endPoint: .trailing))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: cardWidth)
        .background(notchPanelBackground)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }
}

// MARK: - Shared panel background (a NotchShape that grew from the notch)

private var notchPanelBackground: some View {
    ZStack {
        NotchShape(topCornerRadius: 9, bottomCornerRadius: 22)
            .fill(Color.black.opacity(0.92))
        NotchShape(topCornerRadius: 9, bottomCornerRadius: 22)
            .fill(LinearGradient(colors: [Color.cyan.opacity(0.10), Color.clear],
                                 startPoint: .top, endPoint: .bottom))
        NotchShape(topCornerRadius: 9, bottomCornerRadius: 22)
            .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
    }
    .shadow(color: Color.black.opacity(0.55), radius: 14, y: 8)
}

#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()
        VStack(spacing: 30) {
            CollapsedNotchBar(notchSize: CGSize(width: 200, height: 32),
                              contextLine: "Coding in Ghostty",
                              breathingPhase: 1, isHovered: true) {}
            NotchTaskCard(notchWidth: 200, taskName: "Opening Finder…",
                          context: "Organizing your Downloads", progress: 0.6) {}
            NotchBannerCard(notchWidth: 200, title: "You're coding",
                            subtitle: "Editing ScreenEngine.swift in holmes",
                            symbol: "chevron.left.forwardslash.chevron.right") {}
        }
    }
    .frame(width: 640, height: 500)
}
