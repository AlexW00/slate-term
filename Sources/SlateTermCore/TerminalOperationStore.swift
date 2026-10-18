import Foundation

public enum TerminalOperationState: String, CaseIterable, Encodable, Sendable {
    case awaitingInput, submitted, running, capturing
    case completed, rejected, interrupted, trackingLost, sessionLost

    public var isFinished: Bool {
        switch self {
        case .awaitingInput, .submitted, .running, .capturing: false
        case .completed, .rejected, .interrupted, .trackingLost, .sessionLost: true
        }
    }
}

public enum TerminalOperationFailure: String, CaseIterable, Encodable, Sendable {
    case editingBufferNotEmpty, submissionFailed, otherCommand, sessionLost
}

/// A session-owned handle. No caller identity, request continuation, command text,
/// or shell credential is exposed by status/list queries.
public struct TerminalOperationStatus: Encodable, Equatable, Sendable {
    public let commandId: UUID
    public let paneId: PaneID
    public let sessionId: String
    public fileprivate(set) var state: TerminalOperationState
    public fileprivate(set) var exitCode: Int?
    public fileprivate(set) var failure: TerminalOperationFailure?
}

/// A bounded screen observation at completion, not isolated stdout/stderr.
public struct TerminalOperationResult: Encodable, Equatable, Sendable {
    public let paneId: PaneID
    public let sessionId: String
    public let commandId: UUID
    public let exitCode: Int?
    public let text: String
    public let truncated: Bool
}

public enum TerminalOperationError: Error, Equatable, Sendable {
    case invalidCommand
    case alreadyRunning(PaneID)
    case capacity(limit: Int)
    case unavailable
    case alreadyClaimed
    case editingBufferNotEmpty
    case notReady
    case failed(TerminalOperationFailure)
    case closed
}

/// Bounded app-lifetime state. Starting adopts the work into its terminal session;
/// disconnecting or timing out a waiter never mutates this store. The host owns
/// authentication, actual I/O, wait deadlines and publication of these transitions.
public struct TerminalOperationStore: Sendable {
    public static let maximumCommandBytes = 16_384
    public static let maximumActive = 32
    public static let maximumRecords = 128
    public static let retention: Duration = .seconds(900)

    private struct Record: Sendable {
        var status: TerminalOperationStatus
        let command: String
        let prefix: String
        let line: String
        let created: ContinuousClock.Instant
        /// Reports up to this sequence were sent before the operation started.
        let baseline: Int?
        var runningSequence: Int?
        /// Prompts that arrived before the running report, oldest first.
        var prompts: [ShellReport] = []
        var expires: ContinuousClock.Instant?
        var result: TerminalOperationResult?
        var inputClaimed: Bool { status.state != .awaitingInput }
    }
    private var records: [UUID: Record] = [:]
    private var active: [PaneID: UUID] = [:]
    private var reserved = Set<PaneID>()
    private var closed = false

    public init() {}
    public var activeCount: Int { active.count }
    public var reservedCount: Int { reserved.count }
    public func displayCommand(pane: PaneID) -> String? { active[pane].flatMap { records[$0]?.command } }

    public mutating func reserve(_ panes: Set<PaneID>) throws {
        guard !closed else { throw TerminalOperationError.closed }
        guard panes.isDisjoint(with: reserved), panes.isDisjoint(with: active.keys),
              active.count + reserved.count + panes.count <= Self.maximumActive else {
            throw TerminalOperationError.capacity(limit: Self.maximumActive)
        }
        reserved.formUnion(panes)
    }
    public mutating func releaseReservation(_ pane: PaneID) { reserved.remove(pane) }

