import SwiftUI

// MARK: - Appear modifier

struct BarAppearTransition: ViewModifier {
    let isVisible: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1.0 : 0.0)
            .scaleEffect(isVisible ? 1.0 : 0.97)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isVisible)
    }
}

extension View {
    func barAppear(isVisible: Bool) -> some View { modifier(BarAppearTransition(isVisible: isVisible)) }
    func glassAppear(isVisible: Bool) -> some View { barAppear(isVisible: isVisible) }
}

// MARK: - Blinking cursor

struct BlinkingCursor: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.75))
            .frame(width: 2, height: 16)
            .cornerRadius(1)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.52).repeatForever()) {
                    visible.toggle()
                }
            }
    }
}

// MARK: - Dimensions (single source of truth)

private enum BarDimensions {
    static let width: CGFloat        = 860
    static let inputHeight: CGFloat  = 120
    static let outputHeight: CGFloat = 460
}

// MARK: - SearchBarView (Command Bar)

struct SearchBarView: View {
    @State private var vm = CommandViewModel()
    @Binding var isVisible: Bool
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Apple glass base — blur + tint
            AppleGlassBackground(cornerRadius: 18)

            VStack(spacing: 0) {
                inputPanel
                if vm.showOutput {
                    outputPanel
                        .transition(.asymmetric(
                            insertion: .push(from: .bottom).combined(with: .opacity),
                            removal:   .push(from: .top).combined(with: .opacity)
                        ))
                }
            }
        }
        .frame(width: BarDimensions.width)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(NoirColors.glassStroke, lineWidth: 0.75)
        )
        .overlay(
            // Inner shimmer ring
            RoundedRectangle(cornerRadius: 17.5)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.clear, Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
                .padding(0.5)
        )
        .shadow(color: NoirColors.panelShadow, radius: 36, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: vm.showOutput)
        .barAppear(isVisible: isVisible)
        .onAppear { focused = true }
        .onChange(of: vm.showOutput) { _, show in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                SearchBarWindowController.shared.resize(
                    to: show ? BarDimensions.outputHeight : BarDimensions.inputHeight,
                    animated: true
                )
            }
        }
        .onExitCommand { dismiss() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                vm.checkPendingCommand()
            }
        }
    }

    // MARK: Input panel

    private var inputPanel: some View {
        VStack(spacing: 0) {
            // Top chrome bar
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NoirColors.goldAccent)
                    Text("HOLMES")
                        .font(NoirFonts.font(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.textPrimary)
                        .tracking(3)
                }

                Spacer()

                statusPill
                chromeIcons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(NoirColors.glassChrome)

            Divider()
                .background(NoirColors.glassDivider)

            // Command input row
            HStack(spacing: 0) {
                Text("❯")
                    .font(NoirFonts.font(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .padding(.leading, 16)
                    .padding(.trailing, 10)

                if let cmd = vm.matchedCommand {
                    commandBadge(cmd)
                        .padding(.trailing, 8)
                }

                ZStack(alignment: .leading) {
                    if vm.inputText.isEmpty {
                        HStack(spacing: 0) {
                            BlinkingCursor()
                            Text(placeholderText)
                                .font(NoirFonts.font(size: 14, weight: .regular, design: .monospaced))
                                .foregroundColor(NoirColors.textPlaceholder)
                                .padding(.leading, 6)
                        }
                    }
                    TextField("", text: Binding(
                        get: { vm.inputText },
                        set: { vm.onInputChange($0) }
                    ))
                    .focused($focused)
                    .font(NoirFonts.font(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(NoirColors.textPrimary)
                    .textFieldStyle(.plain)
                    .onSubmit { vm.submit() }
                }

                Spacer()

                if !vm.inputText.isEmpty {
                    Text("↵")
                        .font(NoirFonts.font(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(NoirColors.textTertiary)
                        .padding(.trailing, 14)
                }
            }
            .frame(height: 52)
            .background(Color.clear)

            if !vm.suggestions.isEmpty {
                commandSuggestions
            }
        }
        .frame(width: BarDimensions.width, height: BarDimensions.inputHeight, alignment: .top)
    }

    // MARK: Output panel

    private var outputPanel: some View {
        VStack(spacing: 0) {
            Divider().background(NoirColors.glassDivider)

            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .fill(stateColor)
                            .frame(width: 6, height: 6)
                            .opacity(vm.state == .running ? 0.35 : 0)
                            .scaleEffect(vm.state == .running ? 2.2 : 1)
                            .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false), value: vm.state == .running)
                    )

                Text(outputHeaderText)
                    .font(NoirFonts.font(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                    .tracking(2)

                Spacer()

                Button(action: { vm.reset() }) {
                    Text("✕  NEW")
                        .font(NoirFonts.font(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(NoirColors.glassChrome)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .glassBorder(cornerRadius: 5, lineWidth: 0.6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(NoirColors.glassChrome)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.log) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.prefix)
                                    .font(NoirFonts.font(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(line.color)
                                    .frame(width: 14, alignment: .center)
                                Text(line.text)
                                    .font(NoirFonts.font(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundColor(NoirColors.textSecondary)
                                    .lineSpacing(2)
                                Spacer()
                            }
                            .id(line.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if vm.state == .running {
                            HStack(spacing: 6) {
                                BlinkingCursor()
                                    .frame(width: 2, height: 12)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .animation(.easeOut(duration: 0.15), value: vm.log.count)
                }
                .onChange(of: vm.log.count) { _, _ in
                    if let last = vm.log.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(width: BarDimensions.width, height: BarDimensions.outputHeight - BarDimensions.inputHeight)
    }

    // MARK: Command badge

    private func commandBadge(_ cmd: HolmesCommand) -> some View {
        HStack(spacing: 5) {
            Image(systemName: cmd.icon)
                .font(.system(size: 10, weight: .bold))
            Text(cmd.trigger)
                .font(NoirFonts.font(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(Color.white.opacity(0.90))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: "0E0E0E").opacity(0.80))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .glassBorder(cornerRadius: 5, lineWidth: 0.6)
    }

    // MARK: Slash command suggestions

    private var commandSuggestions: some View {
        VStack(spacing: 0) {
            Divider().background(NoirColors.glassDivider)
            VStack(spacing: 0) {
                ForEach(vm.suggestions) { cmd in
                    Button(action: { vm.selectCommand(cmd) }) {
                        HStack(spacing: 12) {
                            Image(systemName: cmd.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(NoirColors.goldAccent)
                                .frame(width: 16)
                            Text(cmd.trigger)
                                .font(NoirFonts.font(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(NoirColors.textPrimary)
                            Text(cmd.description)
                                .font(NoirFonts.font(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(NoirColors.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.04))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if cmd.id != vm.suggestions.last?.id {
                        Divider()
                            .background(NoirColors.glassDivider)
                            .padding(.leading, 44)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeOut(duration: 0.12), value: vm.suggestions.count)
    }

    // MARK: Chrome icons

    private var chromeIcons: some View {
        HStack(spacing: 5) {
            ForEach([
                ("clock.arrow.circlepath", "History"),
                ("gearshape.fill", "Settings")
            ], id: \.0) { icon, tip in
                Button(action: {}) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NoirColors.iconSecondary)
                        .frame(width: 28, height: 26)
                        .background(NoirColors.glassChrome)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .glassBorder(cornerRadius: 6, lineWidth: 0.6)
                }
                .buttonStyle(.plain)
                .help(tip)
            }
        }
    }

    // MARK: Status pill

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(stateColor).frame(width: 5, height: 5)
            Text(stateLabel)
                .font(NoirFonts.font(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.textTertiary)
                .tracking(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(NoirColors.glassChrome)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .glassBorder(cornerRadius: 10, lineWidth: 0.55)
    }

    // MARK: Helpers

    private var placeholderText: String {
        "Type a command or / for slash commands..."
    }

    private var stateLabel: String {
        switch vm.state {
        case .idle:    return "READY"
        case .typing:  return "TYPING"
        case .running: return "RUNNING"
        case .done:    return "DONE"
        case .error:   return "ERROR"
        }
    }

    private var stateColor: Color {
        switch vm.state {
        case .idle:    return NoirColors.textTertiary
        case .typing:  return NoirColors.goldAccent
        case .running: return NoirColors.success
        case .done:    return NoirColors.success
        case .error:   return NoirColors.error
        }
    }

    private var outputHeaderText: String {
        switch vm.state {
        case .running: return "EXECUTING"
        case .done:    return "COMPLETE"
        case .error:   return "ERROR"
        default:       return "OUTPUT"
        }
    }

    // MARK: Dismiss

    private func dismiss() {
        vm.reset()
        isVisible = false
    }
}

// MARK: - Sub-components kept for MainPanel compatibility

struct TopBarButton: View {
    let label: String
    @State private var isHovered = false
    var body: some View {
        Button(action: {}) {
            Text(label)
                .font(NoirFonts.font(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.goldAccent : NoirColors.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(minWidth: 44, minHeight: 28)
                .background(isHovered ? NoirColors.glassElevated : NoirColors.glassSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .glassBorder(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

struct IconButton: View {
    let systemImage: String
    @State private var isHovered = false
    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isHovered ? NoirColors.goldAccent : NoirColors.textPrimary)
                .frame(width: 32, height: 30)
                .background(isHovered ? NoirColors.glassElevated : NoirColors.glassSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .glassBorder(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

struct ActionButton: View {
    let systemImage: String
    @State private var isHovered = false
    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? NoirColors.textPrimary : NoirColors.iconPrimary)
                .frame(width: 32, height: 30)
                .background(isHovered ? NoirColors.goldAccent : NoirColors.glassSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .glassBorder(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        SearchBarView(isVisible: .constant(true))
    }
    .frame(width: 960, height: 400)
}
