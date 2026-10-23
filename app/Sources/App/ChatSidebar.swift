import SwiftUI

/// The sidebar where a task is typed. The agent (the harness, in `acorn-runner`) does it in the
/// page on the left and reports each step here.
struct ChatSidebar: View {
    @StateObject private var runner = AgentRunner()
    @State private var draft = ""
    @State private var choosingModel = false
    @ObservedObject private var catalog = ModelCatalog.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent").font(.headline)
                Spacer()
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Working").font(.caption).foregroundStyle(.secondary)
                } else {
                    modelMenu
                }
            }
            .padding(12)
            modelSummary
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(runner.messages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: runner.messages.count) { _, _ in
                    if let last = runner.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Give the agent a task", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(runner.isRunning)
                    .onSubmit(send)
                if runner.isRunning {
                    Button(action: runner.stop) { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .help("Stop the agent")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
        .background(.background)
        .task { await catalog.refresh() }
        .task { await runTaskFromLaunchArguments() }
    }

    /// Opens the searchable list of OpenRouter's models. The pick drives the next run; the
    /// decision model behind the checks is the runner's own and is not offered here.
    private var modelMenu: some View {
        Button { choosingModel.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(shortName(runner.model)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("The model that drives the page. The checks between its batches use the runner's decision model.")
        .popover(isPresented: $choosingModel, arrowEdge: .bottom) {
            ModelPicker(selection: $runner.model)
        }
    }

    /// One line under the header for the chosen model: what it reads and its token prices.
    @ViewBuilder
    private var modelSummary: some View {
        if let model = catalog.model(runner.model) {
            HStack(spacing: 6) {
                ModalityIcons(kinds: model.inputs)
                Text(model.shortPrice + " per 1M tokens").font(.caption2).foregroundStyle(.secondary)
                if !model.seesImages {
                    Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                        .help("This model does not read images, and the agent sends it a screenshot every step.")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.kind {
        case .person:
            Text(message.text)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        case .step:
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text).font(.callout)
                if !message.detail.isEmpty {
                    Text(message.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        case .agent, .done, .problem:
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text).bold(message.kind != .agent)
                if !message.detail.isEmpty {
                    Text(message.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(message.kind), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func tint(_ kind: ChatMessage.Kind) -> Color {
        switch kind {
        case .done: Color.green.opacity(0.18)
        case .problem: Color.orange.opacity(0.22)
        default: Color.secondary.opacity(0.12)
        }
    }

    private func send() {
        runner.submit(draft)
        draft = ""
    }
}
