import AppKit

struct AgentError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// An action that could not be carried out. `unreached` means the page was left untouched
/// (typing with nothing focused), so the rest of the batch can still run.
struct ActionFailure: Error {
    let message: String
    var unreached = false
}

/// The browser side of the harness's protocol, on a Chromium tab: it looks at the page and does
/// what an action asks, through the DevTools protocol. The requests and replies are the ones
/// `kit/browser/browser.mjs` speaks; the harness cannot tell the two apart.
@MainActor
final class AgentDriver {
    // How a page is looked at and acted on; the same numbers as the kit's Playwright side.
    nonisolated private static let surveyOverlap = 120.0
    nonisolated private static let focusNear = 24.0
    nonisolated private static let quietMs = 250.0
    nonisolated private static let settleCap = 5.0
    nonisolated private static let scrollSettleCap = 1.0
    nonisolated private static let openCap = 30.0
    nonisolated private static let maxWaitMs = 10_000.0
    nonisolated private static let jpegQuality = 80
    nonisolated private static let evaluateRetries = 5
    nonisolated private static let maxLabel = 80
    nonisolated private static let maxValue = 200
    /// How long one in-page wait for quiet may last: each DevTools call has a time limit in
    /// the browser view, so a long settle is made of short waits.
    nonisolated private static let maxQuietWait = 2.0
    /// A request still open after this long (a long poll, a stream) no longer holds a look.
    nonisolated private static let staleRequest = 8.0
    /// How long an upload waits for the page to ask for a file after the click.
    nonisolated private static let chooserWait = 3.0
    nonisolated private static let pollMs = 50

    private let model: BrowserModel
    private var view: ChromiumBrowserView { model.view }
    private var notes: [String] = []
    private var zoneShots: [[String: Any]] = []
    /// The page's requests not yet answered, by request id, with when each was sent.
    private var inFlight: [String: Date] = [:]
    /// The file picker the page opened and the browser intercepted, until an upload takes it.
    private var chooser: [String: Any]?
    /// Whether the DevTools domains this driver listens to are on for the current browser.
    private var domainsOn = false
    private var attached = false

    init(model: BrowserModel) {
        self.model = model
        // The browser view calls these on the main thread, which the actor is.
        model.view.devToolsEventHandler = { [weak self] method, params in
            MainActor.assumeIsolated { self?.event(method, (params as? [String: Any]) ?? [:]) }
        }
    }

    // MARK: Attaching

