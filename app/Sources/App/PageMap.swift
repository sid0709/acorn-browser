import Foundation

/// The page map of DOM mode (`harness/src/page.rs`): what this browser knows of the page, as
/// a flat, depth-first list of nodes, each with its role, its computed name, its live state and
/// its box in page coordinates. It is built from two DevTools answers joined on the DOM node:
///
/// - the accessibility tree (`Accessibility.getFullAXTree`), which has the name the browser
///   computed for a control (its label, its `alt`, its `aria-label`), its live state (checked,
///   selected, expanded, disabled, required), and leaves hidden things out;
/// - the DOM snapshot (`DOMSnapshot.captureSnapshot`), which has every node's box, its computed
///   `display`, `visibility`, `opacity` and `cursor`, its attributes, the value a control holds,
///   and which nodes the page handles a click on.
///
/// What is kept and how a line is written follows Oak's serializer: controls, headings, labels
/// and text; empty wrappers flattened away; images dropped but their `alt` kept as a name; a
/// node that is pressed but has no role kept as `clickable`; class tokens only where a node has
/// no name of its own. A child frame's tree is fetched apart (the main tree does not hold it)
/// and hung under the frame's line, its boxes moved to page coordinates. Nothing is written to
/// the page: the map is read, never stamped on the DOM.
///
/// The same logic, on the same answers, is in the reference builder the map was designed with
/// (a Playwright script), whose output is the harness's test fixture.
extension AgentDriver {
    // The roles a person acts on, the structure worth a line when named, and the internal
    // roles that are never a line of their own.
    nonisolated private static let controlRoles: Set<String> = [
        "link", "button", "textbox", "searchbox", "combobox", "checkbox", "radio", "menuitem",
        "menuitemcheckbox", "menuitemradio", "tab", "option", "switch", "slider", "spinbutton",
        "listbox", "treeitem", "menubutton", "ListBoxOption", "DisclosureTriangle", "Iframe",
    ]
    nonisolated private static let groupRoles: Set<String> = [
        "heading", "radiogroup", "group", "form", "navigation", "main", "banner", "contentinfo",
        "region", "search", "dialog", "alertdialog", "alert", "list", "listitem", "table", "row",
        "cell", "columnheader", "rowheader", "tablist", "menu", "menubar", "tree", "article",
        "section", "complementary", "figure", "img", "image", "status", "log", "progressbar",
        "definition", "term",
    ]
    nonisolated private static let skipRoles: Set<String> = [
        "none", "generic", "InlineTextBox", "LineBreak", "ListMarker", "RootWebArea", "LabelText",
        "Legend", "Caption", "paragraph", "Pre", "blockquote", "code", "emphasis", "strong",
        "superscript", "subscript", "time", "Abbr", "deletion", "insertion", "mark", "Ruby",
        "Details", "Summary", "Canvas", "SvgRoot", "DescriptionList", "DescriptionListTerm",
        "DescriptionListDetail",
    ]
    nonisolated private static let stateProperties = [
        "checked", "selected", "expanded", "disabled", "required", "invalid", "focused", "pressed",
        "readonly", "multiselectable", "hasPopup", "level", "valuemin", "valuemax",
    ]
    /// Chromium's internal names for roles the map writes in plain words.
    nonisolated private static let roleNames: [String: String] = [
        "DisclosureTriangle": "disclosure", "ListBoxOption": "option", "Iframe": "frame", "img": "image",
    ]
    nonisolated private static let maxName = 120
    nonisolated private static let maxText = 160
    nonisolated private static let computedStyles = ["display", "visibility", "opacity", "cursor"]

    /// One line of the map, as the harness reads it.
    private struct MapNode {
        var id = 0
        var role: String
        var name: String
        var depth: Int
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        var frame = 0
        var states: [String] = []
        var value: String?
        var kind: String?
        var hint: String?
        var href: String?

        var isControl: Bool { AgentDriver.controlRoles.contains(role) || role == "clickable" || role == "frame" || role == "disclosure" }

        var dictionary: [String: Any] {
            var out: [String: Any] = ["id": id, "role": role, "name": name, "depth": depth, "x": x, "y": y, "w": w, "h": h, "frame": frame]
            if !states.isEmpty { out["states"] = states }
            if let value { out["value"] = value }
            if let kind { out["kind"] = kind }
            if let hint { out["hint"] = hint }
            if let href { out["href"] = href }
            return out
        }
    }

