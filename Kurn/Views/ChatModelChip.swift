import AgentHarness
import SwiftUI

/// The composer's model chip: the model answering, its reasoning level and the context in use.
/// Tapping it opens `ChatModelSheet` to choose the configured provider's model and the level.
struct ChatModelChip: View {
    let settings: AppSettings
    let gauge: ChatContextGauge?
    var isEnabled = true
    @State private var showingChoice = false

    private var provider: AIProvider { settings.aiProvider }
    private var model: String { settings.summaryModel(for: provider) }

    private var label: String {
        if provider.kind == .appleOnDevice { return NSLocalizedString("settings.on_device_model_name", comment: "Apple Intelligence") }
        let offered = ChatReasoningPreference.isOffered(provider: provider,
            capabilities: ChatReasoningPreference.capabilities(provider: provider, model: model))
        return ChatModelPickerViewModel.chipText(model: model, level: settings.chatReasoningLevel, offered: offered) {
            NSLocalizedString($0, comment: "Reasoning level")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { showingChoice = true } label: {
                HStack(spacing: 4) {
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isEnabled {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.fill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(String(format: NSLocalizedString("chat.model_chip", comment: "Model in use"), label))
            .accessibilityHint(NSLocalizedString("chat.model.choose.hint", comment: "Opens the model and reasoning choice"))
            .accessibilityIdentifier("chat.model")
            if let gauge { ChatContextGaugeView(gauge: gauge) }
        }
        .sheet(isPresented: $showingChoice) {
            ChatModelSheet(settings: settings, provider: provider)
        }
    }
}

/// A small ring with the share of the window in use; the full figures are in its label.
struct ChatContextGaugeView: View {
    let gauge: ChatContextGauge

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Theme.separator, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: gauge.fraction)
                    .stroke(gauge.fraction > 0.8 ? Theme.accent : Theme.textSecondary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            Text(verbatim: "\(gauge.percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.accessibilityText { NSLocalizedString($0, comment: "Context in use") })
        .accessibilityIdentifier("chat.context.gauge")
    }
}

/// The configured provider's models and the reasoning level, as a sheet over the chat.
struct ChatModelSheet: View {
    let settings: AppSettings
    let provider: AIProvider
    @State private var picker: ChatModelPickerViewModel
    @Environment(\.dismiss) private var dismiss

    init(settings: AppSettings, provider: AIProvider) {
        self.settings = settings
        self.provider = provider
        _picker = State(initialValue: ChatModelPickerViewModel(provider: provider, current: settings.summaryModel(for: provider)))
    }

    private var model: String { settings.summaryModel(for: provider) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(picker.models, id: \.self) { candidate in
                        Button { settings.setSummaryModel(candidate, for: provider) } label: {
                            HStack {
                                Text(candidate).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if candidate == model {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(candidate == model ? .isSelected : [])
                    }
                    if picker.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    Text(provider.displayName)
                } footer: {
                    Text(NSLocalizedString(picker.loadFailed ? "chat.model.list_failed" : "chat.model.shared",
                                           comment: "Model list footer"))
                }
                Section {
                    if picker.offersReasoning(model: model) {
                        Picker(NSLocalizedString("chat.reasoning.title", comment: "Reasoning"), selection: Binding(
                            get: { settings.chatReasoningLevel },
                            set: { settings.chatReasoningLevel = $0 }
                        )) {
                            Text(NSLocalizedString("chat.reasoning.automatic", comment: "Provider default")).tag(AgentReasoningLevel?.none)
                            ForEach(AgentReasoningLevel.allCases, id: \.self) { level in
                                Text(NSLocalizedString("chat.reasoning.\(level.rawValue)", comment: "Reasoning level"))
                                    .tag(Optional(level))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } else {
                        Text(NSLocalizedString("chat.reasoning.unavailable", comment: "Model takes no reasoning level"))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } header: {
                    Text(NSLocalizedString("chat.reasoning.title", comment: "Reasoning"))
                } footer: {
                    Text(NSLocalizedString("chat.reasoning.footer", comment: "What the level does"))
                }
            }
            .navigationTitle(NSLocalizedString("chat.model.title", comment: "Model and reasoning"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                        .accessibilityIdentifier("chat.model.done")
                }
            }
            .task { await picker.refresh(current: model) }
        }
        .presentationDetents([.medium, .large])
    }
}
