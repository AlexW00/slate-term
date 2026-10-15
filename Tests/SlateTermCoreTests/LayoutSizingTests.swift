import Testing
@testable import SlateTermCore

private func split(_ axis: Axis, _ fraction: Double, _ first: Layout = .pane(PaneID(1)), _ second: Layout = .pane(PaneID(2))) -> Layout {
    .split(axis: axis, fraction: fraction, first: first, second: second)
}

@Test func dividerSizingPreservesDescendantFractionsRatherThanOnlyCountingLeaves() throws {
    let child = split(.horizontal, 0.2)
    let minimum = try LayoutSizing.minimumSize(of: child, divider: 1)
    #expect(abs(minimum.width - 401) < 0.000001)
    #expect(minimum.height == 80)
    #expect(smallest(child, minimum, 1) >= 80)
    #expect(smallest(child, .init(width: minimum.width.nextDown, height: minimum.height), 1) < 80)
    let root = split(.horizontal, 0.5, child, .pane(PaneID(3)))
    let range = try LayoutSizing.resizeRange(of: root, in: .init(width: 1001, height: 200), divider: 1)
    #expect(abs(range.lowerBound - 0.401) < 0.000001)
    #expect(abs(range.upperBound - 0.92) < 0.000001)
    #expect(throws: WorkspaceError.self) { try LayoutSizing.resizeRange(of: root, in: .init(width: 1001, height: 79), divider: 1) }
    let vertical = split(.vertical, 0.5, split(.vertical, 0.2), .pane(PaneID(3)))
    #expect(try LayoutSizing.resizeRange(of: vertical, in: .init(width: 200, height: 1001), divider: 1) == range)
}

@Test func dividerSizingIncludesEveryDividerAndMixedAxisConstraint() throws {
    let layout = split(.horizontal, 0.5, split(.vertical, 0.25), .pane(PaneID(3)))
    let minimum = try LayoutSizing.minimumSize(of: layout, divider: 2)
    #expect(minimum.width == 162 && minimum.height == 322)
    let exact = try LayoutSizing.resizeRange(of: layout, in: minimum, divider: 2)
    #expect(exact == 0.5...0.5)
    #expect(throws: WorkspaceError.self) { try LayoutSizing.resizeRange(of: layout, in: .init(width: 162, height: 321.99), divider: 2) }
    #expect(throws: WorkspaceError.self) { try LayoutSizing.resizeRange(of: layout, in: .init(width: 161.99, height: 322), divider: 2) }
}

@Test func dividerSizingAcceptsCancellationSensitiveExactFitAndAsymmetricMinimum() throws {
    for axis in [Axis.horizontal, .vertical] {
        let exact = split(axis, 0.5, .pane(PaneID(1)), split(axis, 0.2, .pane(PaneID(2)), .pane(PaneID(3))))
        let size = LayoutSizing.Size(width: axis == .horizontal ? 480 : 80, height: axis == .vertical ? 480 : 80)
        let range = try LayoutSizing.resizeRange(of: exact, in: size, divider: 0)
        #expect(range.contains(1.0 / 6))
    }
}

@Test func dividerSizingAcceptsRepresentableAsymmetricMinimum() throws {
    for axis in [Axis.horizontal, .vertical] {
        let asymmetric = split(axis, 0.99, .pane(PaneID(1)), split(axis, 0.35, .pane(PaneID(2)), .pane(PaneID(3))))
        let minimum = try LayoutSizing.minimumSize(of: asymmetric, divider: 0)
        #expect(max(minimum.width, minimum.height) <= 23000)
        #expect(smallest(asymmetric, minimum, 0) >= 80)
        var predecessor = minimum
        if axis == .horizontal { predecessor.width = predecessor.width.nextDown }
        else { predecessor.height = predecessor.height.nextDown }
        #expect(smallest(asymmetric, predecessor, 0) < 80)
    }
}

@Test func dividerSizingAcceptsDepth64AndRejects65() throws {
    var layout = Layout.pane(PaneID(1))
    for index in 2...65 { layout = split(.vertical, 0.5, layout, .pane(PaneID(index))) }
    let minimum = try LayoutSizing.minimumSize(of: layout, divider: 0)
    #expect(smallest(layout, minimum, 0) >= 80)
    layout = split(.vertical, 0.5, layout, .pane(PaneID(66)))
    #expect(throws: WorkspaceError.self) { try LayoutSizing.minimumSize(of: layout, divider: 0) }
}

@Test func dividerSizingRejectsInvalidUnrepresentableAndDeepGeometry() throws {
    for divider in [-1.0, .nan, .infinity] {
        #expect(throws: WorkspaceError.self) { try LayoutSizing.minimumSize(of: .pane(PaneID(1)), divider: divider) }
    }
    for fraction in [0.0, 1.0, -1.0, .nan, .infinity, .leastNonzeroMagnitude] {
        #expect(throws: WorkspaceError.self) { try LayoutSizing.minimumSize(of: split(.horizontal, fraction), divider: 1) }
    }
    for width in [0.0, -1.0, .nan, .infinity] {
        #expect(throws: WorkspaceError.self) { try LayoutSizing.resizeRange(of: split(.horizontal, 0.5), in: .init(width: width, height: 200), divider: 1) }
    }
    #expect(throws: WorkspaceError.self) { try LayoutSizing.resizeRange(of: .pane(PaneID(1)), in: .init(width: 200, height: 200), divider: 1) }
    var deep = Layout.pane(PaneID(1))
    for index in 2...67 { deep = split(.vertical, 0.5, deep, .pane(PaneID(index))) }
    #expect(throws: WorkspaceError.self) { try LayoutSizing.minimumSize(of: deep, divider: 1) }
}

private func smallest(_ layout: Layout, _ size: LayoutSizing.Size, _ divider: Double) -> Double {
        switch layout {
        case .pane: return min(size.width, size.height)
        case .split(let axis, let fraction, let first, let second):
            var a = size, b = size
            if axis == .horizontal {
                let available = size.width - divider
                a.width = available * fraction; b.width = available - a.width
            } else {
                let available = size.height - divider
                a.height = available * fraction; b.height = available - a.height
            }
            return min(smallest(first, a, divider), smallest(second, b, divider))
        }
}

@Test func dividerRangeEndpointsAgreeWithIndependentLeafProjection() throws {
    for axis in [Axis.horizontal, .vertical] {
        for fraction in [0.1, 0.2, 1.0 / 3, 0.5, 0.8, 0.9] {
            for divider in [0.0, 0.5, 1.0, 2.0] {
                let first = split(axis, fraction)
                let second = split(axis == .horizontal ? .vertical : .horizontal, 1 - fraction, .pane(PaneID(3)), .pane(PaneID(4)))
                let root = split(axis, 0.5, first, second)
                let size = LayoutSizing.Size(width: 4000, height: 3000)
                let range = try LayoutSizing.resizeRange(of: root, in: size, divider: divider)
                for value in [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound] {
                    let candidate = split(axis, value, first, second)
                    #expect(smallest(candidate, size, divider) >= 80)
                }
                for value in [range.lowerBound.nextDown, range.upperBound.nextUp, range.lowerBound - 1e-6, range.upperBound + 1e-6] {
                    #expect(smallest(split(axis, value, first, second), size, divider) < 80)
                }
            }
        }
    }
}
