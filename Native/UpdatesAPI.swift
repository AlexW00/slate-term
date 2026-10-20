import AppKit
import SlateTermCore

@MainActor
enum UpdateOperationScope {
    @TaskLocal static var current: WorkspaceOperationContext?
}

extension WorkspaceHost {
    static let updatesDescriptor = AutomationCapabilities.updates

    func makeUpdatesController() -> UpdateController {
        let controller = UpdateController()
        controller.nativeAction = { [weak self] action, updateID in self?.invokeNativeUpdate(action, updateID: updateID) }
        controller.restartConfirmed = { [weak self] in self?.layoutAppRestartConfirmed = true }
        controller.confirmInstallation = { [weak self] in
            guard let self else { return false }
            return ApplicationLaunchContext.current.isLayoutApp ? self.confirmUpdateInstallation() : self.confirmSettingsClose()
        }
        controller.onChange = { [weak self] before, after in
            guard let self else { return }
            self.refreshCommandPicker()
            self.settingsModel?.layoutAppUpdateStatus = ApplicationLaunchContext.current.isLayoutApp ? after.detail : nil
            // Publish semantic transitions, not every download chunk or release-note byte.
            guard before.phase != after.phase || before.release != after.release || before.windowVisible != after.windowVisible else { return }
            let visibilityOnly = before.phase == after.phase && before.release == after.release
            let operation = UpdateOperationScope.current ?? (visibilityOnly || ApplicationLaunchContext.current.isLayoutApp ? nil : self.updateEventOperation) ?? WorkspaceOperationContext(origin: .native)
            let payload: [String: JSONValue] = ["beforePhase": .string(before.phase.rawValue), "phase": .string(after.phase.rawValue),
                "revision": .string(after.revision), "updateId": after.updateID.map(JSONValue.string) ?? .null,
                "version": after.release.map { .string($0.version) } ?? .null, "windowVisible": .bool(after.windowVisible)]
            do { try self.events.publishOperation(operation.publication(topic: "host.updates.changed", payload: payload)) }
            catch { NSLog("Update state event could not be published; clients must read updates.get.") }
        }
        return controller
    }

    func callUpdates(_ action: UpdateAction, params: [String: JSONValue], operation: WorkspaceOperationContext) async throws -> JSONValue {
        let request = try UpdateRequest(action: action, params: params)
        let validate: @MainActor () throws -> Void = { [weak self] in
            guard let self else { throw CancellationError() }
            try self.validateUpdateOperation(action, params: params, operation: operation)
        }
        try validate()
        return try await UpdateOperationScope.$current.withValue(operation) {
            let before = updates.snapshot
            let after = try await updates.perform(request, validateCaller: validate)
            if [.check, .download, .install].contains(action), before.phase != after.phase { updateEventOperation = operation }
            if action == .cancel { updateEventOperation = nil }
            return try .encoding(after)
        }
    }
}
