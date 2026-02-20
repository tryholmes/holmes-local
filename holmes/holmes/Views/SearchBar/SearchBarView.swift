import SwiftUI

// MARK: - Glass Appear Transition

struct GlassAppearTransition: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isVisible ? 1.0 : 0.96, anchor: .top)
            .opacity(isVisible ? 1.0 : 0.0)
            .offset(y: isVisible ? 0 : -6)
            .animation(
                .spring(response: 0.4, dampingFraction: 0.85),
                value: isVisible
            )
    }
}

extension View {
    func glassAppear(isVisible: Bool) -> some View {
        modifier(GlassAppearTransition(isVisible: isVisible))
    }
}

// MARK: - SearchBarView

struct SearchBarView: View {
    @State private var viewModel = SearchViewModel()
    @Binding var isVisible: Bool
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        ZStack {
            if !viewModel.showResponse {
                searchInputView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
            }
            
            if viewModel.showResponse {
                responseView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.showResponse)
        .glassAppear(isVisible: isVisible)
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: viewModel.showResponse) { oldValue, newValue in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if newValue {
                    SearchBarWindowController.shared.resize(to: 280, animated: true)
                } else {
                    SearchBarWindowController.shared.resize(to: 140, animated: true)
                }
            }
        }
        .onExitCommand {
            dismissSearchBar()
        }
    }
    
    private var searchInputView: some View {
        VStack(spacing: 16) {
            topBar
            searchField
        }
        .padding(20)
        .frame(width: 900)
        .background(liquidGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
    
    private var responseView: some View {
        VStack(spacing: 0) {
            responseHeader
            responseContent
        }
        .frame(width: 800)
        .background(responseLiquidGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
    
    private var topBar: some View {
        HStack(spacing: 12) {
            Text("holmes")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.95))
            
            Spacer()
            
            TopBarButton(label: "Saved")
            TopBarButton(label: "1,000 credits")
            
            IconButton(systemImage: "message")
            IconButton(systemImage: "plus")
            IconButton(systemImage: "bolt.fill")
            IconButton(systemImage: "gearshape.fill")
        }
    }
    
    private var searchField: some View {
        HStack(spacing: 12) {
            TextField("", text: $viewModel.searchText, prompt: Text("Ask Holmes anything...")
                .foregroundColor(.white.opacity(0.35))
            )
            .focused($isTextFieldFocused)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(.white)
            .textFieldStyle(.plain)
            .onSubmit {
                viewModel.submitSearch()
            }
            
            Button(action: {
                viewModel.submitSearch()
            }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
    
    private var responseHeader: some View {
        HStack(spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    viewModel.goBackToSearch()
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)
                .overlay(
                    Image("HolmesLogo")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .foregroundColor(.white.opacity(0.85))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text("holmes")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                
                Text(viewModel.responseSubtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.leading, 10)
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    private var responseContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !viewModel.responseText.isEmpty {
                Text(viewModel.responseText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.88))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 16) {
                    ActionButton(systemImage: "arrow.clockwise")
                    ActionButton(systemImage: "doc.on.doc")
                    ActionButton(systemImage: "square.and.arrow.up")
                    ActionButton(systemImage: "bookmark")
                    ActionButton(systemImage: "ellipsis")
                    
                    Spacer()
                }
            } else {
                Text("Response will appear here...")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    private var liquidGlassBackground: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3, green: 0.38, blue: 0.38).opacity(0.85),
                            Color(red: 0.25, green: 0.33, blue: 0.33).opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.35, green: 0.43, blue: 0.43).opacity(0.12),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 350
                    )
                )
            
            GrainOverlay(opacity: 0.03)
        }
    }
    
    private var responseLiquidGlassBackground: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3, green: 0.38, blue: 0.38).opacity(0.85),
                            Color(red: 0.25, green: 0.33, blue: 0.33).opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.35, green: 0.43, blue: 0.43).opacity(0.12),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 350
                    )
                )
            
            GrainOverlay(opacity: 0.03)
        }
    }
    
    private func dismissSearchBar() {
        if viewModel.showResponse {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.goBackToSearch()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                viewModel.reset()
                isVisible = false
            }
        } else {
            viewModel.reset()
            isVisible = false
        }
    }
}

struct TopBarButton: View {
    let label: String
    
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
    }
}

struct IconButton: View {
    let systemImage: String
    
    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct ActionButton: View {
    let systemImage: String
    
    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [
                Color(red: 0.1, green: 0.15, blue: 0.25),
                Color(red: 0.15, green: 0.1, blue: 0.2)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        
        SearchBarView(isVisible: .constant(true))
    }
    .frame(width: 1200, height: 400)
}
