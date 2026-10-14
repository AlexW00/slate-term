extension Layout {
    /// Equal area, not equal divider fractions: three side-by-side panes each get a third.
    func equalized() -> Layout {
        switch self {
        case .pane: return self
        case .split(let axis, _, let first, let second):
            let fraction = Double(first.paneIDs.count) / Double(paneIDs.count)
            return .split(axis: axis, fraction: fraction, first: first.equalized(), second: second.equalized())
        }
    }

    public func neighbor(of pane: PaneID, direction: Direction) -> PaneID? {
        let frames = frames(in: Frame(x: 0, y: 0, width: 1, height: 1))
        guard let origin = frames.first(where: { $0.0 == pane })?.1 else { return nil }
        let horizontal = direction.axis == .horizontal
        let sign = direction.insertsBefore ? -1.0 : 1.0
        let candidates = frames.compactMap { id, frame -> (PaneID, Double, Double, Double)? in
            guard id != pane else { return nil }
            let distance = sign * (horizontal ? frame.centerX - origin.centerX : frame.centerY - origin.centerY)
            guard distance > 0.000001 else { return nil }
            let perpendicular = abs(horizontal ? frame.centerY - origin.centerY : frame.centerX - origin.centerX)
            let overlap = horizontal
                ? min(frame.y + frame.height, origin.y + origin.height) - max(frame.y, origin.y)
                : min(frame.x + frame.width, origin.x + origin.width) - max(frame.x, origin.x)
            // Prefer the directional corridor; diagonal neighbors are a fallback.
            return (id, overlap > 0.000001 ? 0 : 1, distance, perpendicular)
        }
        return candidates.min { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.2 != right.2 { return left.2 < right.2 }
            if left.3 != right.3 { return left.3 < right.3 }
            return left.0.number < right.0.number
        }?.0
    }

    private struct Frame {
        var x, y, width, height: Double
        var centerX: Double { x + width / 2 }
        var centerY: Double { y + height / 2 }
    }
    private func frames(in frame: Frame) -> [(PaneID, Frame)] {
        switch self {
        case .pane(let id): return [(id, frame)]
        case .split(let axis, let fraction, let first, let second):
            var leading = frame, trailing = frame
            if axis == .horizontal {
                leading.width *= fraction
                trailing.x += leading.width
                trailing.width -= leading.width
            } else {
                leading.height *= fraction
                trailing.y += leading.height
                trailing.height -= leading.height
            }
            return first.frames(in: leading) + second.frames(in: trailing)
        }
    }
}
