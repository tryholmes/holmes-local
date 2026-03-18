import SwiftUI

// MARK: - Appear modifier

struct BarAppearTransition: ViewModifier {
    let isVisible: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.easeOut(duration: 0.2), value: isVisible)
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
            .fill(Color(hex: "B8881C"))
            .frame(width: 9, height: 17)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    visible.toggle()
                }
            }
    }
}

// MARK: - Dimensions (single source of truth)

private enum BarDimensions {
    static let width: CGFloat        = 860
    static let inputHeight: CGFloat  = 120
    static let outputHeight: CGFloat = 460  // input + output panel
}

// MARK: - SearchBarView (Command Bar)

struct SearchBarView: View {
    @State private var vm = CommandViewModel()
    @Binding var isVisible: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputPanel
            if vm.showOutput {
                outputPanel
                    .transition(.asymmetric(
                        insertion: .push(from: .bottom).combined(with: .opacity),
                        removal: .push(from: .top).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: BarDimensions.width)
        .background(Color(hex: "111820"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "2A3D4A"), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
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
            // Small delay so the window is fully visible before auto-executing
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
                // Holmes logo + name
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "B8881C"))
                    Text("HOLMES")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "E8D5A3"))
                        .tracking(3)
                }

                Spacer()

                // Status pill
                statusPill

                // Quick action icons
                chromeIcons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: "0D1318"))

            Divider().background(Color(hex: "1E2D38"))

            // Command input row
            HStack(spacing: 0) {
                // Prompt symbol
                Text("❯")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "B8881C"))
                    .padding(.leading, 16)
                    .padding(.trailing, 10)

                // Active command badge
                if let cmd = vm.matchedCommand {
                    commandBadge(cmd)
                        .padding(.trailing, 8)
                }

                // Text input + blinking cursor overlay
                ZStack(alignment: .leading) {
                    if vm.inputText.isEmpty {
                        HStack(spacing: 0) {
                            BlinkingCursor()
                            Text(placeholderText)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(hex: "3D5A6A"))
                                .padding(.leading, 4)
                        }
                    }
                    TextField("", text: Binding(
                        get: { vm.inputText },
                        set: { vm.onInputChange($0) }
                    ))
                    .focused($focused)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(hex: "E8D5A3"))
                    .textFieldStyle(.plain)
                    .onSubmit { vm.submit() }
                }

                Spacer()

                // Return key hint
                if !vm.inputText.isEmpty {
                    Text("↵")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "3D5A6A"))
                        .padding(.trailing, 14)
                }
            }
            .frame(height: 52)
            .background(Color(hex: "111820"))

            // Slash command autocomplete
            if !vm.suggestions.isEmpty {
                commandSuggestions
            }
        }
        .frame(width: BarDimensions.width, height: BarDimensions.inputHeight, alignment: .top)
    }

    // MARK: Output panel

    private var outputPanel: some View {
        VStack(spacing: 0) {
            Divider().background(Color(hex: "1E2D38"))

            // Output header
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .fill(stateColor)
                            .frame(width: 7, height: 7)
                            .opacity(vm.state == .running ? 0.4 : 0)
                            .scaleEffect(vm.state == .running ? 2 : 1)
                            .animation(.easeOut(duration: 0.8).repeatForever(autoreverses: false), value: vm.state == .running)
                    )

                Text(outputHeaderText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "5A7A8A"))
                    .tracking(2)

                Spacer()

                Button(action: { vm.reset() }) {
                    Text("✕  NEW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "3D5A6A"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: "0D1318"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { h in }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(hex: "0D1318"))

            // Log lines
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.log) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.prefix)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(line.color)
                                    .frame(width: 14, alignment: .center)
                                Text(line.text)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundColor(Color(hex: "BDD0D8"))
                                    .lineSpacing(2)
                                Spacer()
                            }
                            .id(line.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if vm.state == .running {
                            HStack(spacing: 6) {
                                BlinkingCursor()
                                    .frame(width: 6, height: 12)
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
        .background(Color(hex: "0A0F14"))
    }

    // MARK: Command badge

    private func commandBadge(_ cmd: HolmesCommand) -> some View {
        HStack(spacing: 5) {
            Image(systemName: cmd.icon)
                .font(.system(size: 10, weight: .bold))
            Text(cmd.trigger)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(Color(hex: "111820"))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: "B8881C"))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Slash command suggestions

    private var commandSuggestions: some View {
        VStack(spacing: 0) {
            Divider().background(Color(hex: "1E2D38"))
            VStack(spacing: 0) {
                ForEach(vm.suggestions) { cmd in
                    Button(action: { vm.selectCommand(cmd) }) {
                        HStack(spacing: 12) {
                            Image(systemName: cmd.icon)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "B8881C"))
                                .frame(width: 16)
                            Text(cmd.trigger)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "E8D5A3"))
                            Text(cmd.description)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(hex: "5A7A8A"))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color(hex: "0D1318"))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if cmd.id != vm.suggestions.last?.id {
                        Divider().background(Color(hex: "1A2730")).padding(.leading, 44)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeOut(duration: 0.12), value: vm.suggestions.count)
    }

    // MARK: Chrome icons

    private var chromeIcons: some View {
        HStack(spacing: 6) {
            ForEach([
                ("clock.arrow.circlepath", "History"),
                ("gearshape.fill", "Settings")
            ], id: \.0) { icon, tip in
                Button(action: {}) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "3D5A6A"))
                        .frame(width: 28, height: 26)
                        .background(Color(hex: "0D1318"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
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
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "5A7A8A"))
                .tracking(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: "0D1318"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        case .idle:    return Color(hex: "3D5A6A")
        case .typing:  return Color(hex: "B8881C")
        case .running: return Color(hex: "5DBB7A")
        case .done:    return Color(hex: "5DBB7A")
        case .error:   return Color(hex: "E05252")
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.deepTeal : NoirColors.creamWhite)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(minWidth: 44, minHeight: 28)
                .background(isHovered ? NoirColors.creamWhite : NoirColors.midBlue.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
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
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.deepTeal : NoirColors.creamWhite)
                .frame(width: 32, height: 30)
                .background(isHovered ? NoirColors.creamWhite : NoirColors.midBlue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
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
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.creamWhite : NoirColors.iconPrimary)
                .frame(width: 32, height: 30)
                .background(isHovered ? NoirColors.deepTeal : NoirColors.lightBlue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

#Preview {
    ZStack {
        Color(hex: "0A0F14").ignoresSafeArea()
        SearchBarView(isVisible: .constant(true))
    }
    .frame(width: 960, height: 400)
}
