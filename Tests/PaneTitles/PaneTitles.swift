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
        func pane(_ id: Int, type: String, typeID: String) -> PaneContainer {
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
            let pane = PaneContainer(content: content, type: type, typeID: typeID, paneID: PaneID(id))
            pane.onRename = { [weak pane] in pane?.setTitle($0) }
            root.addChild(pane)
            root.view.addSubview(pane.view)
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            return pane
        }
        let left = pane(1, type: "Terminal", typeID: "terminal")
        let right = pane(2, type: "Browser", typeID: "browser")
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
            try require(number("titleTrailingX") <= number("copyIDLeadingX") - 5.5, "Title overlaps copy control: \(info)")
            try require(number("titleTrailingX") > number("titleLeadingX"), "Title editing region collapsed")
            for key in ["copyIDVisible", "closeVisible", "dragHandleVisible"] {
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
        try left.editTitleForTesting("Saved on blur", finish: "blur")
        try require(left.info.object!["title"] == .string("Saved on blur"), "Blur failed")
        left.setTitle("")
        try check(left)
        try require(left.copyIDForTesting() == "p1" && right.copyIDForTesting() == "p2", "Copy ID regressed")
        print("PASS production pane header: true full-width centering, safe symmetric bounds at 250/500/750 points and collapse at 80 points, Unicode/empty/live titles, commit/cancel/blur, copy IDs and light/dark/inline native renders")
    }
}
