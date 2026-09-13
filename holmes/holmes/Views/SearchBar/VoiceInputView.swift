import SwiftUI

struct VoiceInputView: View {
    var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.isListening ? "waveform" : "mic")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(NoirColors.textSecondary)

            Text(viewModel.isListening
                 ? (viewModel.partialTranscript.isEmpty ? "Listening…" : viewModel.partialTranscript)
                 : "Hold Fn to talk")
                .font(NoirFonts.font(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(NoirColors.charcoalDark)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
        }
    }
}

struct AudioWaveform: View {
    let level: CGFloat
    @State private var bars: [CGFloat] = Array(repeating: 0.2, count: 20)
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { index in
                Rectangle()
                    .fill(NoirColors.textSecondary)
                    .frame(width: 4, height: bars[index] * 60)
            }
        }
        .onChange(of: level) { oldLevel, newLevel in
            withAnimation(.easeInOut(duration: 0.1)) {
                for i in 0..<bars.count {
                    let randomVariation = CGFloat.random(in: 0.5...1.5)
                    bars[i] = max(0.1, min(1.0, newLevel * randomVariation))
                }
            }
        }
    }
}

struct ListenButton: View {
    let isListening: Bool
    
    var body: some View {
        HStack(spacing: 6) {
                if isListening {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Listening...")
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .medium))
                    Text("Hold Fn to talk")
                }
            }
            .font(NoirFonts.button())
            .foregroundStyle(isListening ? NoirColors.orangeAccent : NoirColors.creamWhite)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isListening ? NoirColors.orangeAccent.opacity(0.15) : NoirColors.deepTeal)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .pixelBevel(cornerRadius: 6)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        VStack(spacing: 40) {
            VoiceInputView(viewModel: SearchViewModel())
            HStack {
                ListenButton(isListening: false)
                ListenButton(isListening: true)
            }
        }
        .padding()
    }
    .frame(width: 600, height: 400)
}
