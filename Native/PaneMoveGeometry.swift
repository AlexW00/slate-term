import AppKit
import SlateTermCore

/// Predict the committed split geometry in bottom-up window coordinates, including dividers.
/// Used for size validation, not the target-local insertion cue shown during a drag.
enum PaneMoveGeometry {
    static func frames(for layout: Layout, in rect: NSRect, divider: CGFloat) -> [PaneID: NSRect] {
        switch layout {
        case .pane(let pane): return [pane: rect]
        case .split(let axis, let fraction, let first, let second):
            var leading = rect, trailing = rect
            if axis == .horizontal {
                let available = max(0, rect.width - divider)
                leading.size.width = available * fraction
                trailing.origin.x = leading.maxX + divider
                trailing.size.width = available - leading.width
            } else {
                let available = max(0, rect.height - divider)
                leading.size.height = available * fraction
                leading.origin.y = rect.maxY - leading.height
                trailing.size.height = available - leading.height
            }
            return frames(for: first, in: leading, divider: divider)
                .merging(frames(for: second, in: trailing, divider: divider)) { first, _ in first }
        }
    }
}
