import SwiftUI

/// The searchable list of OpenRouter's models. Picking one makes it the driving model at once;
/// the panel below shows what the chosen one reads and writes, and what it costs.
struct ModelPicker: View {
    @Binding var selection: String
    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var search = ""
    @State private var imagesOnly = false

    private var words: [String] {
        search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var shown: [CatalogModel] {
        catalog.models.filter { (!imagesOnly || $0.seesImages) && $0.matches(words) }
    }

    /// A typed id that is not in the list, offered as is (a model added since the list loaded).
    private var typedID: String? {
        let id = search.trimmingCharacters(in: .whitespaces)
        guard id.contains("/"), !id.contains(" "), catalog.model(id) == nil else { return nil }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(catalog.models.count) models", text: $search)
                    .textFieldStyle(.plain)
                if catalog.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await catalog.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Fetch the list from OpenRouter again")
                }
            }
            .padding(10)
            HStack {
                Toggle("Only models that read images", isOn: $imagesOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("The agent sends a screenshot every step, so the driving model has to read images.")
                Spacer()
                Text("\(shown.count) shown").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            if let failure = catalog.failure {
                Text(catalog.models.isEmpty ? "Could not load the models: \(failure)" : "Showing the last list fetched: \(failure)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            List {
                if let id = typedID {
                    Button { selection = id } label: {
                        Label("Use \u{201C}\(id)\u{201D} as the model id", systemImage: "keyboard")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(shown) { model in
                    row(model)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = model.id }
                        .listRowBackground(model.id == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                }
            }
            .listStyle(.plain)
            .frame(height: 240)
            Divider()
            ScrollView {
                ModelDetail(id: selection, model: catalog.model(selection))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 280)
        }
        .frame(width: 460)
        .task { await catalog.refresh() }
    }

    private func row(_ model: CatalogModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).lineLimit(1)
                Text(model.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ModalityIcons(kinds: model.inputs)
                Text(model.shortPrice).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Everything known about one model: what it reads and writes, its size, and each price.
struct ModelDetail: View {
    let id: String
    let model: CatalogModel?

    var body: some View {
        if let model {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline)
                    Text(model.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !model.seesImages {
                    Label("This model does not read images, and the agent sends it a screenshot every step.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                grid([
                    ("Reads", model.inputs.joined(separator: ", ")),
                    ("Writes", model.outputs.joined(separator: ", ")),
                    ("Context", model.contextLength > 0 ? CatalogModel.tokens(model.contextLength) + " tokens" : "unknown"),
                    ("Max output", model.maxOutput > 0 ? CatalogModel.tokens(model.maxOutput) + " tokens" : "unknown"),
                    ("Reasoning", model.reasoningEfforts.isEmpty ? (model.parameters.contains("reasoning") ? "yes" : "no") : model.reasoningEfforts.joined(separator: ", ")),
                    ("Tools", model.parameters.contains("tools") ? "yes" : "no"),
                    ("JSON output", model.parameters.contains("structured_outputs") || model.parameters.contains("response_format") ? "yes" : "no"),
                ])
                Text("Price").font(.subheadline.bold())
                grid(model.prices.map { ($0.label, $0.text) })
                ForEach(model.tiers, id: \.threshold) { tier in
                    Text(tier.threshold).font(.caption.bold()).foregroundStyle(.secondary)
                    grid(tier.prices.map { ($0.label, $0.text) })
                }
                if !model.summary.isEmpty {
                    Text(model.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(id).font(.headline)
                Text("Not in OpenRouter's list as loaded, so nothing is known about it. It is passed to OpenRouter as typed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }
}

/// Small symbols for what a model reads: text, image, file, audio, video.
struct ModalityIcons: View {
    let kinds: [String]
    private static let order = ["text", "image", "file", "audio", "video"]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.order.filter(kinds.contains), id: \.self) { kind in
                Image(systemName: Self.symbol(kind)).help(kind)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "text": "textformat"
        case "image": "photo"
        case "file": "doc"
        case "audio": "waveform"
        case "video": "film"
        default: "questionmark"
        }
    }
}
