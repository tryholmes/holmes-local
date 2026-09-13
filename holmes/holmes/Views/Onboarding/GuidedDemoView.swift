import AppKit
import SwiftUI

/// A small, repeatable workspace for trying Holmes with clearly labeled samples.
/// Selecting an example never runs it; every action begins with the Run button.
@MainActor
struct GuidedDemoView: View {
    @Bindable var model: GuidedDemoModel
    let onDone: () -> Void

    @State private var server = OllamaServer.shared
    @State private var copiedCase: GuidedDemoCase?

    private var selected: GuidedDemoCase { model.selectedCase }
    private var isRunning: Bool { model.runningCase == selected }
    private var needsModel: Bool { selected.requiresModel && !server.status.isReady }
    private var output: String { model.outputs[selected] ?? "" }
    private var hasOutput: Bool { model.outputs[selected] != nil }
    private var error: String? { model.errors[selected] }

    var body: some View {
        ZStack {
            AppleGlassBackground(cornerRadius: 16)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                examplePicker
                workspace
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 38)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 600, idealHeight: 680)
        .preferredColorScheme(.dark)
        .onChange(of: selected) { _, _ in copiedCase = nil }
        .onExitCommand {
            if model.runningCase != nil {
                model.cancel()
            } else {
                onDone()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("HOLMES")
                        .tracking(2)
                    Rectangle()
                        .fill(NoirColors.glassStroke)
                        .frame(width: 16, height: 1)
                    Text("A GUIDED FIRST TRY")
                        .tracking(1.2)
                }
                .font(NoirFonts.font(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NoirColors.textSecondary)

                Text("Take Holmes for a spin")
                    .font(NoirFonts.brand(size: 32))
                    .foregroundStyle(NoirColors.cream)

                Text("Three small examples. Choose one and see what happens.")
                    .font(NoirFonts.body())
                    .foregroundStyle(NoirColors.textSecondary)
            }

            Spacer(minLength: 0)

            NoirCharacterView(size: 53, glowColor: NoirColors.cream, glowRadius: 12)
                .accessibilityHidden(true)
        }
    }

    private var examplePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ForEach(Array(GuidedDemoCase.allCases.enumerated()), id: \.element.id) { index, example in
                    exampleButton(example, number: index + 1)
                }
            }

            HStack(spacing: 7) {
                ForEach(GuidedDemoCase.allCases) { example in
                    Capsule()
                        .fill(model.completedCases.contains(example)
                              ? NoirColors.success : NoirColors.glassDivider)
                        .frame(width: 18, height: 3)
                }
                Text("\(model.completedCount) of \(GuidedDemoCase.allCases.count) examples tried")
                    .font(NoirFonts.font(size: 10, design: .monospaced))
                    .foregroundStyle(NoirColors.textTertiary)
                    .padding(.leading, 3)
                Spacer()
                Text("Try them in any order")
                    .font(NoirFonts.font(size: 10))
                    .foregroundStyle(NoirColors.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.completedCount) of \(GuidedDemoCase.allCases.count) examples tried. Try them in any order.")
        }
    }

    private func exampleButton(_ example: GuidedDemoCase, number: Int) -> some View {
        let isSelected = selected == example
        let wasTried = model.completedCases.contains(example)

        return Button {
            model.select(example)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(String(format: "%02d", number))
                        .font(NoirFonts.font(size: 10, design: .monospaced))
                        .foregroundStyle(NoirColors.textTertiary)
                    Image(systemName: example.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? NoirColors.cream : NoirColors.iconSecondary)
                    Spacer(minLength: 0)
                    if wasTried {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(NoirColors.success)
                            .font(.system(size: 12))
                    }
                }
                Text(example.title)
                    .font(NoirFonts.font(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? NoirColors.textPrimary : NoirColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? NoirColors.glassElevated : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(isSelected ? NoirColors.cream.opacity(0.7) : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 13)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Example \(number): \(example.title)\(wasTried ? ", tried" : "")")
        .accessibilityHint(example.subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension GuidedDemoView {
    private var workspace: some View {
        GlassCard(cornerRadius: 12) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            promptSection

                            if selected.requiresModel && !selected.sampleText.isEmpty {
                                sampleSection
                            }

                            expectationSection
                            resultSection
                                .id("demo-result")
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: selected) { _, _ in
                        proxy.scrollTo("demo-prompt", anchor: .top)
                    }
                    .onChange(of: model.runningCase) { previous, current in
                        if previous == selected && current == nil {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("demo-result", anchor: .top)
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(NoirColors.glassDivider)
                    .frame(height: 1)

                runControls
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionLabel("THE REQUEST", icon: "text.bubble")
                Spacer()
                Text(selected.requiresModel ? "Uses your configured model" : "No model needed")
                    .font(NoirFonts.font(size: 10))
                    .foregroundStyle(NoirColors.textTertiary)
            }
            Text(selected.prompt)
                .font(NoirFonts.font(size: 16, weight: .medium))
                .foregroundStyle(NoirColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(selected.subtitle)
                .font(NoirFonts.caption())
                .foregroundStyle(NoirColors.textSecondary)
        }
        .id("demo-prompt")
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(selected == .draftReply ? "SAMPLE MESSAGE" : "SAMPLE NOTES", icon: "doc.text")
            Text(selected.sampleText)
                .font(NoirFonts.caption())
                .foregroundStyle(NoirColors.textSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(NoirColors.glassSurface, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var expectationSection: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "eye")
                .font(.system(size: 12))
                .foregroundStyle(NoirColors.cream.opacity(0.8))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("What to look for")
                    .font(NoirFonts.font(size: 11, weight: .medium))
                    .foregroundStyle(NoirColors.textPrimary)
                Text(selected.expectation)
                    .font(NoirFonts.caption())
                    .foregroundStyle(NoirColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel(hasOutput ? selected.resultTitle.uppercased() : "RESULT", icon: "sparkle")
                Spacer()
                if !output.isEmpty && !isRunning {
                    Button(action: copyOutput) {
                        Label(copiedCase == selected ? "Copied" : "Copy",
                              systemImage: copiedCase == selected ? "checkmark" : "doc.on.doc")
                            .font(NoirFonts.font(size: 11, weight: .medium))
                            .foregroundStyle(NoirColors.cream)
                    }
                    .buttonStyle(.plain)
                    .help("Copy this result to the clipboard")
                }
            }

            if let error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(NoirColors.error)
                    Text(error)
                        .foregroundStyle(NoirColors.textPrimary)
                        .textSelection(.enabled)
                }
                .font(NoirFonts.caption())
                .fixedSize(horizontal: false, vertical: true)
            }

            if hasOutput {
                if selected == .draftReply {
                    TextEditor(text: Binding(
                        get: { model.outputs[.draftReply] ?? "" },
                        set: {
                            model.updateOutput($0, for: .draftReply)
                            copiedCase = nil
                        }
                    ))
                    .font(NoirFonts.body())
                    .foregroundStyle(NoirColors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 120)
                    .background(NoirColors.glassInput, in: RoundedRectangle(cornerRadius: 7))
                    .disabled(isRunning)
                    .accessibilityLabel("Editable reply draft")

                    Text("Edit the draft here, then copy it when it reads right. Nothing is sent.")
                        .font(NoirFonts.font(size: 10))
                        .foregroundStyle(NoirColors.textTertiary)
                } else {
                    Text(output)
                        .font(NoirFonts.body())
                        .foregroundStyle(NoirColors.textPrimary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if error == nil {
                HStack(spacing: 10) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(NoirColors.iconSecondary)
                    }
                    Text(isRunning ? "\(selected.requiresModel ? "Holmes is working on the sample" : "Opening Calculator")…"
                         : "Run this example to see the result here.")
                        .font(NoirFonts.caption())
                        .foregroundStyle(NoirColors.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runControls: some View {
        HStack(spacing: 12) {
            if needsModel && !isRunning {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up a model to try this example")
                        .font(NoirFonts.font(size: 11, weight: .medium))
                        .foregroundStyle(NoirColors.textPrimary)
                    Text(server.status.headline)
                        .font(NoirFonts.font(size: 10))
                        .foregroundStyle(NoirColors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                NoirButton("Open Settings", icon: "gearshape", style: .secondary) {
                    SettingsWindowController.shared.show()
                }
            } else {
                Text(isRunning ? "You can cancel at any time."
                     : selected.requiresModel ? "Read the result and make it your own."
                     : "Opens the Calculator app on your Mac.")
                    .font(NoirFonts.font(size: 11))
                    .foregroundStyle(NoirColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if isRunning {
                    NoirButton("Cancel", icon: "stop", style: .secondary) {
                        model.cancel()
                    }
                } else {
                    NoirButton(error != nil ? "Try again" : selected.runLabel,
                               icon: error != nil ? "arrow.clockwise" : "play.fill") {
                        copiedCase = nil
                        model.runSelected()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Next time, just ask.")
                    .font(NoirFonts.font(size: 12, weight: .medium))
                    .foregroundStyle(NoirColors.textPrimary)
                Text("Hold Fn to speak · Control + Space to type")
                    .font(NoirFonts.font(size: 10, design: .monospaced))
                    .foregroundStyle(NoirColors.textTertiary)
            }
            Spacer(minLength: 0)
            NoirButton(model.completedCount == GuidedDemoCase.allCases.count ? "Finish" : "Skip for now",
                       icon: "arrow.right", style: .ghost) {
                model.cancel()
                onDone()
            }
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(NoirFonts.font(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(NoirColors.textTertiary)
    }

    private func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(output, forType: .string) {
            copiedCase = selected
        }
    }
}

#Preview("Guided demo") {
    GuidedDemoView(model: GuidedDemoModel(), onDone: {})
        .frame(width: 760, height: 680)
}