    /// What the snapshot knows of one DOM node.
    private struct Laid {
        var box: (x: Double, y: Double, w: Double, h: Double)?
        var display = "", visibility = "", opacity = "", cursor = ""
        var clickable = false, checked = false, selected = false
        var value: String?
        var attrs: [String: String] = [:]
        var nodeType = 0
        var frame = 0

        /// Whether the node can be seen at all: laid out with a size, not hidden by style, not
        /// parked off the page (`left: -9999px`), not clipped to a dot (screen-reader-only text).
        var visible: Bool {
            guard let box else { return false }
            if box.w <= 0 || box.h <= 0 { return false }
            if display == "none" || visibility == "hidden" || visibility == "collapse" { return false }
            if let o = Double(opacity), o == 0 { return false }
            if box.x + box.w <= 0 || box.y + box.h <= 0 { return false }
            if box.w <= 1 && box.h <= 1 { return false }
            return true
        }
    }

    /// The snapshot, by DOM node: the layout of each, and which document each iframe holds.
    private struct Snapshot {
        var laid: [Int: Laid] = [:]
        /// The frame id of the document an iframe element holds, by the element's node id.
        var childFrame: [Int: String] = [:]
    }

    /// Builds the page map for this look, or nil when the browser could not answer. `m` is the
    /// page's metrics (`metrics()`): the snapshot's boxes come in the screen's pixels on a
    /// Retina display, and the page's width says by how much to bring them back to CSS pixels.
    func pageMap(_ m: [String: Any]) async -> [String: Any]? {
        do {
            let frameTree = try await call("Page.getFrameTree")
            let childIds = Self.childFrameIds((frameTree["frameTree"] as? [String: Any]) ?? [:])
            async let ax = call("Accessibility.getFullAXTree")
            async let snapshot = call("DOMSnapshot.captureSnapshot", ["computedStyles": Self.computedStyles, "includeDOMRects": false])
            let axReply = try await ax
            let snapReply = try await snapshot
            let nodes = (axReply["nodes"] as? [[String: Any]]) ?? []
            let snap = Self.readSnapshot(snapReply, scale: Self.snapshotScale(snapReply, m))
            // A child frame's tree is its own; a frame that will not answer (gone, another
            // process) is left as its frame line.
            var trees: [String: [[String: Any]]] = [:]
            for frameId in childIds {
                if let tree = try? await call("Accessibility.getFullAXTree", ["frameId": frameId]), let list = tree["nodes"] as? [[String: Any]] {
                    trees[frameId] = list
                }
            }
            let builder = MapBuilder(ax: nodes, trees: trees, snapshot: snap)
            return ["nodes": builder.build().map { $0.dictionary }]
        } catch {
            return nil
        }
    }

    /// The ids of every frame under the main one, depth first.
    nonisolated private static func childFrameIds(_ tree: [String: Any]) -> [String] {
        var out: [String] = []
        for child in (tree["childFrames"] as? [[String: Any]]) ?? [] {
            if let id = (child["frame"] as? [String: Any])?["id"] as? String { out.append(id) }
            out.append(contentsOf: childFrameIds(child))
        }
        return out
    }

    /// How many of the snapshot's pixels make one CSS pixel: the screen's ratio when the
    /// document's width in the snapshot matches the page's width times it, else 1.
    nonisolated private static func snapshotScale(_ reply: [String: Any], _ m: [String: Any]) -> Double {
        let ratio = max((m["ratio"] as? NSNumber)?.doubleValue ?? 1, 1)
        let pageWidth = (m["pageWidth"] as? NSNumber)?.doubleValue ?? 0
        let content = ((reply["documents"] as? [[String: Any]])?.first?["contentWidth"] as? NSNumber)?.doubleValue ?? 0
        guard ratio > 1, pageWidth > 0, content > 0 else { return 1 }
        return abs(content - pageWidth * ratio) < abs(content - pageWidth) ? ratio : 1
    }

    nonisolated private static func ints(_ value: Any?) -> [Int] {
        ((value as? [Any]) ?? []).map { ($0 as? NSNumber)?.intValue ?? -1 }
    }

