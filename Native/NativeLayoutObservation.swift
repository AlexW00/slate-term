import AppKit
import SlateTermCore

@MainActor
extension WorkspaceSplitController {
    /// Called after reapplying the desired fractions. Preserve them within one backing
    /// pixel, except where native constraints require a new feasible model fraction.
    func constrainedLayout(matching model: Layout) throws -> Layout {
        func unavailable() -> RPCFailure { RPCFailure(code: APIError.unavailable, message: "Native layout cannot represent the model within the leaf minimum") }
        func matchesRoundedPresentation(_ model: Layout, controller: NSViewController) -> Bool {
            let bounds = controller.view.bounds
            guard bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width >= LayoutSizing.minimumLeafExtent, bounds.height >= LayoutSizing.minimumLeafExtent else { return false }
            switch model {
            case .pane: return !(controller is WorkspaceSplitController)
            case .split(let axis, let fraction, let first, let second):
                guard let split = controller as? WorkspaceSplitController, split.splitViewItems.count == 2,
                      split.splitView.isVertical == (axis == .horizontal), fraction.isFinite, fraction > 0, fraction < 1 else { return false }
                let available = Double(axis == .horizontal ? bounds.width : bounds.height) - split.splitView.dividerThickness
                let frame = split.splitViewItems[0].viewController.view.frame
                let actual = Double(axis == .horizontal ? frame.width : frame.height)
                let tolerance = Double(1 / (controller.view.window?.backingScaleFactor ?? 1))
                return available > 0 && abs(actual - available * fraction) <= tolerance
                    && matchesRoundedPresentation(first, controller: split.splitViewItems[0].viewController)
                    && matchesRoundedPresentation(second, controller: split.splitViewItems[1].viewController)
            }
        }
        func observe(_ model: Layout, controller: NSViewController, projected: NSSize) throws -> Layout {
            let bounds = controller.view.bounds
            guard bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width >= LayoutSizing.minimumLeafExtent, bounds.height >= LayoutSizing.minimumLeafExtent else { throw unavailable() }
            // Preserve rounding-only branches even when a sibling genuinely needs
            // normalization. Carry the original full-tree projection, not rounded local
            // bounds; ancestor range checks still protect the final projected minima.
            if matchesRoundedPresentation(model, controller: controller) {
                let frames = PaneMoveGeometry.frames(for: model, in: NSRect(origin: .zero, size: projected), divider: splitView.dividerThickness)
                if frames.values.allSatisfy({ $0.width >= LayoutSizing.minimumLeafExtent && $0.height >= LayoutSizing.minimumLeafExtent }) { return model }
            }
            switch model {
            case .pane:
                guard !(controller is WorkspaceSplitController) else { throw unavailable() }
                return model
            case .split(let axis, let fraction, let first, let second):
                guard let split = controller as? WorkspaceSplitController, split.splitViewItems.count == 2,
                      split.splitView.isVertical == (axis == .horizontal) else { throw unavailable() }
                let divider = Double(split.splitView.dividerThickness)
                let projectedAvailable = Double(axis == .horizontal ? projected.width : projected.height) - divider
                let projectedFirst = projectedAvailable * fraction
                let projectedSecond = projectedAvailable - projectedFirst
                let firstSize = axis == .horizontal ? NSSize(width: projectedFirst, height: projected.height) : NSSize(width: projected.width, height: projectedFirst)
                let secondSize = axis == .horizontal ? NSSize(width: projectedSecond, height: projected.height) : NSSize(width: projected.width, height: projectedSecond)
                let leading = try observe(first, controller: split.splitViewItems[0].viewController, projected: firstSize)
                let trailing = try observe(second, controller: split.splitViewItems[1].viewController, projected: secondSize)
                let candidate = Layout.split(axis: axis, fraction: fraction, first: leading, second: trailing)
                let range = try LayoutSizing.resizeRange(of: candidate, in: .init(width: bounds.width, height: bounds.height), divider: divider)
                let available = Double(axis == .horizontal ? bounds.width : bounds.height) - divider
                let frame = split.splitViewItems[0].viewController.view.frame
                let actual = Double(axis == .horizontal ? frame.width : frame.height)
                guard actual.isFinite, actual > 0, actual < available else { throw unavailable() }
                let tolerance = Double(1 / (controller.view.window?.backingScaleFactor ?? 1))
                let proposed = abs(actual - available * fraction) <= tolerance ? fraction : actual / available
                // Child constraints can require an inward adjustment even when native pixel
                // rounding made the parent's old fraction look close enough.
                let feasible = min(max(proposed, range.lowerBound), range.upperBound)
                return .split(axis: axis, fraction: feasible, first: leading, second: trailing)
            }
        }
        let observed = try observe(model, controller: self, projected: view.bounds.size)
        let frames = PaneMoveGeometry.frames(for: observed, in: view.bounds, divider: splitView.dividerThickness)
        guard frames.values.allSatisfy({ $0.width >= LayoutSizing.minimumLeafExtent && $0.height >= LayoutSizing.minimumLeafExtent }) else { throw unavailable() }
        return observed
    }
}
