import SwiftUI

struct NoirTextField: View {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    @FocusState private var isFocused: Bool
    
    init(_ placeholder: String, text: Binding<String>, fontSize: CGFloat = 48) {
        self.placeholder = placeholder
        self._text = text
        self.fontSize = fontSize
    }
    
    var body: some View {
        ZStack {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textPlaceholder)
            }

            TextField("", text: $text)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.charcoalDark)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .focused($isFocused)
        }
        .onAppear { isFocused = true }
    }
}

// MARK: - Form Field (for login/settings — small, left-aligned, with optional secure input)

struct NoirFormField: View {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    @FocusState private var isFocused: Bool

    init(_ placeholder: String, text: Binding<String>, isSecure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
    }

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(NoirFonts.body())
        .foregroundStyle(NoirColors.charcoalDark)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isFocused ? NoirColors.lightBlue.opacity(0.4) : NoirColors.creamWhite)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(raised: false, cornerRadius: 6)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

struct NoirSearchField: View {
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.iconSecondary)

            TextField(placeholder, text: $text)
                .font(NoirFonts.body())
                .foregroundColor(NoirColors.charcoalDark)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.deepTeal)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NoirColors.creamWhite)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(raised: false, cornerRadius: 6)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        VStack(spacing: 24) {
            NoirTextField("Holmes", text: .constant(""))
            NoirSearchField(text: .constant(""), placeholder: "Search...")
        }
        .padding(40)
    }
    .frame(width: 600, height: 300)
}
