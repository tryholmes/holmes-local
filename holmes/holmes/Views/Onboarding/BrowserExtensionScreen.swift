import SwiftUI

// MARK: - "Connect your browser" step
// Sits after the local model. Holmes reads pages exactly through its browser
// extension; without it the browser falls back to the Accessibility tree and
// OCR. This step installs the bundled extension into the user's Chromium
// browser and pairs it with the bridge, showing live status as it happens.

@MainActor
struct BrowserExtensionScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var contentOpacity: CGFloat = 0
    @State private var browsers: [ExtensionInstaller.Browser] = []
    @State private var chosen: ExtensionInstaller.Browser?
    @State private var started = false
    @State private var errorText: String?

    private var bridge: BrowserBridge { BrowserBridge.shared }
    private var isPaired: Bool { bridge.pairedToken != nil }
    private var isConnected: Bool { bridge.isExtensionConnected }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Connect Your Browser")
                        .font(NoirFonts.headline())
                        .foregroundColor(NoirColors.textPrimary)
                    Text("The Holmes extension gives it an exact read of the page you\nare on, instead of guessing from pixels. It talks only to this Mac.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                statusCard

                if browsers.isEmpty {
                    Text("No Chromium browser found. Chrome, Arc, Brave, Edge, Comet, Vivaldi and Opera are supported. You can do this later from Settings ▸ Privacy.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                } else if !started {
                    VStack(spacing: 10) {
                        Text("Install in")
                            .font(NoirFonts.caption())
                            .foregroundColor(NoirColors.textSecondary)
                        HStack(spacing: 10) {
                            ForEach(browsers.prefix(4)) { b in
                                NoirButton(b.name, icon: "puzzlepiece.extension", style: b.id == browsers.first?.id ? .primary : .secondary) {
                                    begin(b)
                                }
                            }
                        }
                        if browsers.count > 4 {
                            Menu("More browsers…") {
                                ForEach(browsers.dropFirst(4)) { b in
                                    Button(b.name) { begin(b) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 140)
                        }
                    }
                } else {
                    instructions
                }

                if let errorText {
                    Text(errorText)
                        .font(NoirFonts.caption())
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            .opacity(contentOpacity)

            Spacer()

            HStack(spacing: 16) {
                NoirButton("Back", style: .ghost) { viewModel.previousStep() }
                if isPaired {
                    NoirButton("Continue", icon: "arrow.right") { viewModel.nextStep() }
                } else {
                    NoirButton("Skip for now", icon: "arrow.right", style: .secondary) { viewModel.nextStep() }
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            browsers = ExtensionInstaller.installedBrowsers()
            bridge.start()
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) { contentOpacity = 1.0 }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isConnected ? Color.green : (isPaired ? Color.yellow : (bridge.isPairing ? NoirColors.accent : NoirColors.glassStroke)))
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(NoirFonts.caption())
                .foregroundColor(NoirColors.textPrimary)
            if bridge.isPairing && !isPaired {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NoirColors.glassStroke, lineWidth: 1))
    }

    private var statusText: String {
        if isConnected { return "Extension connected and reading pages." }
        if isPaired { return "Paired. Waiting for the browser to post its first page." }
        if bridge.isPairing { return "Waiting for the extension… (pairing window open)" }
        return "Not connected yet."
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In \(chosen?.name ?? "your browser"):")
                .font(NoirFonts.caption())
                .foregroundColor(NoirColors.textSecondary)
            step(1, "Turn on **Developer mode** (top right of the Extensions page).")
            step(2, "Press **Load unpacked** and choose the folder Holmes just opened in Finder.")
            step(3, "Click the Holmes puzzle icon and press **Pair with Holmes**.")
            HStack(spacing: 10) {
                Button("Open Extensions page again") { if let c = chosen { ExtensionInstaller.openExtensionsPage(in: c) } }
                Button("Show folder") { ExtensionInstaller.revealInstalledFolder() }
                if !bridge.isPairing && !isPaired {
                    Button("Re-open pairing window") { bridge.beginPairing() }
                }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.accent)
                .frame(width: 16)
            Text(.init(text))
                .font(NoirFonts.caption())
                .foregroundColor(NoirColors.textPrimary)
        }
    }

    private func begin(_ browser: ExtensionInstaller.Browser) {
        errorText = nil
        chosen = browser
        do {
            try ExtensionInstaller.beginGuidedInstall(in: browser)
            started = true
        } catch {
            errorText = error.localizedDescription
        }
    }
}