    /// The shell is frozen from the pane's authenticated report: the command is
    /// source code in that shell's language. `afterSequence` is the newest report
    /// sequence at start; later-arriving reports up to it belong to earlier commands.
    public mutating func start(pane: PaneID, sessionId: String, command: String, shell: ShellKind = .zsh, afterSequence: Int?,
                               usingReservation: Bool = false, now: ContinuousClock.Instant = .now) throws -> TerminalOperationStatus {
        guard !closed else { throw TerminalOperationError.closed }
        guard !command.isEmpty, !command.utf8.contains(0), command.utf8.count <= Self.maximumCommandBytes else {
            throw TerminalOperationError.invalidCommand
        }
        guard active[pane] == nil else { throw TerminalOperationError.alreadyRunning(pane) }
        if usingReservation {
            guard reserved.contains(pane) else { throw TerminalOperationError.unavailable }
        } else {
            guard !reserved.contains(pane) else { throw TerminalOperationError.alreadyRunning(pane) }
            guard active.count + reserved.count < Self.maximumActive else { throw TerminalOperationError.capacity(limit: Self.maximumActive) }
        }
        prune(now: now)
        if records.count >= Self.maximumRecords {
            // Never silently evict live work, including a reentrant screen capture.
            guard let oldest = orderedRecords().first(where: { $0.status.state.isFinished }) else {
                throw TerminalOperationError.capacity(limit: Self.maximumRecords)
            }
            records.removeValue(forKey: oldest.status.commandId)
        }
        if usingReservation { reserved.remove(pane) }
        let id = UUID()
        let status = TerminalOperationStatus(commandId: id, paneId: pane, sessionId: sessionId, state: .awaitingInput)
        records[id] = Record(status: status, command: command, prefix: shell.runMarker(id), line: shell.runLine(id, command: command),
                             created: now, baseline: afterSequence)
        active[pane] = id
        return status
    }

    /// Only the host's authenticated editor endpoint calls this. A stale session
    /// must not consume a successor's pending input, even when its pane ID is reused.
    public mutating func claimInput(pane: PaneID, sessionId: String, emptyBuffer: Bool,
                                    now: ContinuousClock.Instant = .now) throws -> String {
        guard let id = active[pane], var record = records[id], record.status.sessionId == sessionId else {
            throw TerminalOperationError.unavailable
        }
        guard record.status.state == .awaitingInput else { throw TerminalOperationError.alreadyClaimed }
        guard emptyBuffer else {
            finish(id, state: .rejected, failure: .editingBufferNotEmpty, now: now)
            throw TerminalOperationError.editingBufferNotEmpty
        }
        record.status.state = .submitted
        records[id] = record
        return record.line
    }

    /// Returns the handle whose screen must be captured. Release its pane first,
    /// then let the host capture outside this value mutation (capture may reenter).
    /// Finish with completeCapture; a replaced session cannot publish stale output.
    ///
    /// Reports travel on separate connections and can arrive out of order, so the
    /// host forwards late reports too. An operation completes on the first prompt
    /// after its running report; only the prompt numbered running + 1 carries its
    /// exit status, which every integrated shell guarantees.
    public mutating func observe(pane: PaneID, sessionId: String, report: ShellReport,
                                 now: ContinuousClock.Instant = .now) -> UUID? {
        guard let id = active[pane], var record = records[id] else { return nil }
        // The host forwards only the pane's current session. Another session's
        // report means this operation's shell was replaced.
        guard record.status.sessionId == sessionId else {
            finish(id, state: .sessionLost, failure: .sessionLost, now: now)
            return nil
        }
        if let baseline = record.baseline, report.sequence <= baseline { return nil }
        switch report.state {
        case .running:
            guard report.command?.hasPrefix(record.prefix) == true else {
                // A later command starts after this operation's prompt (running + 1), which may still be in flight.
                if let running = record.runningSequence, report.sequence > running + 1 { return nil }
                // The shell claims only at an empty primary prompt, so after a claim another
                // command's report belongs to one that finished before it; this operation still ran.
                if record.inputClaimed, report.sequence < (record.runningSequence ?? .max) { return nil }
                // Before the claim, another command means the user got there first.
                finish(id, state: .interrupted, failure: .otherCommand, now: now)
                return nil
            }
            record.runningSequence = report.sequence
            record.status.state = .running
            records[id] = record
            if let prompt = record.prompts.first(where: { $0.sequence > report.sequence }) {
                return beginCapture(id, prompt: prompt)
            }
        case .prompt:
            guard let running = record.runningSequence else {
                // The prompt overtook its running report; keep it until that report arrives.
                record.prompts.append(report)
                record.prompts.sort { $0.sequence < $1.sequence }
                records[id] = record
                return nil
            }
            guard report.sequence > running else { return nil }
            return beginCapture(id, prompt: report)
        }
        return nil
    }

