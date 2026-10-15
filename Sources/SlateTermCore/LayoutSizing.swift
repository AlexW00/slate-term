/// Shared point-space leaf constraints. Descendant fractions remain fixed during a
/// divider preview: counting leaves alone would permit an asymmetric child to collapse.
public enum LayoutSizing {
    public static let minimumLeafExtent = 80.0

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
    }

    public static func minimumSize(of layout: Layout, divider: Double) throws -> Size {
        guard divider.isFinite, divider >= 0 else { throw invalid() }
        return try minimumSize(of: layout, divider: divider, depth: 0)
    }

    /// Inclusive legal first-child fractions, excluding the divider. The orthogonal
    /// extent must also fit every descendant; no primary-axis drag can repair it.
    public static func resizeRange(of layout: Layout, in size: Size, divider: Double) throws -> ClosedRange<Double> {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              divider.isFinite, divider >= 0,
              case .split(let axis, let fraction, let first, let second) = layout else { throw invalid() }
        try validate(fraction)
        let a = try minimumSize(of: first, divider: divider, depth: 1)
        let b = try minimumSize(of: second, divider: divider, depth: 1)
        let horizontal = axis == .horizontal
        let available = (horizontal ? size.width : size.height) - divider
        let perpendicular = horizontal ? size.height : size.width
        guard available > 0, perpendicular >= max(horizontal ? a.height : a.width, horizontal ? b.height : b.width) else { throw invalid() }
        let leading = horizontal ? a.width : a.height
        let trailing = horizontal ? b.width : b.height
        // Search representable fractions against the exact forward projection. Subtracting
        // nearly equal extents can otherwise exclude a legal exact fit or round below 80.
        let candidates = Double.leastNonzeroMagnitude...Double(1).nextDown
        let lower = try firstFeasible(in: candidates) { available * $0 >= leading }
        let upper = try lastFeasible(in: candidates) { available - available * $0 >= trailing }
        guard lower <= upper else { throw invalid() }
        return lower...upper
    }

    private static func minimumSize(of layout: Layout, divider: Double, depth: Int) throws -> Size {
        guard depth <= 64 else { throw invalid() }
        switch layout {
        case .pane: return Size(width: minimumLeafExtent, height: minimumLeafExtent)
        case .split(let axis, let fraction, let first, let second):
            try validate(fraction)
            let a = try minimumSize(of: first, divider: divider, depth: depth + 1)
            let b = try minimumSize(of: second, divider: divider, depth: depth + 1)
            let horizontal = axis == .horizontal
            let leading = horizontal ? a.width : a.height
            let trailing = horizontal ? b.width : b.height
            let total = try firstFeasible(in: max(divider, leading, trailing)...Double.greatestFiniteMagnitude) {
                let available = $0 - divider
                return available * fraction >= leading && available - available * fraction >= trailing
            }
            return horizontal ? Size(width: total, height: max(a.height, b.height))
                : Size(width: max(a.width, b.width), height: total)
        }
    }

    // Positive finite IEEE-754 bit patterns preserve numerical order. Each search uses
    // at most 63 iterations, regardless of pixel distance or cancellation plateaus. The
    // forward projections are monotone over representable positive extents/fractions.
    private static func firstFeasible(in range: ClosedRange<Double>, _ fits: (Double) -> Bool) throws -> Double {
        guard fits(range.upperBound) else { throw invalid() }
        var low = range.lowerBound.bitPattern, high = range.upperBound.bitPattern
        while low < high {
            let middle = low + (high - low) / 2
            if fits(Double(bitPattern: middle)) { high = middle } else { low = middle + 1 }
        }
        return Double(bitPattern: low)
    }

    private static func lastFeasible(in range: ClosedRange<Double>, _ fits: (Double) -> Bool) throws -> Double {
        guard fits(range.lowerBound) else { throw invalid() }
        var low = range.lowerBound.bitPattern, high = range.upperBound.bitPattern
        while low < high {
            let middle = low + (high - low) / 2 + 1
            if fits(Double(bitPattern: middle)) { low = middle } else { high = middle - 1 }
        }
        return Double(bitPattern: low)
    }

    private static func validate(_ fraction: Double) throws {
        guard fraction.isFinite, fraction > 0, fraction < 1 else { throw invalid() }
    }
    private static func invalid() -> WorkspaceError {
        .invalidLayout("Layout cannot preserve its fractions within the finite geometry and 80-point leaf minimum")
    }
}