    /// Reads the snapshot's columns into one entry per node. Layout bounds are relative to the
    /// document's own scroll, and a child document's to its frame: both offsets are added, so
    /// every box is in page coordinates.
    nonisolated private static func readSnapshot(_ reply: [String: Any], scale: Double) -> Snapshot {
        let strings = (reply["strings"] as? [String]) ?? []
        let documents = (reply["documents"] as? [[String: Any]]) ?? []
        let str = { (i: Int) -> String in i >= 0 && i < strings.count ? strings[i] : "" }
        var snap = Snapshot()
        var offsets = [(x: Double, y: Double)](repeating: (0, 0), count: documents.count)
        // Where each child document sits: the box of the iframe that holds it, plus its own
        // document's offset. Documents are listed parents first; a second pass catches the rest.
        for _ in 0..<2 {
            for (d, doc) in documents.enumerated() {
                let nodes = (doc["nodes"] as? [String: Any]) ?? [:]
                let layout = (doc["layout"] as? [String: Any]) ?? [:]
                let content = (nodes["contentDocumentIndex"] as? [String: Any]) ?? [:]
                let indexes = ints(content["index"]), values = ints(content["value"])
                let laidIndex = ints(layout["nodeIndex"])
                let bounds = (layout["bounds"] as? [[Any]]) ?? []
                let sx = (doc["scrollOffsetX"] as? NSNumber)?.doubleValue ?? 0
                let sy = (doc["scrollOffsetY"] as? NSNumber)?.doubleValue ?? 0
                for (k, i) in indexes.enumerated() where k < values.count && values[k] < documents.count {
                    guard let at = laidIndex.firstIndex(of: i), at < bounds.count, bounds[at].count == 4 else { continue }
                    let x = ((bounds[at][0] as? NSNumber)?.doubleValue ?? 0) / scale
                    let y = ((bounds[at][1] as? NSNumber)?.doubleValue ?? 0) / scale
                    offsets[values[k]] = (offsets[d].x + x + sx, offsets[d].y + y + sy)
                }
            }
        }
        for (d, doc) in documents.enumerated() {
            let nodes = (doc["nodes"] as? [String: Any]) ?? [:]
            let layout = (doc["layout"] as? [String: Any]) ?? [:]
            let backend = ints(nodes["backendNodeId"])
            let types = ints(nodes["nodeType"])
            let attributes = (nodes["attributes"] as? [[Any]]) ?? []
            let clickable = Set(ints((nodes["isClickable"] as? [String: Any])?["index"]))
            let checked = Set(ints((nodes["inputChecked"] as? [String: Any])?["index"]))
            let selected = Set(ints((nodes["optionSelected"] as? [String: Any])?["index"]))
            let inputValue = (nodes["inputValue"] as? [String: Any]) ?? [:]
            var values: [Int: String] = [:]
            for (k, i) in ints(inputValue["index"]).enumerated() {
                let v = ints(inputValue["value"])
                if k < v.count { values[i] = str(v[k]) }
            }
            let content = (nodes["contentDocumentIndex"] as? [String: Any]) ?? [:]
            for (k, i) in ints(content["index"]).enumerated() {
                let v = ints(content["value"])
                if k < v.count, v[k] < documents.count, i < backend.count {
                    snap.childFrame[backend[i]] = str((documents[v[k]]["frameId"] as? NSNumber)?.intValue ?? -1)
                }
            }
            let sx = (doc["scrollOffsetX"] as? NSNumber)?.doubleValue ?? 0
            let sy = (doc["scrollOffsetY"] as? NSNumber)?.doubleValue ?? 0
            let attrsOf = { (i: Int) -> [String: String] in
                var out: [String: String] = [:]
                guard i < attributes.count else { return out }
                let pairs = ints(attributes[i])
                var k = 0
                while k + 1 < pairs.count {
                    out[str(pairs[k])] = str(pairs[k + 1])
                    k += 2
                }
                return out
            }
            let laidIndex = ints(layout["nodeIndex"])
            let bounds = (layout["bounds"] as? [[Any]]) ?? []
            let styles = (layout["styles"] as? [[Any]]) ?? []
            for (k, i) in laidIndex.enumerated() where i < backend.count {
                var entry = Laid()
                if k < bounds.count, bounds[k].count == 4 {
                    let b = bounds[k].map { (($0 as? NSNumber)?.doubleValue ?? 0) / scale }
                    entry.box = (b[0] + sx + offsets[d].x, b[1] + sy + offsets[d].y, b[2], b[3])
                }
                let st = k < styles.count ? ints(styles[k]).map(str) : []
                if st.count == 4 {
                    entry.display = st[0]; entry.visibility = st[1]; entry.opacity = st[2]; entry.cursor = st[3]
                }
                entry.clickable = clickable.contains(i)
                entry.checked = checked.contains(i)
                entry.selected = selected.contains(i)
                entry.value = values[i]
                entry.attrs = attrsOf(i)
                entry.nodeType = i < types.count ? types[i] : 0
                entry.frame = d
                snap.laid[backend[i]] = entry
            }
            // A node with no layout (display: none, the head) still has its attributes.
            for (i, id) in backend.enumerated() where snap.laid[id] == nil {
                var entry = Laid()
                entry.clickable = clickable.contains(i)
                entry.checked = checked.contains(i)
                entry.selected = selected.contains(i)
                entry.value = values[i]
                entry.attrs = attrsOf(i)
                entry.nodeType = i < types.count ? types[i] : 0
                entry.frame = d
                snap.laid[id] = entry
            }
        }
        return snap
    }

