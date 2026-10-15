import Testing
@testable import SlateTermCore

@Test func onlyExplicitReadsAndAuthenticatedIntegrationAreExempt() {
    for method in ["api.describe", "events.poll", "workspace.snapshot", "terminal.capture", "terminal.wait", "plugins.settings.get", "web.get", "web.snapshot", "web.wait"] {
        #expect(AdmissionAction.forMethod(method) == .read)
    }
    for method in ["command.run", "terminal.run", "terminal.send", "browser.eval", "browser.screenshot", "web.click", "web.fill", "web.select", "web.scroll", "web.screenshot", "web.eval", "storage.set", "events.emit", "plugin.example.get", "unknown.get"] {
        #expect(AdmissionAction.forMethod(method) == .mutation)
    }
    #expect(AdmissionAction.forMethod("shell.update") == .authenticatedIntegration)
    #expect(AdmissionAction.forMethod("shell.runInput") == .authenticatedIntegration)
    #expect(AdmissionAction.forMethod("shell.unknown") == .mutation)
}
