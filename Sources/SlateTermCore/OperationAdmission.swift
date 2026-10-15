import Foundation

/// Host-owned lineage, never decoded from a caller's claimed provenance.
/// Accepted asynchronous work keeps this value independently of delivery-reference expiry.
public struct OperationLineage: Equatable, Sendable {
    public let operationID: UUID
    public let rootOperationID: UUID
    public let parentOperationID: UUID?
    public let depth: Int

    public init(operationID: UUID = UUID()) {
        self.operationID = operationID
        rootOperationID = operationID
        parentOperationID = nil
        depth = 0
    }

    fileprivate init(parent: OperationLineage) {
        operationID = UUID()
        rootOperationID = parent.rootOperationID
        parentOperationID = parent.operationID
        depth = parent.depth + 1
    }
}

/// Private delivery audience, not event routing or serialized provenance. Document generation
/// is a host lifetime identifier, not a bridge credential. Administrators are same-user callers;
/// their references intentionally are not bound to an ephemeral Unix connection.
public enum CausationAudience: Hashable, Sendable {
    case administrative(epoch: UUID)
    case plugin(epoch: UUID, registrationID: String, instanceID: String, viewID: UUID, documentGeneration: UUID)
    case service(epoch: UUID, registrationID: String, recipient: ServiceEventRecipient)

    fileprivate var epoch: UUID {
        switch self {
        case .administrative(let epoch), .plugin(let epoch, _, _, _, _), .service(let epoch, _, _): return epoch
        }
    }

    fileprivate var isBounded: Bool {
        switch self {
        case .administrative: return true
        case .plugin(_, let registration, let instance, _, _):
            return boundedAdmissionIdentity(registration, maximum: 64) && boundedAdmissionIdentity(instance, maximum: 256)
        case .service(_, let registration, _):
            return boundedAdmissionIdentity(registration, maximum: 64)
        }
    }
}

public enum OperationAdmissionError: Error, Equatable, Sendable {
    case invalidPolicy, invalidContext, contextUnavailable, depthExceeded, tokenUnavailable
    case clockRegressed, trackingCapacity
    case rateLimited(retryAfterMilliseconds: UInt64)
}

/// A bounded host-private cache. Eviction can precede the maximum TTL: a reference is not a lease.
/// Monotonic milliseconds are supplied by the host; tests do not need wall-clock sleeps.
public struct CausationReferences: Sendable {
    public static let maximumDepth = 8
    private let epoch: UUID
    private let maximumReferences: Int
    private let maximumPerAudience: Int
    private let lifetime: UInt64
    private let makeToken: @Sendable () -> String
    private var records: [Record] = []
    private var lastTime: UInt64 = 0
    public var count: Int { records.count }

    public init(epoch: UUID, maximumReferences: Int = 4_096, maximumPerAudience: Int = 256,
                lifetimeMilliseconds: UInt64 = 300_000,
                makeToken: @escaping @Sendable () -> String = { UUID().uuidString }) throws {
        guard (1...4_096).contains(maximumReferences), (1...256).contains(maximumPerAudience),
              (1...300_000).contains(lifetimeMilliseconds) else { throw OperationAdmissionError.invalidPolicy }
        self.epoch = epoch
        self.maximumReferences = maximumReferences
        self.maximumPerAudience = maximumPerAudience
        lifetime = lifetimeMilliseconds
        self.makeToken = makeToken
    }

    public mutating func issue(for audience: CausationAudience, eventCursor: String,
                               lineage: OperationLineage, now: UInt64) throws -> String {
        guard audience.epoch == epoch, audience.isBounded,
              let cursor = try? EventCursor(parsing: eventCursor), cursor.epoch == epoch,
              now <= UInt64.max - lifetime else { throw OperationAdmissionError.invalidContext }
        try expire(at: now)
        if let existing = records.first(where: { $0.audience == audience && $0.eventCursor == eventCursor && $0.lineage == lineage }) {
            return existing.token
        }
        // Generate before capacity eviction; a faulty generator cannot destroy valid references.
        var token: String?
        for _ in 0..<4 {
            let candidate = makeToken()
            if isValidCausationToken(candidate), !records.contains(where: { $0.token == candidate }) { token = candidate; break }
        }
        guard let token else { throw OperationAdmissionError.tokenUnavailable }
        if records.lazy.filter({ $0.audience == audience }).count >= maximumPerAudience,
           let index = records.firstIndex(where: { $0.audience == audience }) { records.remove(at: index) }
        if records.count >= maximumReferences { records.removeFirst() }
        records.append(Record(token: token, audience: audience, eventCursor: eventCursor,
                              lineage: lineage, expiresAt: now + lifetime))
        return token
    }

    /// Siblings reuse their parent reference; a later delivery of their own event advances depth.
    /// Missing, forged, expired and foreign-audience references deliberately share one error.
    public mutating func derive(from token: String, audience: CausationAudience, now: UInt64) throws -> OperationLineage {
        try expire(at: now)
        guard isValidCausationToken(token), audience.epoch == epoch,
              let record = records.first(where: { $0.token == token && $0.audience == audience }) else {
            throw OperationAdmissionError.contextUnavailable
        }
        guard record.lineage.depth < Self.maximumDepth else { throw OperationAdmissionError.depthExceeded }
        return OperationLineage(parent: record.lineage)
    }

