import SwiftUI

/// The agent panel where a task is typed. The agent (the harness, in `acorn-runner`) does it in
/// the page next to it and reports each step here.
struct ChatSidebar: View {
    @ObservedObject var runner: AgentRunner
    var onClose: () -> Void
    @State private var draft = ""
    @State private var choosingModel = false
    @FocusState private var composerFocused: Bool
    @ObservedObject private var catalog = ModelCatalog.shared
    @Environment(\.palette) private var palette

    private static let suggestions: [(icon: String, text: String)] = [
        ("magnifyingglass", "Find the best-reviewed option on this page and summarize why"),
        ("tray.and.arrow.down", "Fill in this form with placeholder details and stop before submitting"),
        ("list.bullet.rectangle", "Collect the key facts from this page into a short list"),
    ]

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasConversation: Bool { runner.messages.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            composer
        }
        .frosted(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous),
                 weight: .panel, movesWindow: true)
        .task { await catalog.refresh() }
        .task { await runTaskFromLaunchArguments() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.sparkle).frame(width: 22, height: 22)
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
            Text("Agent").font(Theme.Text.title).foregroundStyle(palette.ink)
            if runner.isRunning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Working").font(Theme.Text.caption).foregroundStyle(palette.inkSecondary)
                }
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.chrome)
                .help("Hide the agent")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if hasConversation {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runner.messages.dropFirst()) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(14)
                } else {
                    emptyState
                }
            }
            .scrollIndicators(.never)
            .onChange(of: runner.messages.count) { _, _ in
                if let last = runner.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            ZStack {
                Circle().fill(Theme.sparkle.opacity(0.18)).frame(width: 64, height: 64)
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Theme.sparkle)
            }
            VStack(spacing: 4) {
                Text("What should I do for you?").font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.ink)
                Text("I work in the agent tab and report each step here. You can also paste a task file with url: and done_when: lines.")
                    .font(Theme.Text.secondary)
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.text) { suggestion in
                    Button { draft = suggestion.text; composerFocused = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.icon).frame(width: 18).foregroundStyle(palette.accent)
                            Text(suggestion.text).font(.system(size: 12.5)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(palette.ink)
                        .padding(10)
                        .background(palette.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The field stays open while the agent works: a message sent then reaches it with
            // its next look, so the person can steer or correct it without stopping it.
            TextField(runner.isRunning ? "Tell the agent something while it works" : "Give the agent a task", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(palette.ink)
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
                .padding(.horizontal, 4)
            HStack(spacing: 8) {
                modelMenu
                modeSwitch
                Spacer()
                modelSummary
                if runner.isRunning {
                    stopButton
                }
                sendButton
            }
        }
        .padding(12)
        .background(GlassBead(shape: RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
            .strokeBorder(palette.accent.opacity(composerFocused ? 0.45 : 0), lineWidth: 1.5))
        .padding(10)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(palette.accent.opacity(canSend ? 1 : 0.3)))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(runner.isRunning ? "Send to the agent while it works" : "Send")
    }

    private var stopButton: some View {
        Button(action: runner.stop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(palette.hover))
        }
        .buttonStyle(.plain)
        .help("Stop the agent")
    }

    /// Opens the searchable list of OpenRouter's models. The pick drives the next run; the
    /// decision model behind the checks is the runner's own and is not offered here.
    private var modelMenu: some View {
        Button { choosingModel.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 11))
                Text(shortName(runner.model)).lineLimit(1).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(palette.inkSecondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(palette.hover, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning)
        .help("The model that drives the page. The checks between its batches use the runner's decision model.")
        .popover(isPresented: $choosingModel, arrowEdge: .top) {
            ModelPicker(selection: $runner.model)
        }
    }

    /// How the model sees the page: a screenshot each step, or the page map and no picture
    /// (DOM mode). The pick drives the next run.
    private var modeSwitch: some View {
        Picker("", selection: $runner.mode) {
            Text("Image").tag("image")
            Text("DOM").tag("dom")
            Text("Hybrid").tag("hybrid")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 110)
        .disabled(runner.isRunning)
        .help("Image: the model sees a screenshot each step. DOM: it reads the page map (the page's own controls, names and states) and no picture at all.")
    }

    /// What the chosen model reads and a warning when it cannot read images.
    @ViewBuilder
    private var modelSummary: some View {
        if let model = catalog.model(runner.model) {
            HStack(spacing: 5) {
                ModalityIcons(kinds: model.inputs)
                if !model.seesImages && runner.mode != "dom" {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        .help("This model does not read images, and the agent sends it a screenshot every step. Switch to DOM mode, which sends none.")
                }
            }
            .help(model.shortPrice + " per 1M tokens")
        }
    }

    /// "openai/gpt-6-luna" as "gpt-6-luna".
    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// `AcornBrowser --run-task <file>` submits that task file once the first page is up, so a
    /// run can be started (and tested) without typing.
    private func runTaskFromLaunchArguments() async {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--run-task"), flag + 1 < arguments.count,
              let text = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) else { return }
        try? await Task.sleep(for: .seconds(6))
        runner.submit(text)
    }

    // MARK: Messages

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.kind {
        case .person:
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(palette.onAccent)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        case .step:
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(Theme.sparkle).frame(width: 6, height: 6).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.text).font(.system(size: 12.5)).foregroundStyle(palette.ink)
                    if !message.detail.isEmpty {
                        Text(message.detail).font(Theme.Text.caption).foregroundStyle(palette.inkSecondary)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        case .agent, .done, .problem:
            VStack(alignment: .leading, spacing: 6) {
                if message.kind != .agent {
                    Label(message.kind == .done ? "Done" : "Needs attention",
                          systemImage: message.kind == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(message.kind == .done ? Color.green : Color.orange)
                }
                Text(message.text).font(Theme.Text.body).foregroundStyle(palette.ink)
                if !message.detail.isEmpty {
                    Text(message.detail).font(Theme.Text.caption).foregroundStyle(palette.inkSecondary)
                }
            }
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(message.kind), in: RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
        }
    }

    private func tint(_ kind: ChatMessage.Kind) -> Color {
        switch kind {
        case .done: Color.green.opacity(palette.isDark ? 0.2 : 0.13)
        case .problem: Color.orange.opacity(palette.isDark ? 0.22 : 0.16)
        default: palette.hover
        }
    }

    private func send() {
        runner.submit(draft)
        draft = ""
    }
}
