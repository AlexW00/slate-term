import AppKit
import SlateTermCore

extension WorkspaceHost {
    static let updatesDescriptor = AutomationCapabilities.updates

    func makeUpdatesController() -> UpdateController {
        let controller = UpdateController()
        controller.nativeAction = { [weak self] action, updateID in self?.invokeNativeUpdate(action, updateID: updateID) }
        controller.confirmInstallation = { [weak self] in self?.confirmUpdateInstallation() ?? false }
        controller.onChange = { [weak self] before, after in
            guard let self else { return }
            self.refreshCommandPicker()
            // Publish semantic transitions, not every download chunk or release-note byte.
            guard before.phase != after.phase || before.release != after.release || before.windowVisible != after.windowVisible else { return }
            let visibilityOnly = before.phase == after.phase && before.release == after.release
            let operation = self.updateImmediateOperation ?? (visibilityOnly ? nil : self.updateEventOperation) ?? WorkspaceOperationContext(origin: .native)
            let payload: [String: JSONValue] = ["beforePhase": .string(before.phase.rawValue), "phase": .string(after.phase.rawValue),
                "revision": .string(after.revision), "updateId": after.updateID.map(JSONValue.string) ?? .null,
                "version": after.release.map { .string($0.version) } ?? .null, "windowVisible": .bool(after.windowVisible)]
            do { try self.events.publishOperation(operation.publication(topic: "host.updates.changed", payload: payload)) }
            catch { NSLog("Update state event could not be published; clients must read updates.get.") }
        }
        return controller
    }

    func callUpdates(_ action: UpdateAction, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        let request = try UpdateRequest(action: action, params: params)
        try operation.validateCaller()
        let previous = updateImmediateOperation
        updateImmediateOperation = operation
        defer { updateImmediateOperation = previous }
        let before = updates.snapshot
        let after = try updates.perform(request, validateCaller: operation.validateCaller)
        if [.check, .download, .install].contains(action), before.phase != after.phase { updateEventOperation = operation }
        if action == .cancel { updateEventOperation = nil }
        return try .encoding(after)
    }
}