    private mutating func expire(at now: UInt64) throws {
        guard now >= lastTime else { throw OperationAdmissionError.clockRegressed }
        lastTime = now
        records.removeAll { $0.expiresAt <= now }
    }

    private struct Record: Sendable {
        let token: String
        let audience: CausationAudience
        let eventCursor: String
        let lineage: OperationLineage
        let expiresAt: UInt64
    }
}

/// The host derives both classifications. Never accept these enums from request parameters.
public enum MutationOrigin: Equatable, Sendable {
    case native, administrative, plugin(String)
}
public enum AdmissionAction: Sendable {
    case mutation, read, emergencyControl, authenticatedIntegration

    /// Explicit reads only: an arbitrary contributed command name never grants exemption.
    public static func forMethod(_ method: String) -> Self {
        // These handlers still require the private terminal-session credential. Run-input
        // delivery belongs to an already admitted terminal.run, not a second mutation.
        if method == "shell.update" || method == "shell.runInput" { return .authenticatedIntegration }
        if ["service.ready", "plugins.service.stop", "plugins.service.disable"].contains(method) { return .emergencyControl }
        let reads: Set<String> = ["version", "api.describe", "context.get", "context.inspect", "workspace.get", "workspace.snapshot",
            "layout.get", "tabs.list", "panes.list", "pane.inspect", "window.list", "window.get", "command.list",
            "terminal.capture", "terminal.wait", "panes.capture", "events.head", "events.poll", "settings.get", "storage.get",
            "config.get", "config.validate", "palette.list", "plugins.list", "plugins.status", "plugins.logs", "plugins.settings.get",
            "browser.get", "browser.snapshot", "browser.wait", "web.get", "web.snapshot", "web.wait",
            "plugins.service.list", "plugins.service.status", "plugins.service.logs"]
        return reads.contains(method) ? .read : .mutation
    }
}

/// Token buckets aggregate all documents/views for a plugin ID. Global capacity also covers
/// administrative roots. Classify/charge once at outer admission, not again during shared dispatch.
/// Side effects that later fail (and successful no-ops) do not refund an admitted token.
public struct MutationAdmission: Sendable {
    private let maximumPlugins: Int
    private var global: Bucket?
    private var plugins: [String: Bucket] = [:]
    private var lastTime: UInt64 = 0
    public var trackedPlugins: Int { plugins.count }

    public init(maximumPlugins: Int = 256) throws {
        guard (1...256).contains(maximumPlugins) else { throw OperationAdmissionError.invalidPolicy }
        self.maximumPlugins = maximumPlugins
    }

    public mutating func admit(_ origin: MutationOrigin, action: AdmissionAction = .mutation, now: UInt64) throws {
        guard action == .mutation, origin != .native else { return }
        guard now >= lastTime else { throw OperationAdmissionError.clockRegressed }
        var nextGlobal = (global ?? Bucket(burst: 100, tokenCost: 10, now: now)).refilled(at: now)
        let pluginID: String?
        if case .plugin(let id) = origin {
            guard boundedAdmissionIdentity(id, maximum: 64) else { throw OperationAdmissionError.invalidContext }
            pluginID = id
        } else { pluginID = nil }
        var nextPlugin = pluginID.map { (plugins[$0] ?? Bucket(burst: 20, tokenCost: 100, now: now)).refilled(at: now) }
        let retry = max(nextGlobal.retryAfter, nextPlugin?.retryAfter ?? 0)
        guard retry == 0 else { throw OperationAdmissionError.rateLimited(retryAfterMilliseconds: retry) }
        var evicted: String?
        if let pluginID, plugins[pluginID] == nil, plugins.count == maximumPlugins {
            // Do not reset partially spent buckets on unregister/re-register churn. Only an
            // already fully replenished bucket can be forgotten without granting extra capacity.
            evicted = plugins.keys.sorted().first { plugins[$0]!.refilled(at: now).isFull }
            guard evicted != nil else { throw OperationAdmissionError.trackingCapacity }
        }
        nextGlobal.consume()
        nextPlugin?.consume()
        global = nextGlobal
        lastTime = now
        if let evicted { plugins.removeValue(forKey: evicted) }
        if let pluginID, let nextPlugin { plugins[pluginID] = nextPlugin }
    }

    /// Integer millisecond credits avoid rounding errors at exact refill boundaries.
    private struct Bucket: Sendable {
        let capacity: UInt64
        let tokenCost: UInt64
        var credits: UInt64
        var timestamp: UInt64
        var isFull: Bool { credits == capacity }
        var retryAfter: UInt64 { credits < tokenCost ? tokenCost - credits : 0 }

        init(burst: UInt64, tokenCost: UInt64, now: UInt64) {
            capacity = burst * tokenCost
            self.tokenCost = tokenCost
            credits = capacity
            timestamp = now
        }
        func refilled(at now: UInt64) -> Bucket {
            var next = self
            next.credits += min(now - timestamp, capacity - credits)
            next.timestamp = now
            return next
        }
        mutating func consume() { credits -= tokenCost }
    }
}

private func boundedAdmissionIdentity(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
}
