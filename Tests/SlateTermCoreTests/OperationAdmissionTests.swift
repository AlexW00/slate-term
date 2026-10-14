import Foundation
import Testing
@testable import SlateTermCore

private let admissionEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let viewIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private func audience(document: UUID = viewIdentity, plugin: String = "tools") -> CausationAudience {
    .plugin(epoch: admissionEpoch, registrationID: plugin, instanceID: "instance-1", viewID: viewIdentity, documentGeneration: document)
}
private func cursor(_ sequence: Int) -> String { "\(admissionEpoch.uuidString):\(sequence)" }

@Test func causalReferencesBindDocumentAndEpochAndExpireWithoutDowngrading() throws {
    var store = try CausationReferences(epoch: admissionEpoch, lifetimeMilliseconds: 100)
    let root = OperationLineage()
    let token = try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 10)
    let child = try store.derive(from: token, audience: audience(), now: 109)
    #expect(child.parentOperationID == root.operationID)
    #expect(child.rootOperationID == root.operationID && child.depth == 1)
    let foreign: [CausationAudience] = [
        audience(document: UUID()), audience(plugin: "other"),
        .plugin(epoch: admissionEpoch, registrationID: "tools", instanceID: "other", viewID: viewIdentity, documentGeneration: viewIdentity),
        .plugin(epoch: admissionEpoch, registrationID: "tools", instanceID: "instance-1", viewID: UUID(), documentGeneration: viewIdentity),
        .plugin(epoch: UUID(), registrationID: "tools", instanceID: "instance-1", viewID: viewIdentity, documentGeneration: viewIdentity),
        .administrative(epoch: admissionEpoch), .administrative(epoch: UUID())
    ]
    for recipient in foreign {
        #expect(throws: OperationAdmissionError.contextUnavailable) { try store.derive(from: token, audience: recipient, now: 109) }
    }
    // Repeated delivery does not extend the original maximum lifetime.
    #expect(try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 109) == token)
    #expect(throws: OperationAdmissionError.contextUnavailable) {
        try store.derive(from: token, audience: audience(), now: 110)
    }
    // Accepted work retains immutable lineage independently of reference expiry.
    #expect(child.depth == 1 && child.rootOperationID == root.operationID)
}

@Test func causalSiblingFanoutAndReplayPreserveDepth() throws {
    var store = try CausationReferences(epoch: admissionEpoch, lifetimeMilliseconds: 100)
    let root = OperationLineage()
    let token = try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 0)
    #expect(try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 1) == token)
    let first = try store.derive(from: token, audience: audience(), now: 2)
    let sibling = try store.derive(from: token, audience: audience(), now: 2)
    #expect(first.operationID != sibling.operationID && first.depth == sibling.depth)
    var lineage = first
    for sequence in 2...8 {
        let reference = try store.issue(for: audience(), eventCursor: cursor(sequence), lineage: lineage, now: 3)
        lineage = try store.derive(from: reference, audience: audience(), now: 3)
    }
    #expect(lineage.depth == 8)
    let last = try store.issue(for: audience(), eventCursor: cursor(9), lineage: lineage, now: 4)
    #expect(throws: OperationAdmissionError.depthExceeded) { try store.derive(from: last, audience: audience(), now: 5) }
    let replay = try store.issue(for: audience(), eventCursor: cursor(9), lineage: lineage, now: 104)
    #expect(replay != last)
    #expect(throws: OperationAdmissionError.depthExceeded) { try store.derive(from: replay, audience: audience(), now: 104) }
}

