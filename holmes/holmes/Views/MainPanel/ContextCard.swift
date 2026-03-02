import SwiftUI

struct ContextCard: View {
    let context: DetectedContext
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: context.icon)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.deepTeal)

                Text("CONTEXT DETECTED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.deepTeal)
                    .tracking(1)
            }

            Text(context.description)
                .font(NoirFonts.body())
                .foregroundColor(NoirColors.charcoalDark)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoirColors.creamWhite)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(cornerRadius: 6)
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
