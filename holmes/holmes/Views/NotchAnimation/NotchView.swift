// Ported from boring.notch (GPL-3.0, © TheBoredTeam and contributors):
// https://github.com/TheBoredTeam/boring.notch
//   - components/Notch/NotchShape.swift (itself from MrKai77/DynamicNotchKit):
//     the exact notch path — concave top corners flaring into the flat top edge,
//     convex rounded bottom corners.
//   - ContentView.swift: the layout structure (NotchLayout padding/background/
//     clipShape/1px top seam overlay/shadow), the open/close springs
//     (open 0.42/0.8, close 0.45/1.0, interactive hover 0.38/0.8), the hover
//     open/close handling with its delays, and the closed-state "wings" +
//     sneak-peek row structure (battery-notification / music-live-activity
//     patterns).
//   - components/Notch/BoringHeader.swift: the open-state header (leading area,
//     black NotchShape mask over the physical notch, trailing capsule buttons).
// Only the CONTENT is Holmes's (task + step + progress + live context instead of
// music/battery/shelf). See THIRD_PARTY_NOTICES.md.

import SwiftUI

// MARK: - NotchShape (exact port)

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat? = nil, bottomCornerRadius: CGFloat? = nil) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

// MARK: - NotchView (ContentView port)

@MainActor
struct NotchView: View {
    @ObservedObject var vm: NotchViewModel

    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var haptics: Bool = false

    // Shared interactive spring for movement/resizing (boring.notch's).
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private var topCornerRadius: CGFloat {
        vm.notchState == .open
            ? NotchGeometry.cornerRadiusInsets.opened.top
            : NotchGeometry.cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: vm.notchState == .open
                ? NotchGeometry.cornerRadiusInsets.opened.bottom
                : NotchGeometry.cornerRadiusInsets.closed.bottom
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                            ? NotchGeometry.cornerRadiusInsets.opened.top
                            : NotchGeometry.cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        // The 1px seam filler that welds the island to the screen edge.
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (vm.notchState == .open || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .animation(
                        vm.notchState == .open
                            ? .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                            : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0),
                        value: vm.notchState)
                    .animation(.smooth, value: vm.sneakPeek)
                    .animation(.smooth, value: vm.taskActive)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Open Holmes") {
                            MainPanelWindowController.shared.toggle()
                        }
                    }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: NotchGeometry.windowSize.width, maxHeight: NotchGeometry.windowSize.height, alignment: .top)
        .compositingGroup()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if vm.sneakPeek.show && vm.notchState == .closed {
                    sneakPeekRow
                        .fixedSize()
                } else if vm.taskActive && vm.notchState == .closed {
                    taskLiveActivity
                } else if vm.notchState == .open {
                    NotchHeader(vm: vm)
                        .frame(height: max(24, vm.effectiveClosedNotchHeight))
                } else {
                    Rectangle()
                        .fill(.clear)
                        .frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                }
            }
            .zIndex(2)

            if vm.notchState == .open {
                NotchHomeView(vm: vm)
                    .transition(
                        .scale(scale: 0.8, anchor: .top)
                            .combined(with: .opacity)
                            .animation(.smooth(duration: 0.35))
                    )
                    .zIndex(1)
            }
        }
    }

    /// boring.notch's battery-notification row structure: text on the left wing,
    /// a black spacer exactly as wide as the physical notch, symbol on the right
    /// wing. Holmes uses it for context flashes, step banners, and run results.
    @ViewBuilder
    private var sneakPeekRow: some View {
        HStack(spacing: 0) {
            HStack {
                Text(vm.sneakPeek.subtitle.isEmpty ? vm.sneakPeek.title : vm.sneakPeek.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 210, alignment: .trailing)
            }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 10)

            HStack(spacing: 6) {
                Image(systemName: vm.sneakPeek.symbol)
                    .foregroundStyle(.white)
                    .imageScale(.medium)
                Text(vm.sneakPeek.subtitle.isEmpty ? "" : vm.sneakPeek.title)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    /// boring.notch's music-live-activity wings, carrying Holmes's running task:
    /// bolt on the left wing, circular progress on the right wing, black spacer
    /// over the physical notch between them.
    @ViewBuilder
    private var taskLiveActivity: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.yellow.opacity(0.18))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.yellow)
            }
            .frame(
                width: max(0, vm.effectiveClosedNotchHeight - 12),
                height: max(0, vm.effectiveClosedNotchHeight - 12)
            )

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - NotchGeometry.cornerRadiusInsets.closed.top)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, vm.taskProgress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(
                width: max(0, vm.effectiveClosedNotchHeight - 14),
                height: max(0, vm.effectiveClosedNotchHeight - 14)
            )
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover management (exact port of boring.notch's handleHover)

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            if vm.notchState == .closed {
                haptics.toggle()
            }

            guard vm.notchState == .closed, !vm.sneakPeek.show else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard vm.notchState == .closed,
                          isHovering,
                          !vm.sneakPeek.show else { return }
                    doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        isHovering = false
                    }

                    if vm.notchState == .open {
                        vm.close()
                    }
                }
            }
        }
    }
}

// MARK: - NotchHeader (BoringHeader port)

@MainActor
struct NotchHeader: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Text("Holmes")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                // The black mask that keeps the physical notch's silhouette
                // visible inside the opened panel (boring.notch's signature).
                Rectangle()
                    .fill((NSScreen.main?.safeAreaInsets.top ?? 0) > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    Button(action: {
                        MainPanelWindowController.shared.toggle()
                    }) {
                        Capsule()
                            .fill(.black)
                            .frame(width: 30, height: 30)
                            .overlay {
                                Image(systemName: "rectangle.expand.vertical")
                                    .foregroundColor(.white)
                                    .padding()
                                    .imageScale(.medium)
                            }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
    }
}

// MARK: - NotchHomeView (NotchHomeView slot, Holmes content)

@MainActor
struct NotchHomeView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What Holmes SEES right now.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: vm.contextSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.contextLine.isEmpty ? "Watching your screen" : vm.contextLine)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("Live context")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(Color.white.opacity(0.1))

            // What Holmes is DOING (or last did).
            if vm.taskActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.yellow)
                        Text(vm.taskStep.isEmpty ? vm.taskName : vm.taskStep)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    ProgressView(value: vm.taskProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                }
            } else if !vm.lastResult.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                    Text(vm.lastResult)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.gray)
                    Text("No task running — Holmes acts when it spots something useful")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