    /// Takes the page over for the harness: dialogs are answered, file pickers intercepted,
    /// blocked windows opened in this tab, and the page's traffic watched.
    private func attach() async {
        if !attached {
            attached = true
            view.dialogHandler = { [weak self] kind, message, _ in
                MainActor.assumeIsolated {
                    // An alert only informs, and leaving a page is what the plan asked for; a
                    // question the page asks is not the harness's to answer, so it is declined.
                    let accept = kind == .alert || kind == .beforeUnload
                    let shown = Self.cut(message, Self.maxValue)
                    self?.notes.append("A dialog said: \(shown) (it was \(accept ? "accepted" : "dismissed")).")
                    return accept ? "" : nil
                }
            }
            view.downloadHandler = { [weak self] name, finished in
                MainActor.assumeIsolated {
                    self?.notes.append(finished ? "A file downloaded: \(name)." : "A download started: \(name).")
                }
            }
            view.blockedPopupHandler = { [weak self] url in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if url.isEmpty || url == "about:blank" {
                        self.notes.append("The page tried to open a new window, which this browser blocked.")
                    } else {
                        self.notes.append("The page opened a new window for \(url); it was opened in this tab instead.")
                        self.view.loadURL(url)
                    }
                }
            }
        }
        await enableDomains()
    }

    /// Gives the page back to the person: dialogs and file pickers show again.
    func detach() async {
        guard attached else { return }
        attached = false
        view.dialogHandler = nil
        view.downloadHandler = nil
        view.blockedPopupHandler = nil
        if domainsOn {
            _ = try? await call("Page.setInterceptFileChooserDialog", ["enabled": false])
        }
        domainsOn = false
        inFlight.removeAll()
        chooser = nil
    }

    private func enableDomains() async {
        guard !domainsOn else { return }
        do {
            _ = try await call("Network.enable")
            _ = try await call("Page.enable")
            _ = try await call("DOM.enable")
            _ = try await call("Page.setInterceptFileChooserDialog", ["enabled": true])
            domainsOn = true
        } catch {
            // Without a browser yet (the window is still opening) there is nothing to enable;
            // the next request tries again.
        }
    }

    /// A DevTools event of one of the enabled domains.
    private func event(_ method: String, _ params: [String: Any]) {
        switch method {
        case "Network.requestWillBeSent":
            // A socket or an event stream stays open on purpose; it is not loading.
            let type = params["type"] as? String ?? ""
            if type == "WebSocket" || type == "EventSource" { return }
            if let id = params["requestId"] as? String { inFlight[id] = Date() }
        case "Network.loadingFinished", "Network.loadingFailed":
            if let id = params["requestId"] as? String { inFlight.removeValue(forKey: id) }
        case "Page.fileChooserOpened":
            chooser = params
        default:
            break
        }
    }

    /// Whether the page is waiting on a request, leaving out those open for too long.
    private var loading: Bool {
        let now = Date()
        inFlight = inFlight.filter { now.timeIntervalSince($0.value) < Self.staleRequest }
        return !inFlight.isEmpty
    }

    nonisolated private static func cut(_ text: String, _ max: Int) -> String {
        let one = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(one.prefix(max))
    }

    // MARK: Requests

    /// Answers one request line (already parsed) with the reply to send back.
    func handle(_ request: [String: Any]) async -> [String: Any] {
        var reply: [String: Any]
        do {
            await attach()
            switch request["cmd"] as? String {
            case "open":
                guard let url = request["url"] as? String else { throw AgentError("open needs a url") }
                await open(url)
                reply = ["ok": true]
            case "observe":
                let survey = request["survey"] as? Bool ?? false
                let focusYs = (request["focus"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                let spans = ((request["settled"] as? [String: Any])?["spans"] as? [[String: Any]]) ?? []
                reply = ["ok": true, "observation": try await observe(survey: survey, focusYs: focusYs, settledSpans: spans)]
            case "act":
                let actions = request["actions"] as? [[String: Any]] ?? []
                reply = ["ok": true, "results": await act(actions)]
            case "close":
                await detach()
                reply = ["ok": true]
            default:
                reply = ["ok": false, "error": "unknown command \(request["cmd"] as? String ?? "")"]
            }
        } catch {
            reply = ["ok": false, "error": "\(error)"]
        }
        reply["id"] = request["id"] ?? NSNull()
        return reply
    }

    // MARK: DevTools

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            view.sendDevToolsMethod(method, params: params) { success, result in
                if success {
                    continuation.resume(returning: (result as? [String: Any]) ?? [:])
                } else {
                    let message = ((result as? [String: Any])?["message"] as? String) ?? "the browser could not run \(method)"
                    continuation.resume(throwing: AgentError(message))
                }
            }
        }
    }

    /// Runs a page function, waiting out a navigation meanwhile: between two documents the
    /// context is destroyed or the new document has no element yet, and either fails it once.
    private func evaluate(_ expression: String) async throws -> Any? {
        var attempt = 0
        while true {
            do {
                let result = try await call("Runtime.evaluate", [
                    "expression": expression, "returnByValue": true, "awaitPromise": true,
                ])
                if let details = result["exceptionDetails"] as? [String: Any] {
                    let exception = details["exception"] as? [String: Any]
                    throw AgentError((exception?["description"] as? String) ?? (details["text"] as? String) ?? "the page function failed")
                }
                return (result["result"] as? [String: Any])?["value"]
            } catch {
                attempt += 1
                if attempt > Self.evaluateRetries { throw error }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    // MARK: Looking

    private func metrics() async throws -> [String: Any] {
        let value = try await evaluate("""
        (() => {
          const root = document.documentElement;
          if (!root) throw new Error('the page has no document yet');
          return { scrollX: window.scrollX, scrollY: window.scrollY,
                   pageWidth: root.scrollWidth, pageHeight: root.scrollHeight,
                   width: window.innerWidth, height: window.innerHeight,
                   ratio: window.devicePixelRatio || 1 };
        })()
        """)
        guard let dictionary = value as? [String: Any] else { throw AgentError("the page has no size yet") }
        return dictionary
    }

    /// A JPEG of what the page shows, as a data URL, one pixel to a CSS pixel so a point in the
    /// picture is a point to click.
    private func shot(_ m: [String: Any]? = nil) async throws -> String {
        let size: [String: Any]
        if let m { size = m } else { size = try await metrics() }
        let params: [String: Any] = [
            "format": "jpeg", "quality": Self.jpegQuality, "fromSurface": true,
            "clip": ["x": number(size["scrollX"]), "y": number(size["scrollY"]),
                     "width": number(size["width"]), "height": number(size["height"]),
                     // Chromium multiplies the scale by the screen's pixel ratio; undo that so
                     // the picture has one pixel to a CSS pixel.
                     "scale": 1 / max(number(size["ratio"]), 1)],
        ]
        var result: [String: Any]
        do {
            result = try await call("Page.captureScreenshot", params)
        } catch {
            // Chromium only paints a window that is on screen: bring it there and try again.
            if let window = view.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            try? await Task.sleep(for: .milliseconds(300))
            result = try await call("Page.captureScreenshot", params)
        }
        guard let data = result["data"] as? String else { throw AgentError("the browser returned no picture") }
        return "data:image/jpeg;base64," + data
    }

    /// Waits until the page has settled: no change to its DOM for a quarter second, no request
    /// of the page's still open, and the document loaded, within `cap` seconds. A menu still
    /// opening or a list still filling is not what the model should plan from.
    private func settled(cap: Double = AgentDriver.settleCap) async {
        let started = Date()
        while Date().timeIntervalSince(started) < cap {
            let left = min(max(cap - Date().timeIntervalSince(started), Self.quietMs / 1000), Self.maxQuietWait)
            let quiet = (try? await evaluate("""
            new Promise((resolve) => {
              let timer = setTimeout(() => done(true), \(Self.quietMs));
              const stop = setTimeout(() => done(false), \(Int(left * 1000)));
              const observer = new MutationObserver(() => {
                clearTimeout(timer);
                timer = setTimeout(() => done(true), \(Self.quietMs));
              });
              function done(result) {
                observer.disconnect(); clearTimeout(timer); clearTimeout(stop); resolve(result);
              }
              observer.observe(document, { childList: true, subtree: true, attributes: true, characterData: true });
            })
            """) as? Bool) ?? true
            let ready = ((try? await evaluate("document.readyState === 'complete'")) as? Bool) ?? false
            if quiet && ready && !view.isLoading && !loading { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func scrollTo(_ y: Double) async throws {
        _ = try await evaluate("window.scrollTo(window.scrollX, \(y))")
        await settled(cap: Self.scrollSettleCap)
    }

    /// Whether a control has the keyboard: typing goes somewhere.
    private func hasFocus() async -> Bool {
        let value = try? await evaluate("""
        (() => {
          const a = document.activeElement;
          if (!a || a === document.body || a === document.documentElement) return false;
          return a.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(a.tagName);
        })()
        """)
        return (value as? Bool) ?? false
    }

    /// The focused control as the page describes it, or nil.
    private func focus() async -> [String: Any]? {
        let value = try? await evaluate("""
        (() => {
          const a = document.activeElement;
          if (!a || a === document.body || a === document.documentElement) return null;
          const cut = (text, max) => (text || '').trim().replace(/\\s+/g, ' ').slice(0, max);
          const byId = a.getAttribute('aria-labelledby');
          const label = (a.labels && a.labels[0] && a.labels[0].innerText) || a.getAttribute('aria-label') ||
            (byId && document.getElementById(byId) && document.getElementById(byId).innerText) ||
            a.getAttribute('placeholder') || a.getAttribute('title') || a.getAttribute('name') || '';
          const tag = a.tagName.toLowerCase();
          const type = (a.type || '').toLowerCase();
          const out = { tag, type, label: cut(label, \(Self.maxLabel)) };
          if (tag === 'select') {
            out.options = Array.from(a.options).map((o) => cut(o.text, \(Self.maxLabel)));
            out.multiple = a.multiple;
            out.value = cut(a.selectedOptions[0] ? a.selectedOptions[0].text : '', \(Self.maxValue));
          } else if (type === 'checkbox' || type === 'radio') {
            out.checked = a.checked;
          } else if (type !== 'password' && 'value' in a) {
            out.value = cut(a.value, \(Self.maxValue));
          } else if (a.isContentEditable) {
            out.value = cut(a.innerText, \(Self.maxValue));
          }
          out.required = !!a.required;
          if (typeof a.checkValidity === 'function' && !a.checkValidity()) out.invalid = cut(a.validationMessage, \(Self.maxValue));
          return out;
        })()
        """)
        return value as? [String: Any]
    }

    private func open(_ url: String) async {
        do {
            let result = try await call("Page.navigate", ["url": url])
            if let error = result["errorText"] as? String {
                notes.append("The page did not finish loading: \(error)")
            }
        } catch {
            notes.append("The page did not finish loading: \(error)")
        }
        await settled(cap: Self.openCap)
    }

    private func observe(survey: Bool, focusYs: [Double], settledSpans: [[String: Any]]) async throws -> [String: Any] {
        await settled()
        let m = try await metrics()
        var observation: [String: Any] = [
            "screenshot": try await shot(m),
            "url": view.currentURL,
            "title": view.title,
            "viewport": [
                "width": number(m["width"]), "height": number(m["height"]),
                "scrollX": number(m["scrollX"]), "scrollY": number(m["scrollY"]),
                "pageWidth": number(m["pageWidth"]), "pageHeight": number(m["pageHeight"]),
            ],
            "notes": notes,
            "zoneShots": zoneShots,
        ]
        notes.removeAll()
        zoneShots.removeAll()
        if let focused = await focus() { observation["focus"] = focused }
        if survey { observation["survey"] = try await surveyScreens(m, focusYs: focusYs, settledSpans: settledSpans) }
        return observation
    }

    /// The whole page as screens from top to bottom, leaving out the parts the harness settled.
    private func surveyScreens(_ m: [String: Any], focusYs: [Double], settledSpans: [[String: Any]]) async throws -> [[String: Any]] {
        let height = number(m["height"])
        let last = max(0, number(m["pageHeight"]) - height)
        let step = max(1, height - Self.surveyOverlap)
        func inSettled(_ from: Double, _ to: Double) -> Bool {
            settledSpans.contains { number($0["from"]) <= from + 1 && number($0["to"]) >= to - 1 }
        }
        var tops: [Double] = []
        var y = 0.0
        while true {
            let top = min(y, last)
            if !inSettled(top, top + height) { tops.append(top) }
            if top >= last { break }
            y += step
        }
        for wanted in focusYs {
            let top = min(max(wanted - height / 2, 0), last)
            if !tops.contains(where: { abs($0 - top) <= Self.focusNear }) { tops.append(top) }
        }
        tops.sort()

        var screens: [[String: Any]] = []
        for top in tops {
            if let previous = screens.last, abs(number(previous["scrollY"]) - top) <= 1 { continue }
            try await scrollTo(top)
            let now = try await metrics()
            screens.append(["screenshot": try await shot(now), "scrollY": number(now["scrollY"])])
        }
        try await scrollTo(number(m["scrollY"]))
        return screens
    }

    // MARK: Acting

    /// Carries the actions out in order. A failure stops the batch (the rest is reported as not
    /// run); typing with nothing focused is a failure of that action only.
    private func act(_ actions: [[String: Any]]) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        var stopped: String?
        for (index, action) in actions.enumerated() {
            let id = action["id"] as? String ?? ""
            if let stopped {
                results.append(["id": id, "ok": false, "error": "not run: \(stopped)"])
                continue
            }
            do {
                if let target = action["scrollTo"] as? NSNumber {
                    let m = try await metrics()
                    let pageHeight = number(action["pageHeight"])
                    if pageHeight > 0 && abs(number(m["pageHeight"]) - pageHeight) > 12 {
                        throw ActionFailure(message: "the page is \(Int(number(m["pageHeight"]))) px tall now and was \(Int(pageHeight)) px when the point was measured")
                    }
                    if abs(number(m["scrollY"]) - target.doubleValue) > 1 { try await scrollTo(target.doubleValue) }
                }
                chooser = nil
                var result: [String: Any] = ["id": id, "ok": true]
                for (key, value) in try await doAction(action) { result[key] = value }
                // A plain click that opened the file picker: the browser held it back, and the
                // harness is told so it can plan an upload.
                if chooser != nil && action["kind"] as? String != "upload" {
                    chooser = nil
                    result["opened"] = "file_picker"
                }
                results.append(result)
            } catch let failure as ActionFailure {
                results.append(["id": id, "ok": false, "error": failure.message, "unreached": failure.unreached])
                if !failure.unreached { stopped = failure.message }
            } catch {
                results.append(["id": id, "ok": false, "error": "\(error)", "unreached": false])
                stopped = "\(error)"
            }

            // A zone's photo once its last action is done, for the harness to review on the side.
            let zone = Int(number(action["zone"]))
            let next = index + 1 < actions.count ? actions[index + 1] : nil
            if zone > 0 && (next == nil || Int(number(next?["zone"])) != zone) {
                await settled()
                if let m = try? await metrics(), let picture = try? await shot(m) {
                    zoneShots.append(["zone": zone, "screenshot": picture, "scrollY": number(m["scrollY"])])
                }
            }
        }
        return results
    }

    private func doAction(_ action: [String: Any]) async throws -> [String: Any] {
        let x = number(action["x"]), y = number(action["y"])
        switch action["kind"] as? String {
        case "click":
            try await click(x, y, count: 1)
        case "double_click":
            try await click(x, y, count: 2)
        case "triple_click":
            try await click(x, y, count: 3)
        case "right_click":
            try await click(x, y, count: 1, button: "right")
        case "hover":
            try await mouse("mouseMoved", x, y)
        case "type":
            guard await hasFocus() else {
                throw ActionFailure(message: "nothing has focus, so there is nowhere to type", unreached: true)
            }
            try await type(action["text"] as? String ?? "")
        case "key":
            let keys = (action["keys"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            for name in keys {
                let press: KeyPress
                do { press = try KeyPress.parse(name) } catch { throw ActionFailure(message: "\(error)") }
                for event in press.events() { _ = try await call("Input.dispatchKeyEvent", event) }
            }
        case "scroll":
            let m = try await metrics()
            let at = (x: (action["x"] as? NSNumber)?.doubleValue ?? number(m["width"]) / 2,
                      y: (action["y"] as? NSNumber)?.doubleValue ?? number(m["height"]) / 2)
            try await mouse("mouseMoved", at.x, at.y)
            _ = try await call("Input.dispatchMouseEvent", [
                "type": "mouseWheel", "x": at.x, "y": at.y,
                "deltaX": number(action["dx"]), "deltaY": number(action["dy"]),
            ])
            await settled(cap: Self.scrollSettleCap)
            return [:]
        case "upload":
            return try await upload(x, y, path: action["path"] as? String ?? "", name: action["fileName"] as? String ?? "")
        case "wait":
            let ms = min((action["ms"] as? NSNumber)?.doubleValue ?? 1000, Self.maxWaitMs)
            try? await Task.sleep(for: .milliseconds(Int(ms)))
            return [:]
        case let kind:
            throw ActionFailure(message: "the browser cannot do an action of kind \(kind ?? "(none)")")
        }
        await settled()
        return [:]
    }

    /// Clicks what opens the file picker, and hands the page the task's file in its place.
    private func upload(_ x: Double, _ y: Double, path: String, name: String) async throws -> [String: Any] {
        chooser = nil
        try await click(x, y, count: 1)
        let started = Date()
        while chooser == nil && Date().timeIntervalSince(started) < Self.chooserWait {
            try? await Task.sleep(for: .milliseconds(Self.pollMs))
        }
        guard let opened = chooser else {
            throw ActionFailure(message: "the click did not open a file picker")
        }
        chooser = nil
        if path.isEmpty { throw ActionFailure(message: "the task has no file to upload") }
        guard let nodeId = opened["backendNodeId"] as? NSNumber else {
            throw ActionFailure(message: "the browser did not say which control asked for the file")
        }
        _ = try await call("DOM.setFileInputFiles", ["files": [path], "backendNodeId": nodeId.intValue])
        await settled()
        return ["detail": "attached \(name.isEmpty ? path : name)"]
    }

    private func mouse(_ type: String, _ x: Double, _ y: Double, button: String = "none", count: Int = 0, buttons: Int = 0) async throws {
        _ = try await call("Input.dispatchMouseEvent", [
            "type": type, "x": x, "y": y, "button": button, "clickCount": count, "buttons": buttons,
        ])
    }

    private func click(_ x: Double, _ y: Double, count: Int, button: String = "left") async throws {
        let mask = button == "right" ? 2 : 1
        try await mouse("mouseMoved", x, y)
        for n in 1...count {
            try await mouse("mousePressed", x, y, button: button, count: n, buttons: mask)
            try await mouse("mouseReleased", x, y, button: button, count: n)
        }
    }

    /// Types into the focused control, a key at a time like a person, which pages that listen to
    /// keys expect. Characters a keyboard cannot type (Chinese, say) are inserted as text.
    private func type(_ text: String) async throws {
        for character in text {
            let string = String(character)
            let named = character.isNewline ? "Enter" : character == "\t" ? "Tab" : nil
            if let press = named.flatMap({ try? KeyPress.parse($0) }) ?? asciiPress(character) {
                for event in press.events() { _ = try await call("Input.dispatchKeyEvent", event) }
            } else {
                _ = try await call("Input.insertText", ["text": string])
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The key press that types a printable ASCII character, or nil for any other.
    private func asciiPress(_ character: Character) -> KeyPress? {
        guard let ascii = character.asciiValue, ascii >= 32, ascii < 127 else { return nil }
        guard let press = try? KeyPress.parse(String(character)), press.text != nil else { return nil }
        return press
    }
}