@Test func referencesBoundGlobalAndRecipientRetentionAndAdministrativeLifetime() throws {
    var store = try CausationReferences(epoch: admissionEpoch, maximumReferences: 3, maximumPerAudience: 2)
    let root = OperationLineage()
    let oldest = try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 0)
    _ = try store.issue(for: audience(), eventCursor: cursor(2), lineage: root, now: 0)
    _ = try store.issue(for: audience(), eventCursor: cursor(3), lineage: root, now: 0)
    #expect(store.count == 2)
    #expect(throws: OperationAdmissionError.contextUnavailable) { try store.derive(from: oldest, audience: audience(), now: 0) }
    let admin = CausationAudience.administrative(epoch: admissionEpoch)
    let token = try store.issue(for: admin, eventCursor: cursor(4), lineage: root, now: 0)
    _ = try store.issue(for: audience(plugin: "other"), eventCursor: cursor(5), lineage: root, now: 0)
    #expect(store.count == 3)
    // Administrative references intentionally survive the originating connection.
    #expect(try store.derive(from: token, audience: .administrative(epoch: admissionEpoch), now: 1).depth == 1)
    #expect(throws: OperationAdmissionError.contextUnavailable) { try store.derive(from: "forged", audience: admin, now: 1) }
    #expect(throws: OperationAdmissionError.invalidContext) {
        try store.issue(for: admin, eventCursor: "\(UUID().uuidString):1", lineage: root, now: 1)
    }
}

@Test func referenceTokenCollisionIsBoundedAndDoesNotEvictValidReferences() throws {
    var store = try CausationReferences(epoch: admissionEpoch, maximumReferences: 1, maximumPerAudience: 1,
                                       makeToken: { "fixed-token" })
    let root = OperationLineage()
    let token = try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 0)
    #expect(throws: OperationAdmissionError.tokenUnavailable) {
        try store.issue(for: audience(), eventCursor: cursor(2), lineage: root, now: 0)
    }
    #expect(store.count == 1)
    #expect(try store.derive(from: token, audience: audience(), now: 0).parentOperationID == root.operationID)
}

@Test func automationBucketsAggregatePluginViewsAndLeaveRecoveryAndNativeControlsAvailable() throws {
    var admission = try MutationAdmission()
    for _ in 0..<20 { try admission.admit(.plugin("tools"), now: 0) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 100)) {
        try admission.admit(.plugin("tools"), now: 0)
    }
    for _ in 0..<200 {
        try admission.admit(.native, now: 0)
        try admission.admit(.plugin("tools"), action: .read, now: 0)
        try admission.admit(.plugin("tools"), action: .emergencyControl, now: 0)
    }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 1)) {
        try admission.admit(.plugin("tools"), now: 99)
    }
    try admission.admit(.plugin("tools"), now: 100)
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 100)) {
        try admission.admit(.plugin("tools"), now: 100)
    }
}

@Test func globalAdmissionIncludesAdministrativeRootsAndDenialsAreAtomic() throws {
    var admission = try MutationAdmission()
    for _ in 0..<100 { try admission.admit(.administrative, now: 0) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 10)) {
        try admission.admit(.plugin("tools"), now: 0)
    }
    // A global denial must not charge or allocate the plugin's bucket.
    #expect(admission.trackedPlugins == 0)
    for _ in 0..<20 { try admission.admit(.plugin("tools"), now: 1_000) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 100)) {
        try admission.admit(.plugin("tools"), now: 1_000)
    }
    try admission.admit(.administrative, now: 1_000)
    #expect(throws: OperationAdmissionError.clockRegressed) { try admission.admit(.administrative, now: 999) }
}

@Test func pluginAdmissionStateIsBoundedWithoutResettingActiveBudgets() throws {
    var admission = try MutationAdmission(maximumPlugins: 2)
    try admission.admit(.plugin("one"), now: 0)
    try admission.admit(.plugin("two"), now: 0)
    #expect(throws: OperationAdmissionError.trackingCapacity) { try admission.admit(.plugin("three"), now: 0) }
    #expect(admission.trackedPlugins == 2)
    // Only fully replenished idle buckets may be discarded for a new identity.
    try admission.admit(.plugin("three"), now: 100)
    #expect(admission.trackedPlugins == 2)
}

