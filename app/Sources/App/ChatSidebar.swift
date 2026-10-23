import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case person, agent }
    let id = UUID()
    let role: Role
    let text: String
}

/// The sidebar where a task is typed. Stage 1: the box takes input and answers that no
/// agent is connected yet; the harness is wired in at stage 3.
struct ChatSidebar: View {
    @State private var messages = [
        ChatMessage(role: .agent, text: "Type a task and I will do it in the page on the left. The agent is not connected yet.")
    ]
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Agent")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Give the agent a task", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .background(.background)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        Text(message.text)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: message.role == .person ? .trailing : .leading)
            .background(
                message.role == .person ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .person, text: text))
        messages.append(ChatMessage(role: .agent, text: "Noted. The agent is not connected yet, so nothing ran."))
        draft = ""
    }
}
