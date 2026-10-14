import Foundation

/// Horizontal places children left/right; vertical places them top/bottom.
public enum Axis: String, Codable, Sendable { case horizontal, vertical }
public enum Branch: String, Codable, Sendable { case first, second }
public enum Direction: String, CaseIterable, Codable, Sendable {
    case left, right, up, down
    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    public var insertsBefore: Bool { self == .left || self == .up }
}

public indirect enum Layout: Equatable, Codable, Sendable {
    case pane(PaneID)
    /// Fraction of available space assigned to the first child, excluding the divider.
    case split(axis: Axis, fraction: Double, first: Layout, second: Layout)

    public var paneIDs: [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    func replacing(_ target: PaneID, with replacement: Layout) -> Layout {
        switch self {
        case .pane(let id): id == target ? replacement : self
        case .split(let axis, let fraction, let first, let second):
            .split(axis: axis, fraction: fraction,
                   first: first.replacing(target, with: replacement),
                   second: second.replacing(target, with: replacement))
        }
    }

    func removing(_ target: PaneID) -> Layout? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let axis, let fraction, let first, let second):
            let left = first.removing(target)
            let right = second.removing(target)
            switch (left, right) {
            case (nil, let survivor), (let survivor, nil): return survivor
            case (.some(let left), .some(let right)):
                return .split(axis: axis, fraction: fraction, first: left, second: right)
            }
        }
    }

    func resized(path: ArraySlice<Branch>, fraction: Double) throws -> Layout {
        guard case .split(let axis, let oldFraction, let first, let second) = self else {
            throw WorkspaceError.invalidLayout("Resize path addresses a pane, not a split")
        }
        guard let branch = path.first else {
            return .split(axis: axis, fraction: fraction, first: first, second: second)
        }
        switch branch {
        case .first:
            return .split(axis: axis, fraction: oldFraction,
                          first: try first.resized(path: path.dropFirst(), fraction: fraction), second: second)
        case .second:
            return .split(axis: axis, fraction: oldFraction, first: first,
                          second: try second.resized(path: path.dropFirst(), fraction: fraction))
        }
    }

    func checkedPaneIDs(depth: Int = 0) throws -> [PaneID] {
        guard depth <= 64 else { throw WorkspaceError.invalidLayout("Split depth exceeds 64") }
        switch self {
        case .pane(let id): return [id]
        case .split(_, let fraction, let first, let second):
            guard fraction.isFinite, fraction > 0, fraction < 1 else {
                throw WorkspaceError.invalidLayout("Split fractions must be finite and between 0 and 1")
            }
            return try first.checkedPaneIDs(depth: depth + 1) + second.checkedPaneIDs(depth: depth + 1)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, pane, axis, fraction, first, second }
    private enum Kind: String, Codable { case pane, split }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pane: self = .pane(try container.decode(PaneID.self, forKey: .pane))
        case .split:
            self = .split(axis: try container.decode(Axis.self, forKey: .axis),
                          fraction: try container.decode(Double.self, forKey: .fraction),
                          first: try container.decode(Layout.self, forKey: .first),
                          second: try container.decode(Layout.self, forKey: .second))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(id, forKey: .pane)
        case .split(let axis, let fraction, let first, let second):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(axis, forKey: .axis)
            try container.encode(fraction, forKey: .fraction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}
