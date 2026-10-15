import Testing
@testable import SlateTermCore

@Test func serviceRecoveryIsExemptWithoutExemptingOrdinaryOrContributedMutations() throws {
    var admission = try MutationAdmission()
    for _ in 0..<100 { try admission.admit(.administrative, now: 0) }
    for method in ["service.ready", "plugins.service.stop", "plugins.service.disable"] {
        #expect(AdmissionAction.forMethod(method) == .emergencyControl)
        try admission.admit(.plugin("controller"), action: .forMethod(method), now: 0)
    }
    for method in ["plugins.service.list", "plugins.service.status", "plugins.service.logs"] {
        #expect(AdmissionAction.forMethod(method) == .read)
        try admission.admit(.administrative, action: .forMethod(method), now: 0)
    }
    for method in ["plugins.service.start", "plugins.service.restart", "plugins.service.enable", "plugin.service.start", "plugin.service.stop"] {
        #expect(AdmissionAction.forMethod(method) == .mutation)
        #expect(throws: OperationAdmissionError.self) {
            try admission.admit(.administrative, action: .forMethod(method), now: 0)
        }
    }
}
