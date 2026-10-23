import Foundation

/// Notes a view whose hover turns on and off faster than a hand moves a pointer. That is a
/// view whose hover changes the layout under the pointer, and the changed layout changes the
/// hover back: SwiftUI hit-tests the whole window on every turn, and the window stops
/// answering for seconds. The note goes to perf.log with the stalls it explains.
@MainActor
enum HoverWatch {
    private static let limit = 20
    private static var flips: [String: (start: Date, count: Int)] = [:]

    /// One turn of `view`'s hover, on or off.
    static func flipped(_ view: String) {
        let now = Date()
        var entry = flips[view] ?? (now, 0)
        if now.timeIntervalSince(entry.start) > 1 { entry = (now, 0) }
        entry.count += 1
        if entry.count == limit {
            ChromiumPerf.note("hover on \(view) turned \(limit) times within a second")
        }
        flips[view] = entry
    }
}