    /// Only the immediate successor carries this operation's status. A later prompt that
    /// overtook it still ends the operation, without claiming another command's status.
    private mutating func beginCapture(_ id: UUID, prompt: ShellReport) -> UUID? {
        guard var record = records[id], let running = record.runningSequence else { return nil }
        record.status.state = .capturing
        record.status.exitCode = prompt.sequence == running + 1 ? prompt.exitCode : nil
        record.prompts = []
        records[id] = record
        if active[record.status.paneId] == id { active.removeValue(forKey: record.status.paneId) }
        return id
    }

    public mutating func completeCapture(_ id: UUID, text: String, now: ContinuousClock.Instant = .now) {
        guard var record = records[id], record.status.state == .capturing else { return }
        let output = TerminalOutput(text)
        record.result = TerminalOperationResult(paneId: record.status.paneId, sessionId: record.status.sessionId,
            commandId: id, exitCode: record.status.exitCode, text: output.text, truncated: output.truncated)
        records[id] = record
        finish(id, state: .completed, now: now)
    }

    public mutating func submissionFailed(_ id: UUID, now: ContinuousClock.Instant = .now) {
        guard let record = records[id] else { return }
        switch record.status.state {
        case .awaitingInput:
            finish(id, state: .rejected, failure: .submissionFailed, now: now)
        case .submitted:
            // The editor already claimed input: do not claim it never executed.
            finish(id, state: .trackingLost, failure: .submissionFailed, now: now)
        case .running, .capturing, .completed, .rejected, .interrupted, .trackingLost, .sessionLost:
            // An observed execution/outcome wins over a late delivery error.
            break
        }
    }

    public mutating func loseSession(pane: PaneID, sessionId: String, now: ContinuousClock.Instant = .now) {
        // A reservation may already prepare this pane's successor. Its authoritative
        // host owns releaseReservation; an old session-loss callback must not steal it.
        for (id, record) in records where record.status.paneId == pane && record.status.sessionId == sessionId && !record.status.state.isFinished {
            finish(id, state: .sessionLost, failure: .sessionLost, now: now)
        }
    }

    public mutating func close(now: ContinuousClock.Instant = .now) {
        closed = true
        reserved.removeAll()
        for (id, record) in records where !record.status.state.isFinished {
            finish(id, state: .sessionLost, failure: .sessionLost, now: now)
        }
    }

    public mutating func status(_ id: UUID, now: ContinuousClock.Instant = .now) throws -> TerminalOperationStatus {
        prune(now: now)
        guard let record = records[id] else { throw TerminalOperationError.unavailable }
        return record.status
    }
    public mutating func result(_ id: UUID, now: ContinuousClock.Instant = .now) throws -> TerminalOperationResult {
        let status = try status(id, now: now)
        if let failure = status.failure { throw TerminalOperationError.failed(failure) }
        guard let result = records[id]?.result, status.state == .completed else { throw TerminalOperationError.notReady }
        return result
    }
    public mutating func list(now: ContinuousClock.Instant = .now) -> [TerminalOperationStatus] {
        prune(now: now)
        return orderedRecords().map(\.status)
    }

    private mutating func finish(_ id: UUID, state: TerminalOperationState, failure: TerminalOperationFailure? = nil,
                                  now: ContinuousClock.Instant) {
        guard var record = records[id], !record.status.state.isFinished else { return }
        record.status.state = state
        record.status.failure = failure
        record.expires = now.advanced(by: Self.retention)
        records[id] = record
        if active[record.status.paneId] == id { active.removeValue(forKey: record.status.paneId) }
    }
    private mutating func prune(now: ContinuousClock.Instant) {
        records = records.filter { $0.value.expires.map { $0 > now } ?? true }
    }
    private func orderedRecords() -> [Record] {
        records.values.sorted {
            $0.created == $1.created ? $0.status.commandId.uuidString < $1.status.commandId.uuidString : $0.created < $1.created
        }
    }
}
