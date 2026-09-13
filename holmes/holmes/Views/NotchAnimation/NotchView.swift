// Shape and hover animations derived from boring.notch (GPL-3.0,
// © TheBoredTeam and contributors), including the NotchShape originally from
// MrKai77/DynamicNotchKit. Holmes content is laid out below the measured camera
// housing instead of the original wing layout. See THIRD_PARTY_NOTICES.md.

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
        NotchLayout()
            // Size includes the inner padding. The old intrinsic layout added
            // padding outside 640 points, clipping its wings in the host window.
            .padding(.horizontal, vm.notchState == .open ? 32 : 24)
            .frame(width: vm.notchSize.width, height: vm.notchSize.height, alignment: .top)
            .background(.black)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .shadow(color: (vm.notchState == .open || isHovering) ? .black.opacity(0.7) : .clear,
                    radius: 6)
            .animation(vm.notchState == .open
                       ? .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                       : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0),
                       value: vm.notchState)
            .animation(.smooth, value: vm.sneakPeek)
            .animation(.smooth, value: vm.taskActive)
            .contentShape(currentNotchShape)
            .onHover { handleHover($0) }
            .onTapGesture { doOpen() }
            .onChange(of: vm.notchState) { _, newState in
                if newState == .closed && isHovering {
                    withAnimation { isHovering = false }
                }
            }
            .sensoryFeedback(.alignment, trigger: haptics)
            .contextMenu {
                Button("Open Holmes") { MainPanelWindowController.shared.toggle() }
                if vm.taskActive {
                    Button("Stop current task") { WorkActivityCenter.shared.cancelSelected() }
                }
            }
            .frame(width: vm.geometry.windowSize.width, height: vm.geometry.windowSize.height,
                   alignment: .top)
            .ignoresSafeArea() // the measured hardware band is reserved explicitly below
            .compositingGroup()
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func NotchLayout() -> some View {
        if vm.notchState == .open {
            VStack(spacing: 0) {
                Color.clear.frame(height: vm.geometry.contentTopInset)
                NotchHeader()
                    .frame(height: 30)
                NotchHomeView(vm: vm)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
        } else if vm.sneakPeek.show || vm.taskActive {
            VStack(spacing: 0) {
                // Every status row is BELOW the housing. Unequal wing widths
                // can no longer move text behind the physical notch.
                Color.clear.frame(height: vm.geometry.contentTopInset)
                Group {
                    if vm.taskActive { taskLiveActivity }
                    else { sneakPeekRow }
                }
                .frame(height: 50)
                Spacer(minLength: 14)
            }
        } else {
            Color.clear
        }
    }

    private var sneakPeekRow: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.sneakPeek.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NoirColors.iconPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(NoirColors.glassSurface))
            VStack(alignment: .leading, spacing: 3) {
                if !vm.sneakPeek.subtitle.isEmpty {
                    Text(vm.sneakPeek.title)
                        .font(NoirFonts.font(size: 10, weight: .medium))
                        .foregroundStyle(NoirColors.textSecondary)
                        .lineLimit(1)
                }
                Text(vm.sneakPeek.subtitle.isEmpty ? vm.sneakPeek.title : vm.sneakPeek.subtitle)
                    .font(NoirFonts.font(size: 13, weight: .medium))
                    .foregroundStyle(NoirColors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var taskLiveActivity: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.taskPhase.symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NoirColors.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(NoirColors.accentDim))
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.taskName)
                    .font(NoirFonts.font(size: 13, weight: .medium))
                    .foregroundStyle(NoirColors.textPrimary)
                    .lineLimit(1)
                Text(vm.taskStep.isEmpty ? vm.taskPhase.label : "\(vm.taskPhase.label) · \(vm.taskStep)")
                    .font(NoirFonts.font(size: 11, weight: .regular))
                    .foregroundStyle(NoirColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if vm.additionalTaskCount > 0 {
                Text("+\(vm.additionalTaskCount)")
                    .font(NoirFonts.font(size: 10, weight: .medium))
                    .foregroundStyle(NoirColors.textSecondary)
                    .help("\(vm.additionalTaskCount) other task(s) in progress")
            }
            if vm.taskIsIndeterminate {
                NotchWorkSpinner()
            } else {
                ZStack {
                    Circle().stroke(NoirColors.glassBorder, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: vm.taskProgress)
                        .stroke(NoirColors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vm.taskName). \(vm.taskPhase.label). \(vm.taskStep)")
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
    var body: some View {
        HStack {
            Text("holmes")
                .font(NoirFonts.brand(size: 22))
                .foregroundStyle(NoirColors.iconPrimary)
            Spacer(minLength: 12)
            Button(action: { MainPanelWindowController.shared.toggle() }) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NoirColors.iconPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(NoirColors.glassSurface))
            }
            .buttonStyle(.plain)
            .help("Open Holmes")
            .accessibilityLabel("Open Holmes")
        }
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
                    .foregroundStyle(NoirColors.textPrimary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(NoirColors.glassSurface))

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.contextLine.isEmpty ? "Watching your screen" : vm.contextLine)
                        .font(NoirFonts.font(size: 14, weight: .medium))
                        .foregroundStyle(NoirColors.textPrimary)
                        .lineLimit(2)
                    Text("Live context")
                        .font(NoirFonts.font(size: 11, weight: .regular))
                        .foregroundStyle(NoirColors.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(NoirColors.glassDivider)

            // What Holmes is DOING (or last did).
            if vm.taskActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: vm.taskPhase.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NoirColors.accent)
                        Text(vm.taskStep.isEmpty ? vm.taskName : vm.taskStep)
                            .font(NoirFonts.font(size: 13, weight: .medium))
                            .foregroundStyle(NoirColors.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    if vm.taskIsIndeterminate {
                        HStack(spacing: 8) {
                            NotchWorkSpinner()
                            Text(vm.taskPhase.label)
                                .font(NoirFonts.font(size: 11, weight: .regular))
                                .foregroundStyle(NoirColors.textSecondary)
                        }
                    } else {
                        ProgressView(value: vm.taskProgress)
                            .progressViewStyle(.linear)
                            .tint(NoirColors.accent)
                    }
                }
            } else if !vm.lastResult.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: vm.lastResultSymbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(vm.lastResultFailed ? Color.orange : NoirColors.success)
                    Text(vm.lastResult)
                        .font(NoirFonts.font(size: 13, weight: .regular))
                        .foregroundStyle(NoirColors.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NoirColors.textSecondary)
                    Text("No task running — Holmes acts when it spots something useful")
                        .font(NoirFonts.font(size: 13, weight: .regular))
                        .foregroundStyle(NoirColors.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// SwiftUI's native macOS spinner can render dark gray on the black island.
/// An explicit stroked arc retains visible contrast in both host/render paths.
private struct NotchWorkSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle().stroke(NoirColors.textPrimary.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0.05, to: 0.76)
                .stroke(NoirColors.textPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
        }
        .frame(width: 18, height: 18)
        .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
        .onAppear { rotating = true }
        .accessibilityHidden(true)
    }
}