    /// Class tokens a person can read: words, not hashes.
    nonisolated private static func readableClasses(_ attrs: [String: String]) -> String? {
        let tokens = (attrs["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
            token.count >= 3 && token.count <= 31
                && token.allSatisfy { $0.isLetter || $0 == "-" } && (token.first?.isLetter ?? false)
                && !token.lowercased().hasPrefix("css-") && !token.lowercased().hasPrefix("sc-") && !token.lowercased().hasPrefix("jss-")
        }
        let picked = tokens.prefix(3).joined(separator: " ")
        return picked.isEmpty ? nil : picked
    }

    nonisolated private static func clean(_ text: String, _ max: Int) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(max))
    }

    /// Walks the accessibility tree with the snapshot beside it and writes the lines.
    private final class MapBuilder {
        private var byId: [String: [String: Any]] = [:]
        private let root: [String: Any]?
        private let trees: [String: [[String: Any]]]
        private let snap: Snapshot
        private var nodes: [MapNode] = []

        init(ax: [[String: Any]], trees: [String: [[String: Any]]], snapshot: Snapshot) {
            for node in ax { if let id = node["nodeId"] as? String { byId[id] = node } }
            for tree in trees.values { for node in tree { if let id = node["nodeId"] as? String { byId[id] = node } } }
            root = ax.first
            self.trees = trees
            snap = snapshot
        }

        func build() -> [MapNode] {
            nodes.removeAll()
            if let root { walk(root, depth: 0) }
            // A label's text right before the control it names is the control's name already.
            var i = nodes.count - 2
            while i >= 0 {
                if nodes[i].role == "text" && nodes[i + 1].role != "text" && nodes[i + 1].name == nodes[i].name { nodes.remove(at: i) }
                i -= 1
            }
            for k in nodes.indices { nodes[k].id = k + 1 }
            return nodes
        }

        private func walk(_ ax: [String: Any], depth: Int) {
            let role = ((ax["role"] as? [String: Any])?["value"] as? String) ?? ""
            // Text keeps more of itself than a name does.
            let text = AgentDriver.clean(((ax["name"] as? [String: Any])?["value"] as? String) ?? "", AgentDriver.maxText)
            let name = String(text.prefix(AgentDriver.maxName))
            let ignored = (ax["ignored"] as? Bool) ?? false
            let backendId = (ax["backendDOMNodeId"] as? NSNumber)?.intValue ?? -1
            let laid = snap.laid[backendId]
            // A hidden node and everything under it is not on the page a person sees.
            if let laid, laid.box != nil, !laid.visible, role != "RootWebArea" { return }

            var props: [String: Any] = [:]
            for p in (ax["properties"] as? [[String: Any]]) ?? [] {
                if let key = p["name"] as? String { props[key] = (p["value"] as? [String: Any])?["value"] }
            }
            let named = !ignored && (role == "generic" || role == "none") && !name.isEmpty
            let keep = !ignored && (!AgentDriver.skipRoles.contains(role) || named)
            var line: Int? = nil
            let emit = { (role: String, name: String, extra: (inout MapNode) -> Void) in
                var node = MapNode(role: role, name: name, depth: depth)
                if let box = laid?.box { node.x = box.x.rounded(); node.y = box.y.rounded(); node.w = box.w.rounded(); node.h = box.h.rounded() }
                node.frame = laid?.frame ?? 0
                extra(&node)
                self.nodes.append(node)
                line = self.nodes.count - 1
            }
            if keep && (AgentDriver.controlRoles.contains(role) || AgentDriver.groupRoles.contains(role) || role == "StaticText" || named) {
                if role == "StaticText" || named {
                    if !text.isEmpty { emit("text", text) { _ in } }
                } else {
                    var states: [String] = []
                    for key in AgentDriver.stateProperties {
                        guard let v = props[key] else { continue }
                        // A JSON true or false arrives as a number too: only a real boolean is one.
                        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                            if n.boolValue { states.append(key) }
                            continue
                        }
                        let s = "\(v)"
                        if s == "false" || s == "none" || s.isEmpty { continue }
                        states.append(s == "true" ? key : "\(key)=\(s)")
                    }
                    // Live facts the snapshot has and the tree may not.
                    if laid?.checked == true && !states.contains("checked") { states.append("checked") }
                    if laid?.attrs["disabled"] != nil && !states.contains("disabled") { states.append("disabled") }
                    let kind = laid?.attrs["type"]
                    var value = (ax["value"] as? [String: Any])?["value"].map { "\($0)" } ?? ""
                    if value.isEmpty, let live = laid?.value, kind != "password" { value = live }
                    let roleName = AgentDriver.roleNames[role] ?? role
                    emit(roleName, name) { node in
                        node.states = states
                        if !value.isEmpty && kind != "password" { node.value = AgentDriver.clean(value, AgentDriver.maxText) }
                        if let kind, role == "textbox", kind != "text" { node.kind = kind }
                        if AgentDriver.controlRoles.contains(role) && name.isEmpty, let hint = AgentDriver.readableClasses(laid?.attrs ?? [:]) { node.hint = hint }
                        if role == "link", let href = laid?.attrs["href"] { node.href = String(href.prefix(120)) }
                    }
                }
            }
            if line == nil, let laid, laid.clickable, laid.nodeType == 1, laid.cursor == "pointer" || laid.attrs["onclick"] != nil, laid.visible {
                // A div made into a button: the tree calls it generic, the page says it is
                // pressed. Kept only when no descendant turns out to be a control of its own.
                emit("clickable", name) { node in node.hint = AgentDriver.readableClasses(laid.attrs) }
            }

            let childDepth = line == nil ? depth : depth + 1
            let before = nodes.count
            for id in (ax["childIds"] as? [String]) ?? [] {
                if let child = byId[id] { walk(child, depth: childDepth) }
            }
            // The frame's own tree, under the frame's line.
            if let frameId = snap.childFrame[backendId], let tree = trees[frameId], let frameRoot = tree.first {
                walk(frameRoot, depth: childDepth)
            }
            guard let at = line else { return }
            if nodes[at].role == "clickable" {
                let kids = nodes[before...]
                if kids.contains(where: { $0.isControl }) {
                    // A clickable wrapper whose children carry a real control is noise.
                    nodes.remove(at: at)
                    for k in (before - 1)..<nodes.count { nodes[k].depth -= 1 }
                    return
                }
                if nodes[at].name.isEmpty {
                    // Named from its text, as a button would be.
                    nodes[at].name = AgentDriver.clean(kids.filter { $0.role == "text" }.map(\.name).joined(separator: " "), AgentDriver.maxName)
                    nodes.removeSubrange(before...)
                    return
                }
            }
            // A sole child that only repeats its parent's name (the image in a link, the heading
            // in a link, the text of a button) says nothing new.
            if nodes[at].role != "text", nodes.count == before + 1, nodes[before].name == nodes[at].name, !nodes[before].isControl {
                nodes.remove(at: before)
            }
        }
    }
}