@Test func referencePolicyIdentityTokenAndClockBoundariesFailClosed() throws {
    for (total, perAudience, lifetime) in [(0, 1, UInt64(1)), (4097, 1, 1), (1, 0, 1), (1, 257, 1), (1, 1, 0), (1, 1, 300001)] {
        #expect(throws: OperationAdmissionError.invalidPolicy) {
            try CausationReferences(epoch: admissionEpoch, maximumReferences: total, maximumPerAudience: perAudience, lifetimeMilliseconds: lifetime)
        }
    }
    #expect(throws: OperationAdmissionError.invalidPolicy) { try MutationAdmission(maximumPlugins: 0) }
    #expect(throws: OperationAdmissionError.invalidPolicy) { try MutationAdmission(maximumPlugins: 257) }
    var store = try CausationReferences(epoch: admissionEpoch, lifetimeMilliseconds: 100)
    let root = OperationLineage()
    for recipient in [audience(plugin: String(repeating: "a", count: 65)), audience(plugin: "bad id"),
                      .plugin(epoch: admissionEpoch, registrationID: "tools", instanceID: String(repeating: "a", count: 257), viewID: viewIdentity, documentGeneration: viewIdentity)] {
        #expect(throws: OperationAdmissionError.invalidContext) { try store.issue(for: recipient, eventCursor: cursor(1), lineage: root, now: 0) }
    }
    #expect(store.count == 0)
    #expect(throws: OperationAdmissionError.invalidContext) {
        try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: UInt64.max - 99)
    }
    let token = try store.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: UInt64.max - 100)
    #expect(throws: OperationAdmissionError.clockRegressed) { try store.derive(from: token, audience: audience(), now: 0) }
    #expect(try store.derive(from: token, audience: audience(), now: UInt64.max - 1).depth == 1)
    #expect(throws: OperationAdmissionError.contextUnavailable) { try store.derive(from: token, audience: audience(), now: UInt64.max) }
    for invalid in ["", "contains whitespace", String(repeating: "a", count: 65)] {
        var broken = try CausationReferences(epoch: admissionEpoch, makeToken: { invalid })
        #expect(throws: OperationAdmissionError.tokenUnavailable) { try broken.issue(for: audience(), eventCursor: cursor(1), lineage: root, now: 0) }
        #expect(broken.count == 0)
    }
}

@Test func pluginAndTrackingDenialsNeverConsumeGlobalCredits() throws {
    var limited = try MutationAdmission()
    for _ in 0..<20 { try limited.admit(.plugin("tools"), now: 0) }
    for _ in 0..<20 {
        #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 100)) { try limited.admit(.plugin("tools"), now: 0) }
    }
    for _ in 0..<80 { try limited.admit(.administrative, now: 0) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 10)) { try limited.admit(.administrative, now: 0) }

    var bounded = try MutationAdmission(maximumPlugins: 1)
    try bounded.admit(.plugin("one"), now: 0)
    for _ in 0..<20 {
        #expect(throws: OperationAdmissionError.trackingCapacity) { try bounded.admit(.plugin("two"), now: 0) }
    }
    for _ in 0..<19 { try bounded.admit(.plugin("one"), now: 0) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 100)) { try bounded.admit(.plugin("one"), now: 0) }
    for _ in 0..<80 { try bounded.admit(.administrative, now: 0) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 10)) { try bounded.admit(.administrative, now: 0) }
}

@Test func globalRefillIsExactAndLongIdleCannotAccumulateBeyondBurst() throws {
    var admission = try MutationAdmission()
    for _ in 0..<100 { try admission.admit(.administrative, now: 0) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 1)) { try admission.admit(.administrative, now: 9) }
    try admission.admit(.administrative, now: 10)
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 10)) { try admission.admit(.administrative, now: 10) }
    for _ in 0..<100 { try admission.admit(.administrative, now: UInt64.max) }
    #expect(throws: OperationAdmissionError.rateLimited(retryAfterMilliseconds: 10)) { try admission.admit(.administrative, now: UInt64.max) }
}
