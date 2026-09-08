import SwiftUI

// MARK: - "Connect your tools" step
// Optional. Composio is the one connection that gives Holmes's playbooks read
// access to Gmail, Calendar, GitHub and the rest, with OAuth handled on
// Composio's side. This step writes the entry to mcp.json, restarts the MCP
// host, and shows how many tools came back. Everything stays draft only: the
// same tool filter applies to Composio tools as to every other server.

@MainActor
struct IntegrationsScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var contentOpacity: CGFloat = 0
    @State private var url: String = MCPConfigWriter.composioEntry?.url ?? ""
    @State private var apiKey: String = MCPConfigWriter.composioEntry?.apiKey ?? ""
    @State private var isConnecting = false
    @State private var resultText: String?
    @State private var resultIsError = false

    private var connectedToolCount: Int {
        MCPClient.shared.tools.filter { $0.serverName.lowercased() == MCPConfigWriter.composioName }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Connect Your Tools")
                        .font(NoirFonts.headline())
                        .foregroundColor(NoirColors.textPrimary)
                    Text("Optional. One Composio connection lets Holmes read your Gmail,\nCalendar and GitHub to ground its drafts. It can never send from them.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                VStack(alignment: .leading, spacing: 10) {
                    field("Composio MCP URL", text: $url, placeholder: "https://backend.composio.dev/v3/mcp/…?user_id=…", secure: false)
                    field("Composio API key", text: $apiKey, placeholder: "x-api-key (optional for some servers)", secure: true)

                    HStack(spacing: 10) {
                        Button("Open Composio dashboard") {
                            if let u = URL(string: "https://dashboard.composio.dev") { NSWorkspace.shared.open(u) }
                        }
                        Spacer()
                        if isConnecting {
                            ProgressView().controlSize(.small)
                        }
                        Button(connectedToolCount > 0 ? "Reconnect" : "Connect") { connect() }
                            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)

                    if let resultText {
                        Text(resultText)
                            .font(NoirFonts.caption())
                            .foregroundColor(resultIsError ? .orange : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if connectedToolCount > 0 {
                        Text("Connected: \(connectedToolCount) tools available.")
                            .font(NoirFonts.caption())
                            .foregroundColor(.green)
                    }

                    Text("You can also add any MCP server later in ~/Library/Application Support/Holmes/mcp.json or with the holmes-sdk CLI.")
                        .font(.system(size: 10))
                        .foregroundColor(NoirColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: 480)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(NoirColors.glassStroke, lineWidth: 1))
            }
            .opacity(contentOpacity)

            Spacer()

            HStack(spacing: 16) {
                NoirButton("Back", style: .ghost) { viewModel.previousStep() }
                if connectedToolCount > 0 {
                    NoirButton("Continue", icon: "arrow.right") { viewModel.nextStep() }
                } else {
                    NoirButton("Skip for now", icon: "arrow.right", style: .secondary) { viewModel.nextStep() }
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) { contentOpacity = 1.0 }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NoirColors.textSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private func connect() {
        resultText = nil
        isConnecting = true
        Task { @MainActor in
            defer { isConnecting = false }
            do {
                try MCPConfigWriter.setComposio(url: url, apiKey: apiKey)
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
                return
            }
            await MCPClient.shared.restart()
            let n = connectedToolCount
            if n > 0 {
                resultIsError = false
                resultText = "Connected: \(n) tools available. Holmes can now ground drafts in your connected apps."
            } else {
                resultIsError = true
                resultText = "Saved, but no tools came back. Check the URL and API key, and that at least one toolkit is connected in the Composio dashboard. Log: \(MCPClient.shared.status)"
            }
        }
    }
}
