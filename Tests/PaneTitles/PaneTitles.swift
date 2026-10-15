import AppKit
import SlateTermCore

/// Exercises the production header independently of terminal/plugin runtime dependencies.
@main
struct PaneTitlesGate {
    @MainActor static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pane Header Verification"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 260))
        window.contentViewController = root
        func pane(type: String, typeID: String) -> PaneContainer {
            let content = NSViewController()
            let label = NSTextField(labelWithString: "\(type) content fixture")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            content.view = NSView()
            content.view.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.view.centerYAnchor),
            ])
            let pane = PaneContainer(content: content, type: type, typeID: typeID)
            pane.onRename = { [weak pane] in pane?.setTitle($0) }
            root.addChild(pane)
            root.view.addSubview(pane.view)
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            return pane
        }
        let left = pane(type: "Terminal", typeID: "terminal")
        let right = pane(type: "Browser", typeID: "browser")
        let leftWidth = left.view.widthAnchor.constraint(equalToConstant: 500)
        NSLayoutConstraint.activate([
            leftWidth,
            left.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            left.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            left.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            right.view.leadingAnchor.constraint(equalTo: left.view.trailingAnchor),
            right.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            right.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            right.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        func settle() {
            root.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        func check(_ pane: PaneContainer) throws {
            settle()
            let info = pane.info.object!
            func number(_ key: String) -> Double {
                guard case .number(let number) = info[key] else { fatalError("Missing geometry: \(key)") }
                return number
            }
            try require(info["titleCentered"] == .bool(true), "Title text not center aligned")
            try require(abs(number("titleCenterX") - number("headerWidth") / 2) < 0.5, "Title off-center across full pane")
            try require(number("titleLeadingX") >= number("typeTrailingX") + 7.5, "Title overlaps type control: \(info)")
            try require(number("titleTrailingX") <= number("actionsLeadingX") - 5.5, "Title overlaps header actions: \(info)")
            try require(number("titleTrailingX") > number("titleLeadingX"), "Title editing region collapsed")
            for key in ["actionsBeforeClose", "closeVisible", "dragHandleVisible"] {
                try require(info[key] == .bool(true), "Hidden header control: \(key)")
            }
        }
        let artifacts = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        func capture(_ name: String) throws {
            settle()
            guard let bitmap = root.view.bitmapImageRepForCachingDisplay(in: root.view.bounds) else {
                throw NSError(domain: "Native header capture unavailable", code: 1)
            }
            root.view.cacheDisplay(in: root.view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "PNG capture unavailable", code: 1)
            }
            try png.write(to: artifacts.appendingPathComponent("pane-titles-native-\(name).png"))
        }
        settle()
        // Unlike the app host, the fixture has no terminal to take initial keyboard focus.
        window.makeFirstResponder(nil)
        left.setTitle("Build")
        right.setTitle("Documentation")
        left.setActive(true)
        right.setActive(false)
        try require(left.info.object!["dimmed"] == .bool(false), "Active pane must stay undimmed")
        try require(right.info.object!["dimmed"] == .bool(true), "Inactive pane must be dimmed")
        let point = right.content.view.convert(NSPoint(x: 20, y: 20), to: right.view)
        try require(right.view.hitTest(point) !== right.view.subviews.last, "Dim overlay must not intercept input")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try check(left)
            try check(right)
            try capture(name)
        }
        let longTitle = "A deliberately long panel title — 日本語 — " + String(repeating: "long title ", count: 20)
        left.setTitle(longTitle)
        for width in [250.0, 750.0, 500.0] {
            leftWidth.constant = width
            try check(left)
            try check(right)
            if width == 250 { try capture("narrow-long") }
        }
        // The app permits 80-point split children: no title can fit around fixed controls.
        leftWidth.constant = 80
        settle()
        let minimum = left.info.object!
        guard case .number(let minimumCenter) = minimum["titleCenterX"],
              case .number(let minimumLeading) = minimum["titleLeadingX"],
              case .number(let minimumTrailing) = minimum["titleTrailingX"] else {
            throw NSError(domain: "Missing minimum-width geometry", code: 1)
        }
        try require(abs(minimumCenter - 40) < 0.5 && minimumTrailing - minimumLeading < 0.5,
                    "Minimum-width title must collapse without moving off-center")
        try capture("minimum-width")
        leftWidth.constant = 500
        left.setTitle("Build")
        try left.editTitleForTesting("Cancelled draft", finish: nil)
        try require(left.info.object!["draft"] == .string("Cancelled draft"), "Draft did not open")
        try check(left)
        try capture("editing")
        left.setTitle("Live title update")
        try require(left.info.object!["draft"] == .string("Cancelled draft"), "Live title clobbered draft")
        try left.editTitleForTesting(nil, finish: "cancel")
        try require(left.info.object!["title"] == .string("Live title update"), "Cancel lost live title")
        try left.editTitleForTesting("Committed", finish: "commit")
        try require(left.info.object!["title"] == .string("Committed"), "Commit failed")
        try left.editTitleForTesting("Discarded on blur", finish: "blur")
        try require(left.info.object!["title"] == .string("Committed"), "Outside dismissal must cancel")
        try require(left.info.object!["editing"] == .bool(false), "Dismissed popover stayed open")
        left.setTitle("")
        try check(left)
        var invoked: [Int] = []
        let initialActions = (0..<5).map { index in
            PaneHeaderAction(id: "action\(index)", title: "Action \(index)", symbol: "bolt", enabled: index != 1, revision: UUID(), perform: { invoked.append(index) })
        }
        left.setHeaderActions(initialActions)
        try check(left)
        try require(left.info.object!["visibleHeaderActions"] == .array([.string("action0"), .string("action1"), .string("action2"), .string("overflow")]), "Header overflow missing")
        try left.clickHeaderActionForTesting("action0")
        try left.clickHeaderActionForTesting("action1")
        try left.clickHeaderActionForTesting("action4")
        try require(invoked == [0, 4], "Direct/overflow/disabled action dispatch incorrect")
        let unchangedMenu = left.headerActionMenu()
        left.setHeaderActions(initialActions)
        unchangedMenu.performActionForItem(at: 0)
        try require(invoked == [0, 4, 3], "An unchanged refresh must preserve open menu actions")
        let unrelatedMenu = left.headerActionMenu()
        left.setHeaderActions(initialActions.map { action in
            PaneHeaderAction(id: action.id, title: action.title, symbol: action.symbol, enabled: action.id == "action0" ? false : action.enabled, revision: action.revision, perform: action.perform)
        })
        unrelatedMenu.performActionForItem(at: 0)
        try require(invoked == [0, 4, 3, 3], "An unrelated busy-state change must preserve valid menu actions")
        let staleMenu = left.headerActionMenu()
        left.setHeaderActions((0..<5).map { index in
            PaneHeaderAction(id: "action\(index)", title: "Replacement \(index)", symbol: "bolt", enabled: true, revision: UUID(), perform: { invoked.append(100 + index) })
        })
        staleMenu.performActionForItem(at: 0)
        try require(invoked == [0, 4, 3, 3], "A stale menu must not execute a replacement action")
        try left.clickHeaderActionForTesting("action4")
        try require(invoked == [0, 4, 3, 3, 104], "Replacement action should execute from the new menu")
        try capture("actions")
        leftWidth.constant = 250
        try check(left)
        try require(left.info.object!["visibleHeaderActions"] == .array([.string("overflow")]), "Narrow header must use overflow")
        try capture("actions-narrow")
        leftWidth.constant = 80
        settle()
        try require(left.info.object!["visibleHeaderActions"] == .array([]), "Minimum-width header must preserve Close without overflowing")
        leftWidth.constant = 500
        left.setHeaderActions([])
        try check(left)
        try require(left.info.object!["visibleHeaderActions"] == .array([]), "Removed contributions remain visible")
        print("PASS production pane header: centered titles, safe bounds at 250/500/750 points and collapse at 80, Unicode/live titles, commit/cancel/blur, command-backed buttons/overflow/disabled actions/removal and native renders")
    }
}
