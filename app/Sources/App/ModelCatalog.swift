import Foundation

/// One model as OpenRouter's public list describes it: what it reads and writes, how much it
/// holds, and what it costs.
struct CatalogModel: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let contextLength: Int
    let maxOutput: Int
    let inputs: [String]
    let outputs: [String]
    let prices: [Price]
    /// Dearer prices above a prompt length, as "Above 272K prompt tokens" and its prices.
    let tiers: [(threshold: String, prices: [Price])]
    let reasoningEfforts: [String]
    let parameters: [String]

    struct Price: Hashable {
        let label: String
        let text: String
    }

    static func == (a: CatalogModel, b: CatalogModel) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// A driving model reads a screenshot each step.
    var seesImages: Bool { inputs.contains("image") }

    /// Input and output per million tokens, for one line.
    var shortPrice: String {
        let input = prices.first { $0.label == "Input" }?.text ?? "?"
        let output = prices.first { $0.label == "Output" }?.text ?? "?"
        return "\(input) in · \(output) out"
    }

    /// Whether every word of the search is in the id or the name.
    func matches(_ words: [String]) -> Bool {
        let haystack = (id + " " + name).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

extension CatalogModel {
    /// The price fields OpenRouter sends, in the order shown, with how each is counted.
    private static let priceFields: [(key: String, label: String, unit: Unit)] = [
        ("prompt", "Input", .tokens),
        ("completion", "Output", .tokens),
        ("internal_reasoning", "Reasoning", .tokens),
        ("input_cache_read", "Cache read", .tokens),
        ("input_cache_write", "Cache write", .tokens),
        ("input_cache_write_1h", "Cache write (1 h)", .tokens),
        ("audio", "Audio input", .tokens),
        ("input_audio_cache", "Audio cache", .tokens),
        ("audio_output", "Audio output", .tokens),
        ("image", "Image input", .each("image")),
        ("image_output", "Image output", .tokens),
        ("web_search", "Web search", .each("search")),
        ("request", "Request", .each("request")),
    ]

    private enum Unit { case tokens, each(String) }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = (json["name"] as? String) ?? id
        summary = (json["description"] as? String) ?? ""
        let architecture = json["architecture"] as? [String: Any] ?? [:]
        inputs = architecture["input_modalities"] as? [String] ?? []
        outputs = architecture["output_modalities"] as? [String] ?? []
        let top = json["top_provider"] as? [String: Any] ?? [:]
        contextLength = (json["context_length"] as? Int) ?? (top["context_length"] as? Int) ?? 0
        maxOutput = (top["max_completion_tokens"] as? Int) ?? 0
        let pricing = json["pricing"] as? [String: Any] ?? [:]
        prices = Self.prices(pricing, keepZero: true)
        tiers = (pricing["overrides"] as? [[String: Any]] ?? []).compactMap { tier in
            guard let from = tier["min_prompt_tokens"] as? Int else { return nil }
            return ("Above \(Self.tokens(from)) prompt tokens", Self.prices(tier, keepZero: false))
        }
        let reasoning = json["reasoning"] as? [String: Any] ?? [:]
        reasoningEfforts = reasoning["supported_efforts"] as? [String] ?? []
        parameters = json["supported_parameters"] as? [String] ?? []
    }

    /// The prices present in one pricing object. Input and output are always shown, as "free"
    /// when zero; the rest only when they cost something.
    private static func prices(_ pricing: [String: Any], keepZero: Bool) -> [Price] {
        priceFields.compactMap { field in
            guard let raw = pricing[field.key] as? String, let value = Double(raw) else { return nil }
            let always = keepZero && (field.key == "prompt" || field.key == "completion")
            if value == 0 && !always { return nil }
            if value < 0 { return Price(label: field.label, text: "varies") }
            if value == 0 { return Price(label: field.label, text: "free") }
            switch field.unit {
            case .tokens: return Price(label: field.label, text: dollars(value * 1_000_000) + " / 1M")
            case .each(let what): return Price(label: field.label, text: dollars(value) + " / \(what)")
            }
        }
    }

    static func dollars(_ value: Double) -> String {
        if value >= 100 { return String(format: "$%.0f", value) }
        // Cents as cents ("$0.10"), and a price between cents ("$0.125") whole.
        if value >= 0.01 && abs(value * 100 - (value * 100).rounded()) < 1e-9 { return String(format: "$%.2f", value) }
        return String(format: "$%.4g", value)
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%gM", (Double(count) / 10_000).rounded() / 100) }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }
}

/// Every model OpenRouter offers, from its public list (no key needed). The last list fetched is
/// kept on disk, so the picker works offline and opens with it while a fresh one loads.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    @Published private(set) var models: [CatalogModel] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?

    private static let listURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private static var cacheFile: URL { AgentRunner.appDirectory.appendingPathComponent("openrouter-models.json") }
    private var fetchedThisLaunch = false

    private init() {
        if let data = try? Data(contentsOf: Self.cacheFile) { models = Self.parse(data) ?? [] }
    }

    func model(_ id: String) -> CatalogModel? { models.first { $0.id == id } }

    /// Fetches the list once per launch, or again when `force`.
    func refresh(force: Bool = false) async {
        guard !loading, force || !fetchedThisLaunch else { return }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.listURL)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "OpenRouter answered \(http.statusCode)"])
            }
            guard let parsed = Self.parse(data), !parsed.isEmpty else {
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "OpenRouter's model list could not be read"])
            }
            models = parsed
            failure = nil
            fetchedThisLaunch = true
            try? FileManager.default.createDirectory(at: AgentRunner.appDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.cacheFile, options: .atomic)
        } catch {
            failure = error.localizedDescription
        }
    }

    private static func parse(_ data: Data) -> [CatalogModel]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return nil }
        return list.compactMap(CatalogModel.init(json:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
