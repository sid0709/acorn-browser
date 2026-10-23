import SwiftUI

/// The sidebar where a task is typed. The agent (the harness, in `acorn-runner`) does it in the
/// page on the left and reports each step here.
struct ChatSidebar: View {
    @StateObject private var runner = AgentRunner()
    @State private var draft = ""
    /// Whether the model is typed in rather than picked from the list.
    @State private var customModel = false

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
            if customModel {
                TextField("Model id, as OpenRouter names it", text: $runner.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(runner.isRunning)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
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
        .onAppear { customModel = !AgentRunner.knownModels.contains(runner.model) }
        .task { await runTaskFromLaunchArguments() }
    }

    /// Picks the model that drives the next run: the known ones by name, or any id typed in.
    /// The decision model behind the checks is the runner's own and is not offered here.
    private var modelMenu: some View {
        Menu {
            ForEach(AgentRunner.knownModels, id: \.self) { id in
                Button {
                    runner.model = id
                    customModel = false
                } label: {
                    if id == runner.model {
                        Label(shortName(id), systemImage: "checkmark")
                    } else {
                        Text(shortName(id))
                    }
                }
            }
            Divider()
            Button("Other model…") { customModel = true }
        } label: {
            Label(shortName(runner.model), systemImage: "cpu").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The model that drives the page. The checks between its batches use the runner's decision model.")
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
