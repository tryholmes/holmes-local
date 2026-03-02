import SwiftUI

struct ContextCard: View {
    let context: DetectedContext
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: context.icon)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "B8881C"))
                Text("CONTEXT DETECTED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "5A7A8A"))
                    .tracking(2)
            }
            Text(context.description)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "BDD0D8"))
                .lineLimit(2)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "111820"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "1E2D38"), lineWidth: 1))
    }
}

struct DetectedContext {
    let icon: String
    let description: String
    let appName: String
    
    static let placeholder = DetectedContext(
        icon: "doc.text",
        description: "Working on \"Project Proposal.docx\" in Microsoft Word",
        appName: "Microsoft Word"
    )
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        ContextCard(context: .placeholder).padding()
    }
    .frame(width: 400, height: 200)
}
