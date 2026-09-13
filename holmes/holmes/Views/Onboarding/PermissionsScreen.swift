import SwiftUI

struct PermissionsScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var cardsOpacity: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                Text("Permissions Needed")
                    .font(NoirFonts.headline())
                    .foregroundColor(NoirColors.charcoalDark)
                
                VStack(spacing: 16) {
                    PermissionCard(
                        icon: "rectangle.dashed.badge.record",
                        title: "Screen Recording",
                        description: "To understand what you're working on and provide contextual help",
                        isGranted: viewModel.hasScreenRecordingPermission,
                        action: viewModel.openScreenRecordingSettings
                    )
                    
                    PermissionCard(
                        icon: "accessibility",
                        title: "Accessibility",
                        description: "To interact with apps on your behalf (clicking, typing, etc)",
                        isGranted: viewModel.hasAccessibilityPermission,
                        action: viewModel.requestAccessibilityPermission
                    )
                    
                    PermissionCard(
                        icon: "gearshape.2.fill",
                        title: "Automation",
                        description: "To execute tasks across multiple applications automatically",
                        isGranted: viewModel.hasAutomationPermission,
                        action: viewModel.openAutomationSettings
                    )
                }
                .opacity(cardsOpacity)
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                NoirButton("Back", style: .ghost) {
                    viewModel.previousStep()
                }
                
                NoirButton(
                    viewModel.allPermissionsGranted ? "Continue" : "Grant Permissions",
                    icon: viewModel.allPermissionsGranted ? "arrow.right" : "lock.open.fill"
                ) {
                    if viewModel.allPermissionsGranted {
                        viewModel.nextStep()
                    } else {
                        if !viewModel.hasAccessibilityPermission {
                            viewModel.requestAccessibilityPermission()
                        } else if !viewModel.hasScreenRecordingPermission {
                            viewModel.openScreenRecordingSettings()
                        }
                    }
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.checkPermissions() }
        }
        .task {
            while !Task.isCancelled {
                viewModel.checkPermissions()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        .onAppear {
            viewModel.checkPermissions()
            withAnimation(.easeOut(duration: 0.5)) {
                cardsOpacity = 1.0
            }
        }
    }
}

struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isGranted ? Color.black.opacity(0.85) : Color.black.opacity(0.10))
                        .frame(width: 44, height: 44)
                        .pixelBevel(cornerRadius: 6)

                    Image(systemName: isGranted ? "checkmark" : icon)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(isGranted ? NoirColors.success : Color.black.opacity(0.75))
                }

                VStack(alignment: .leading, spacing: 3) {
                    // The card below is near-white: dark ink, not the palette's
                    // white-on-glass aliases (charcoalDark/deepTeal both resolve to white).
                    Text(title)
                        .font(NoirFonts.title())
                        .foregroundColor(Color.black.opacity(0.88))

                    Text(description)
                        .font(NoirFonts.caption())
                        .foregroundColor(Color.black.opacity(0.62))
                        .lineLimit(2)
                }

                Spacer()

                if !isGranted {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.black.opacity(0.45))
                }
            }
            .padding(14)
            .background(NoirColors.creamWhite)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .pixelBevel(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 450)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        PermissionsScreen(viewModel: OnboardingViewModel())
    }
    .frame(width: 600, height: 700)
}
