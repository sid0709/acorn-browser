import Foundation

struct ChatMessage: Identifiable {
    enum Kind { case person, agent, step, done, problem }
    let id = UUID()
    let kind: Kind
    var text: String
    /// A smaller second part: the actions of a step, or what a finished run left.
    var detail = ""
}

/// A value touched from several threads (the pipe handlers and the termination handler).
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Runs a typed task: writes it to a task file, starts `acorn-runner` (the harness) against this
/// app's own browser, and turns the events it prints into chat messages.
@MainActor
final class AgentRunner: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = [
        ChatMessage(kind: .agent, text: "Type a task and I will do it in the page on the left. You can also paste a task file, with its url: and done_when: lines.")
    ]
    @Published private(set) var isRunning = false
    /// The model that drives the page, as OpenRouter names it, kept between launches. The
    /// checks between batches use the runner's own decision model, which this does not touch.
    @Published var model: String = UserDefaults.standard.string(forKey: AgentRunner.modelKey) ?? AgentRunner.defaultModel {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    static let defaultModel = "openai/gpt-6-luna"
    private static let modelKey = "agentModel"
    /// How the model sees the page: `image` (a screenshot each step) or `dom` (the page map
    /// and no picture), kept between launches. In DOM mode no picture reaches the model at all,
    /// so a run measures that way of seeing on its own.
    @Published var mode: String = UserDefaults.standard.string(forKey: AgentRunner.modeKey) ?? "image" {
        didSet { UserDefaults.standard.set(mode, forKey: Self.modeKey) }
    }
    private static let modeKey = "agentMode"

    private var process: Process?
    private var stopped = false
    private var finished = false

    static var appDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.acorn.browser")
    }

    private var runnerURL: URL? {
        if let path = ProcessInfo.processInfo.environment["ACORN_RUNNER"] { return URL(fileURLWithPath: path) }
        return Bundle.main.resourceURL?.appendingPathComponent("acorn-runner")
    }

    func submit(_ text: String) {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !isRunning else { return }
        messages.append(ChatMessage(kind: .person, text: task))
        start(task)
    }

    func stop() {
        guard let process, isRunning else { return }
        stopped = true
        process.terminate()
    }

    private func start(_ task: String) {
        guard let runner = runnerURL, FileManager.default.isExecutableFile(atPath: runner.path) else {
            messages.append(ChatMessage(kind: .problem, text: "The agent runner is missing from the app. Rebuild with scripts/build.sh."))
            return
        }

        // One folder per run: the task as typed, and the harness's trace of what it saw and did.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let runDirectory = Self.appDirectory.appendingPathComponent("runs/\(stamp.string(from: Date()))")
        let taskFile = runDirectory.appendingPathComponent("task.md")
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            try task.write(to: taskFile, atomically: true, encoding: .utf8)
        } catch {
            messages.append(ChatMessage(kind: .problem, text: "Could not save the task: \(error.localizedDescription)"))
            return
        }

        let process = Process()
        process.executableURL = runner
        process.arguments = [
            taskFile.path,
            "--socket", AgentServer.socketPath,
            "--trace", runDirectory.path,
            "--model", drivingModel,
            "--mode", mode == "dom" ? "dom" : "image",
            "--env-file", Self.appDirectory.appendingPathComponent(".env").path,
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Every event the runner prints is also kept in the run's folder, for looking back.
        let eventsFile = runDirectory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
        let eventsLog = try? FileHandle(forWritingTo: eventsFile)

        let pending = Locked(Data())
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines: [Data] = pending.with { buffer in
                buffer.append(data)
                var found: [Data] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    found.append(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                return found
            }
            for line in lines {
                eventsLog?.write(line + Data([0x0A]))
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                Task { @MainActor in self?.handle(event) }
            }
        }

        let errorText = Locked(Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            errorText.with { buffer in
                buffer.append(data)
                if buffer.count > 4000 { buffer = buffer.suffix(4000) }
            }
        }

        process.terminationHandler = { [weak self] finished in
            let tail = errorText.with { String(data: $0, encoding: .utf8) ?? "" }
            Task { @MainActor in self?.ended(status: finished.terminationStatus, errorText: tail) }
        }

        stopped = false
        finished = false
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            messages.append(ChatMessage(kind: .problem, text: "Could not start the agent: \(error.localizedDescription)"))
        }
    }

    /// The chosen model, or the default when the field was left blank.
    private var drivingModel: String {
        let chosen = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? Self.defaultModel : chosen
    }

    private func ended(status: Int32, errorText: String) {
        isRunning = false
        process = nil
        if stopped {
            messages.append(ChatMessage(kind: .agent, text: "Stopped."))
        } else if !finished && status != 0 {
            let reason = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(kind: .problem, text: reason.isEmpty ? "The agent stopped unexpectedly (exit \(status))." : reason))
        }
    }

    // MARK: Events from the runner

    private func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "start":
            break
        case "understood":
            let summary = event["summary"] as? String ?? ""
            var detail: [String] = []
            if let url = event["startUrl"] as? String, !url.isEmpty { detail.append("Starting at \(url)") }
            if let done = event["doneWhen"] as? String, !done.isEmpty { detail.append("Done when \(done)") }
            messages.append(ChatMessage(kind: .agent, text: summary.isEmpty ? "Understood." : summary, detail: detail.joined(separator: "\n")))
        case "step":
            let number = event["number"] as? Int ?? 0
            let message = event["message"] as? String ?? ""
            let actions = (event["actions"] as? [String]) ?? []
            let status = event["status"] as? String ?? ""
            var detail = actions.map { "• \($0)" }.joined(separator: "\n")
            for question in (event["questions"] as? [[String: Any]]) ?? [] {
                detail += (detail.isEmpty ? "" : "\n") + "? \(question["text"] as? String ?? "")"
            }
            // The step that ends the run is shown by the end event, which has the full picture.
            if status == "working" {
                messages.append(ChatMessage(kind: .step, text: "\(number). \(message)", detail: detail))
            }
        case "action_failed":
            let error = event["error"] as? String ?? "an action failed"
            messages.append(ChatMessage(kind: .step, text: "That did not work: \(error)"))
        case "end":
            finished = true
            messages.append(finalMessage(event))
        case "error":
            finished = true
            messages.append(ChatMessage(kind: .problem, text: event["message"] as? String ?? "Something went wrong."))
        default:
            break
        }
    }

    private func finalMessage(_ event: [String: Any]) -> ChatMessage {
        let status = event["status"] as? String ?? ""
        var message = event["message"] as? String ?? ""
        var detail: [String] = []
        // The answer in words is what the person asked for; the status line goes under it.
        if let answer = event["answer"] as? String, !answer.isEmpty {
            if !message.isEmpty { detail.append(message) }
            message = answer
        }
        if let stop = event["stop"] as? [String: Any] {
            let problem = stop["problem"] as? String ?? ""
            let action = stop["action"] as? String ?? ""
            detail.append([problem, action].filter { !$0.isEmpty }.joined(separator: " "))
        }
        if let report = event["report"] as? [String: Any] {
            let assumed = report["assumed"] as? [String] ?? []
            if !assumed.isEmpty { detail.append("Assumed: " + assumed.joined(separator: "; ")) }
            let left = report["left"] as? [String] ?? []
            if !left.isEmpty { detail.append("Left: " + left.joined(separator: ", ")) }
            for question in (report["questions"] as? [[String: Any]]) ?? [] {
                let text = question["text"] as? String ?? ""
                let answer = question["answer"] as? String ?? "no answer"
                detail.append("Asked: \(text) (\(answer))")
            }
        }
        let seconds = event["seconds"] as? Double ?? 0
        let cost = event["cost"] as? Double ?? 0
        detail.append(String(format: "%.0f s, $%.4f", seconds, cost))
        let kind: ChatMessage.Kind = status == "done" ? .done : .problem
        return ChatMessage(kind: kind, text: message.isEmpty ? status : message, detail: detail.joined(separator: "\n"))
    }
}
