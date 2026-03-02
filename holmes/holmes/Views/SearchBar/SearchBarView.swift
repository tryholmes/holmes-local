import SwiftUI

// MARK: - Appear Transition (opacity only — no positional shift)

struct BarAppearTransition: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.easeOut(duration: 0.22), value: isVisible)
    }
}

extension View {
    func barAppear(isVisible: Bool) -> some View {
        modifier(BarAppearTransition(isVisible: isVisible))
    }
    // Keep old name so existing call sites compile
    func glassAppear(isVisible: Bool) -> some View {
        barAppear(isVisible: isVisible)
    }
}

// MARK: - SearchBarView

struct SearchBarView: View {
    @State private var viewModel = SearchViewModel()
    @Binding var isVisible: Bool
    @FocusState private var isTextFieldFocused: Bool

    // Both views share the same fixed frame so no layout shift occurs.
    private let panelWidth: CGFloat  = 900
    private let inputHeight: CGFloat = 130
    private let responseHeight: CGFloat = 260

    var body: some View {
        // Single ZStack with a fixed frame — both layers sit in the same space.
        ZStack(alignment: .top) {
            searchInputView
                .opacity(viewModel.showResponse ? 0 : 1)

            responseView
                .opacity(viewModel.showResponse ? 1 : 0)
        }
        .frame(width: panelWidth)
        .animation(.easeInOut(duration: 0.22), value: viewModel.showResponse)
        .barAppear(isVisible: isVisible)
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: viewModel.showResponse) { _, newValue in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                SearchBarWindowController.shared.resize(
                    to: newValue ? responseHeight : inputHeight,
                    animated: true
                )
            }
        }
        .onExitCommand { dismissSearchBar() }
        .onReceive(NotificationCenter.default.publisher(for: .searchBarWillHide)) { _ in
            viewModel.reset()
            isVisible = false
        }
    }

    // MARK: Search Input

    private var searchInputView: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .background(NoirColors.deepTeal)

            searchField
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(NoirColors.skyBlue)
        }
        .frame(width: panelWidth, height: inputHeight, alignment: .top)
        .background(NoirColors.skyBlue)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(cornerRadius: 6)
        .shadow(color: NoirColors.charcoalDark.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    // MARK: Response View

    private var responseView: some View {
        VStack(spacing: 0) {
            responseHeader

            Divider()
                .background(NoirColors.charcoalDark.opacity(0.12))

            responseContent
        }
        .frame(width: panelWidth, height: responseHeight, alignment: .top)
        .background(NoirColors.warmWhite)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(cornerRadius: 6)
        .shadow(color: NoirColors.charcoalDark.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    // MARK: Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("HOLMES")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.creamWhite)
                .tracking(3)

            Spacer()

            TopBarButton(label: "Saved")
            TopBarButton(label: "1,000 credits")

            IconButton(systemImage: "message")
            IconButton(systemImage: "plus")
            IconButton(systemImage: "bolt.fill")
            IconButton(systemImage: "gearshape.fill")
        }
    }

    // MARK: Search Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.iconSecondary)

            TextField("", text: $viewModel.searchText, prompt:
                Text("Ask Holmes anything...")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(NoirColors.textPlaceholder)
            )
            .focused($isTextFieldFocused)
            .font(.system(size: 14, weight: .regular, design: .monospaced))
            .foregroundColor(NoirColors.charcoalDark)
            .textFieldStyle(.plain)
            .onSubmit { viewModel.submitSearch() }

            Button(action: { viewModel.submitSearch() }) {
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.creamWhite)
                    .frame(width: 32, height: 28)
                    .background(NoirColors.deepTeal)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .pixelBevel(cornerRadius: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(NoirColors.lightBlue.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(raised: false, cornerRadius: 6)
    }

    // MARK: Response Header

    private var responseHeader: some View {
        HStack(spacing: 10) {
            Button(action: {
                viewModel.goBackToSearch()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text("Back")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(NoirColors.creamWhite)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(NoirColors.deepTeal)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 2)
                .fill(NoirColors.charcoalDark.opacity(0.2))
                .frame(width: 1, height: 20)

            Image("HolmesLogo")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .foregroundColor(NoirColors.deepTeal)

            VStack(alignment: .leading, spacing: 1) {
                Text("Holmes")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.charcoalDark)

                Text(viewModel.responseSubtitle.isEmpty ? "Ready" : viewModel.responseSubtitle)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(NoirColors.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(NoirColors.skyBlue)
    }

    // MARK: Response Content

    private var responseContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.responseText.isEmpty {
                Text(viewModel.responseText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(NoirColors.charcoalDark)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    ActionButton(systemImage: "arrow.clockwise")
                    ActionButton(systemImage: "doc.on.doc")
                    ActionButton(systemImage: "square.and.arrow.up")
                    ActionButton(systemImage: "bookmark")
                    ActionButton(systemImage: "ellipsis")
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.iconSecondary)
                    Text("Processing...")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(NoirColors.iconSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Dismiss

    private func dismissSearchBar() {
        if viewModel.showResponse {
            viewModel.goBackToSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                viewModel.reset()
                isVisible = false
            }
        } else {
            viewModel.reset()
            isVisible = false
        }
    }
}

// MARK: - Sub-Components

struct TopBarButton: View {
    let label: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.deepTeal : NoirColors.creamWhite)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minWidth: 44, minHeight: 28)
                .background(isHovered ? NoirColors.creamWhite : NoirColors.midBlue.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NoirColors.goldAccent, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

struct IconButton: View {
    let systemImage: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.deepTeal : NoirColors.creamWhite)
                .frame(width: 32, height: 30)
                .background(isHovered ? NoirColors.creamWhite : NoirColors.midBlue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NoirColors.goldAccent, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .frame(minWidth: 44, minHeight: 44)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

struct ActionButton: View {
    let systemImage: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.creamWhite : NoirColors.iconPrimary)
                .frame(width: 32, height: 30)
                .background(isHovered ? NoirColors.deepTeal : NoirColors.lightBlue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NoirColors.goldAccent, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .frame(minWidth: 44, minHeight: 44)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

#Preview {
    ZStack {
        NoirColors.deepTeal.opacity(0.3).ignoresSafeArea()
        SearchBarView(isVisible: .constant(true))
    }
    .frame(width: 1100, height: 400)
}
