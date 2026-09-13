import SwiftUI

struct OnboardingFlow: View {
    @StateObject private var viewModel = OnboardingViewModel()
    // The brand intro plays once before Welcome; Reduce Motion skips it.
    @State private var showLaunchIntro = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let onComplete: () -> Void
    
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    
                    if viewModel.currentStep != .welcome {
                        StepIndicator(
                            currentStep: viewModel.currentStep.rawValue,
                            totalSteps: OnboardingStep.allCases.count
                        )
                    }
                    
                    Spacer()
                }
                .padding(.top, 40)
                .padding(.horizontal, 40)
                
                Group {
                    switch viewModel.currentStep {
                    case .welcome:
                        // Held back until the intro ends so its entrance animation plays.
                        if !showLaunchIntro {
                            WelcomeScreen(viewModel: viewModel)
                        }
                    case .howItWorks:
                        HowItWorksScreen(viewModel: viewModel)
                    case .permissions:
                        PermissionsScreen(viewModel: viewModel)
                    case .localModel:
                        LocalModelScreen(viewModel: viewModel)
                    case .browser:
                        BrowserExtensionScreen(viewModel: viewModel)
                    case .integrations:
                        IntegrationsScreen(viewModel: viewModel)
                    case .ready:
                        ReadyScreen(viewModel: viewModel, onComplete: onComplete)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .overlay {
            if showLaunchIntro {
                LaunchIntroView(onFinish: finishLaunchIntro)
                    .overlay {
                        // Click anywhere to skip.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: finishLaunchIntro)
                    }
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: 600, minHeight: 700)
        // The whole palette is white-on-glass; pin the window to the dark
        // appearance so the .hudWindow material stays dark under a light
        // system appearance / light wallpaper instead of washing the text out.
        .preferredColorScheme(.dark)
    }

    private func finishLaunchIntro() {
        showLaunchIntro = false
    }
}

// MARK: - "Your local model" step
// Sits between Permissions and Ready. Embeds the compact Local Model pane
// (status + the one model Holmes will use, with download progress) so the user
// ends onboarding with Ollama running and the default model pulled. Continue
// is offered once everything is ready; "Set up later" always lets them through —
// Settings ▸ Local Model shows the same controls, and every "can't act" message
// points there.
@MainActor
struct LocalModelScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var contentOpacity: CGFloat = 0

    private var isReady: Bool { OllamaServer.shared.status.isReady }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Your Local Model")
                        .font(NoirFonts.headline())
                        .foregroundColor(NoirColors.textPrimary)

                    Text("Holmes thinks with an open model that runs on this Mac\nthrough Ollama. Nothing you do is sent to a server.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                LocalModelSettingsView(compact: true)
            }
            .opacity(contentOpacity)

            Spacer()

            HStack(spacing: 16) {
                NoirButton("Back", style: .ghost) {
                    viewModel.previousStep()
                }

                if isReady {
                    NoirButton("Continue", icon: "arrow.right") {
                        viewModel.nextStep()
                    }
                } else {
                    NoirButton("Set up later", icon: "arrow.right", style: .secondary) {
                        viewModel.nextStep()
                    }
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                contentOpacity = 1.0
            }
            // The launch-time monitor is already probing; nudge it so the card
            // reflects "now" (and spawns the server if it's down and allowed).
            Task { await OllamaServer.shared.ensureRunning() }
        }
    }
}

struct StepIndicator: View {
    let currentStep: Int
    let totalSteps: Int
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule()
                    .fill(index <= currentStep ? NoirColors.accent : NoirColors.glassStroke)
                    .frame(width: index == currentStep ? 24 : 8, height: 8)
                    .animation(NoirAnimations.smooth, value: currentStep)
            }
        }
    }
}

#Preview {
    OnboardingFlow {}
}
