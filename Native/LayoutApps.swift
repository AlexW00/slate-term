import AppKit
import CryptoKit
import Security
import SlateTermCore
import SlateTermSettings

/// The parent owns this index. Each app owns its separate workspace and runtime lease.
@MainActor
final class LayoutApps {
    nonisolated struct Record: Codable, Equatable, Sendable {
        var layoutAppID: UUID
        var layoutID: UUID
        var name: String
        var path: String
        var shellCodeHash: String
    }
    let parentBase: URL
    let parentConfigURL: URL
    var onChange: ((String, [String: JSONValue], WorkspaceOperationContext) -> Void)?
    private var attemptedRefreshes = Set<String>()
    private var mutationBusy = false
    private var automaticRefreshBusy = false
    private var catchUpNotBefore: [String: TimeInterval] = [:]
    private var catchingUp = false
    private var closed = false
    private struct Inspection {
        let record: Record
        let candidateExists: Bool
        let value: JSONValue
    }
    private var inspections: [String: Inspection] = [:]
    private var inspectionTokens: [String: UUID] = [:]
    private var watchers: [String: DirectoryTreeWatcher] = [:]
    private var launchObservers: [NSObjectProtocol] = []
    private var pendingLaunches: [String: NSRunningApplication] = [:]
    private var launchTokens: [String: UUID] = [:]
    private var debugCreationPauseArmed = false
    private var debugCreationContinuation: CheckedContinuation<Void, Never>?
    private var debugCreationPaths: [String: JSONValue] = [:]

    func debugCreationPause(_ action: String) throws -> JSONValue {
        guard ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] == "1" else {
            throw RPCFailure(code: -32601, message: "Integration testing is unavailable")
        }
        switch action {
        case "arm":
            guard !closed else { throw CancellationError() }
            guard !debugCreationPauseArmed, debugCreationContinuation == nil, !mutationBusy else {
                throw RPCFailure(code: APIError.conflict, message: "A layout app creation pause or operation is already pending")
            }
            debugCreationPauseArmed = true
        case "status": break
        case "release": releaseDebugCreationPause()
        default: throw RPCFailure(code: -32602, message: "Expected arm, status, or release")
        }
        return .object([
            "phase": .string(debugCreationContinuation != nil ? "paused" : debugCreationPauseArmed ? "armed" : "idle"),
            "stage": debugCreationPaths["stage"] ?? .null,
            "base": debugCreationPaths["base"] ?? .null,
            "destination": debugCreationPaths["destination"] ?? .null
        ])
    }

    private func pausePreparedCreationForTesting(stage: URL, base: URL, destination: URL) async {
        guard debugCreationPauseArmed, !closed else { return }
        debugCreationPauseArmed = false
        debugCreationPaths = ["stage": .string(stage.path), "base": .string(base.path), "destination": .string(destination.path)]
        // Cancellation stays pending until release, so tests can inspect ownership before cleanup.
        await withCheckedContinuation { debugCreationContinuation = $0 }
    }

    private func releaseDebugCreationPause() {
        debugCreationPauseArmed = false
        debugCreationPaths.removeAll()
        let continuation = debugCreationContinuation
        debugCreationContinuation = nil
        continuation?.resume()
    }

    func close() {
        closed = true
        releaseDebugCreationPause()
        launchObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        launchObservers.removeAll()
        pendingLaunches.removeAll()
        launchTokens.removeAll()
        catchUpNotBefore.removeAll()
        watchers.values.forEach { $0.close() }
        watchers.removeAll()
        inspections.removeAll()
        inspectionTokens.removeAll()
    }

    private func beginMutation() throws {
        guard !closed else { throw CancellationError() }
        guard !mutationBusy else {
            let message = automaticRefreshBusy
                ? "Slate Terminal is automatically refreshing a layout app. Try again when it finishes."
                : "Another layout app creation or refresh is in progress. Try again when it finishes."
            throw RPCFailure(code: APIError.conflict, message: message)
        }
        mutationBusy = true
    }

    nonisolated private static func work<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await BlockingIOExecutor.run(body)
    }

    private func invalidate(_ path: String) {
        guard !closed else { return }
        inspections.removeValue(forKey: path)
        inspectionTokens[path] = UUID()
    }

    private func observe(_ path: String) {
        guard !closed, watchers[path] == nil else { return }
        inspectionTokens[path] = UUID()
        watchers[path] = try? DirectoryTreeWatcher(url: URL(fileURLWithPath: path)) { [weak self] in
            self?.invalidate(path)
        }
    }
    static var shellRuntimeABI: Int? {
        let value = RuntimeBundle.bundle.object(forInfoDictionaryKey: "SlateRuntimeABI")
        return (value as? NSNumber)?.intValue ?? Int(value as? String ?? "")
    }
    private var indexURL: URL { parentBase.appendingPathComponent("state/layout-apps.json") }
    init(parentBase: URL, parentConfigURL: URL) {
        self.parentBase = parentBase
        self.parentConfigURL = parentConfigURL
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            launchObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.closed,
                          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          let identifier = app.bundleIdentifier, identifier.hasPrefix("com.slateterm.layoutapp.") else { return }
                    if notification.name == NSWorkspace.willLaunchApplicationNotification {
                        self.pendingLaunches[identifier] = app
                        self.launchTokens[identifier] = UUID()
                    } else {
                        self.pendingLaunches.removeValue(forKey: identifier)
                        if notification.name == NSWorkspace.didTerminateApplicationNotification {
                            let now = ProcessInfo.processInfo.systemUptime
                            self.catchUpNotBefore = self.catchUpNotBefore.filter { $0.value > now }
                            // Give the restart helper time to launch before automatic refresh takes ownership.
                            self.catchUpNotBefore[identifier] = now + 10
                        }
                    }
                }
            })
        }
    }

    isolated deinit { close() }

    private func identifier(_ record: Record) -> String {
        "com.slateterm.layoutapp.\(record.layoutAppID.uuidString.lowercased())"
    }

    private func records() throws -> [Record] {
        let records = try PrivateJSONStore(url: indexURL, prettyPrinted: true).load([Record].self) ?? []
        guard records.count <= 256, Set(records.map(\.layoutAppID)).count == records.count else {
            throw RPCFailure(code: -32000, message: "Invalid layout app index")
        }
        return records
    }
    func list(cached: Bool = false) async throws -> JSONValue {
        try ApplicationLaunchContext.current.requireParent()
        let records = try records()
        var values: [JSONValue] = []
        var paths = Set<String>()
        for record in records {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let value = try await snapshot(record, cached: cached)
            values.append(value)
            if let path = value.object?["path"]?.string { paths.insert(path) }
        }
        for path in Array(watchers.keys) where !paths.contains(path) {
            watchers.removeValue(forKey: path)?.close()
            inspections.removeValue(forKey: path)
            inspectionTokens.removeValue(forKey: path)
        }
        return .array(values)
    }
    nonisolated static func runtime(at app: URL) -> URL { app.appendingPathComponent("Contents/Frameworks/SlateRuntime.framework") }
    nonisolated static func revision(at runtime: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: runtime.appendingPathComponent("SlateRuntime"))).map { String(format: "%02x", $0) }.joined()
    }
    private func candidateApp(_ record: Record) -> URL? {
        let identifier = "com.slateterm.layoutapp.\(record.layoutAppID.uuidString.lowercased())"
        let registered = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
        let original = URL(fileURLWithPath: record.path)
        let candidates = Set(([original] + registered).map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { app in
            // Read the current file when a different app reuses the same path.
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == identifier,
                  let shellABI = (info["SlateShellRuntimeABI"] as? NSNumber)?.intValue, shellABI > 0,
                  let rawID = info["SlateLayoutAppID"] as? String else { return false }
            return UUID(uuidString: rawID) == record.layoutAppID
        })
        return candidates.count == 1 ? candidates.first : nil
    }
    private func catchUpDeferred(_ identifier: String) -> Bool {
        guard let deadline = catchUpNotBefore[identifier] else { return false }
        if ProcessInfo.processInfo.systemUptime < deadline { return true }
        catchUpNotBefore.removeValue(forKey: identifier)
        return false
    }

    private func isLaunching(_ identifier: String) -> Bool {
        guard let app = pendingLaunches[identifier] else { return false }
        if app.isTerminated || app.isFinishedLaunching {
            pendingLaunches.removeValue(forKey: identifier)
            return false
        }
        return true
    }

    private func isRunning(_ record: Record) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.slateterm.layoutapp.\(record.layoutAppID.uuidString.lowercased())")
            .contains { !$0.isTerminated }
    }

    private func snapshot(_ record: Record, cached: Bool = false) async throws -> JSONValue {
        let candidate = candidateApp(record)
        let app = candidate ?? URL(fileURLWithPath: record.path).standardizedFileURL.resolvingSymlinksInPath()
        observe(app.path)
        let token = inspectionTokens[app.path]
        var value: JSONValue
        if cached, let existing = inspections[app.path], existing.record == record,
           existing.candidateExists == (candidate != nil) {
            value = existing.value
        } else {
            let parentBuild = RuntimeBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let parentABI = Self.shellRuntimeABI
            value = try await Self.work {
                Self.inspect(record, app: app, candidateExists: candidate != nil, parentBuild: parentBuild, parentABI: parentABI)
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            // A watcher event during inspection must not restore an invalidated entry.
            if watchers[app.path] != nil, inspectionTokens[app.path] == token {
                inspections[app.path] = Inspection(record: record, candidateExists: candidate != nil, value: value)
            }
        }
        var fields = value.object!
        fields["running"] = .bool(isRunning(record))
        return .object(fields)
    }

    nonisolated private static func inspect(_ record: Record, app: URL, candidateExists: Bool,
                                            parentBuild: String?, parentABI: Int?) -> JSONValue {
        let available = candidateExists && (try? verifiedCodeHash(app)) == record.shellCodeHash
        let runtime = Self.runtime(at: app)
        let info = NSDictionary(contentsOf: runtime.appendingPathComponent("Resources/Info.plist")) as? [String: Any] ?? [:]
        let shellInfo = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let shellABI = (shellInfo["SlateShellRuntimeABI"] as? NSNumber)?.intValue
        let installedBuild = info["CFBundleVersion"] as? String
        let newerRuntime = parentBuild.flatMap { parent in installedBuild.map { parent.compare($0, options: .numeric) == .orderedDescending } } == true
        return .object(["layoutAppID": .string(record.layoutAppID.uuidString), "layoutID": .string(record.layoutID.uuidString),
            "name": .string(record.name), "path": .string(app.path), "available": .bool(available),
            "runtimeVersion": .string(info["CFBundleShortVersionString"] as? String ?? "unknown"),
            "runtimeBuild": .string(info["CFBundleVersion"] as? String ?? "unknown"),
            "revision": .string((try? Self.revision(at: runtime)) ?? "unavailable"),
            "shellCodeHash": .string(record.shellCodeHash),
            "updateReady": .bool(available && newerRuntime && shellABI == parentABI)])
    }

    func refresh(id: UUID, expectedRevision: String, operation: WorkspaceOperationContext = .init(origin: .native),
                 validate: @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try ApplicationLaunchContext.current.requireParent()
        try beginMutation()
        defer { mutationBusy = false }
        guard let record = try records().first(where: { $0.layoutAppID == id }) else {
            throw RPCFailure(code: -32022, message: "The layout app is not registered")
        }
        let identifier = identifier(record)
        let launchToken = launchTokens[identifier]
        guard !isLaunching(identifier) else {
            throw RPCFailure(code: -32051, message: "Wait for the layout app to finish launching before refreshing it")
        }
        let before = try await snapshot(record).object!
        guard before["running"] == .bool(false) else {
            throw RPCFailure(code: -32051, message: "Quit the layout app before refreshing it")
        }
        guard before["available"] == .bool(true), let path = before["path"]?.string else {
            throw RPCFailure(code: -32022, message: "The layout app is unavailable or running")
        }
        guard before["revision"] == .string(expectedRevision) else {
            throw RPCFailure(code: APIError.conflict, message: "The layout app changed; inspect it again")
        }
        let app = URL(fileURLWithPath: path)
        guard candidateApp(record) == app else {
            throw RPCFailure(code: -32022, message: "The layout app is missing, changed, or has duplicate copies")
        }
        guard let executable = Bundle(url: app)?.executableURL else {
            throw RPCFailure(code: -32022, message: "Layout app executable is unavailable")
        }
        let parentPath = Bundle.main.bundlePath
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try operation.validateCaller()
        try validate()
        guard !isRunning(record), !isLaunching(identifier), launchTokens[identifier] == launchToken else {
            throw RPCFailure(code: -32051, message: "Quit the layout app before refreshing it")
        }
        invalidate(path)
        defer { invalidate(path) }
        _ = try await Self.work {
            try Self.run(executable.path, ["--slate-refresh-only", "--expected-bundle-revision", expectedRevision,
                                          "--slate-parent-path", parentPath], refresh: true)
        }
        // A launched refresh owns its maintenance lease until exit, even if its caller cancels.
        // Reconcile completed mutations without letting cancellation hide their event.
        let parentBuild = RuntimeBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let parentABI = Self.shellRuntimeABI
        var fields = await Task.detached(executorPreference: BlockingIOExecutor.shared, priority: .utility) {
            Self.inspect(record, app: app, candidateExists: true, parentBuild: parentBuild, parentABI: parentABI)
        }.value.object!
        fields["running"] = .bool(isRunning(record))
        if before["revision"] != fields["revision"] {
            onChange?("host.layoutapp.refreshed", fields.filter { ["layoutAppID", "runtimeBuild", "runtimeVersion", "revision"].contains($0.key) }, operation)
        }
        return .object(fields)
    }

    func catchUp() async {
        guard !closed, !catchingUp, !mutationBusy, !ApplicationLaunchContext.current.isLayoutApp,
              let parentBuild = RuntimeBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let records = try? records() else { return }
        catchingUp = true
        defer { catchingUp = false }
        for record in records {
            guard !closed, !mutationBusy, !Task.isCancelled else { return }
            let identifier = identifier(record)
            guard !isLaunching(identifier), !catchUpDeferred(identifier) else { continue }
            guard let value = try? await snapshot(record, cached: true).object,
                  value["available"] == .bool(true), value["running"] == .bool(false), value["updateReady"] == .bool(true),
                  let build = value["runtimeBuild"]?.string, parentBuild.compare(build, options: .numeric) == .orderedDescending,
                  let revision = value["revision"]?.string else { continue }
            guard !closed, !mutationBusy, !Task.isCancelled else { return }
            guard !isLaunching(identifier), !catchUpDeferred(identifier) else { continue }
            let key = "\(record.layoutAppID):\(revision):\(parentBuild)"
            guard !attemptedRefreshes.contains(key) else { continue }
            automaticRefreshBusy = true
            defer { automaticRefreshBusy = false }
            do {
                _ = try await refresh(id: record.layoutAppID, expectedRevision: revision, validate: {
                    guard !self.catchUpDeferred(identifier) else {
                        throw RPCFailure(code: APIError.conflict, message: "Automatic refresh is waiting for the layout app to finish restarting.")
                    }
                    self.attemptedRefreshes.insert(key)
                })
            } catch { NSLog("Layout app refresh deferred: %@", String(describing: error)) }
            return
        }
    }

    func create(at destination: URL, layoutID: UUID, name: String, icon: String, copyPluginData: Bool, operation: WorkspaceOperationContext = .init(origin: .native),
                validate: @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try ApplicationLaunchContext.current.requireParent()
        try beginMutation()
        defer { mutationBusy = false }
        if ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] != "1" {
            let expectedBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SlateTerm")
            let expectedConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slate-term/config.toml")
            guard parentBase.standardizedFileURL == expectedBase.standardizedFileURL,
                  parentConfigURL.standardizedFileURL == expectedConfig.standardizedFileURL else {
                throw RPCFailure(code: -32602, message: "Layout apps require the default Slate state and configuration")
            }
        }
        guard let shellABI = Self.shellRuntimeABI, shellABI > 0 else {
            throw RPCFailure(code: -32022, message: "The parent runtime ABI is unavailable")
        }
        let options = try SavedLayoutLauncherOptions(name: name, icon: icon)
        let manager = FileManager.default
        guard destination.pathExtension == "app", destination.path.hasPrefix("/"), !manager.fileExists(atPath: destination.path) else {
            throw RPCFailure(code: -32602, message: "Choose a new .app destination; existing apps are not overwritten")
        }
        var records = try records()
        guard records.count < 256 else { throw RPCFailure(code: -32602, message: "At most 256 layout apps can be registered") }
        let id = UUID()
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".slate-layout-\(id.uuidString).app")
        let base = parentBase.appendingPathComponent("LayoutApps/\(id.uuidString.lowercased())")
        let recipeDirectory = parentConfigURL.deletingLastPathComponent().appendingPathComponent("layouts")
        let recipe = try LayoutAppPluginSync.readRecipe(directory: recipeDirectory, id: layoutID)
        guard let executable = Bundle.main.executableURL else { throw RPCFailure(code: -32000, message: "The native bootstrap is unavailable") }
        let runtime = RuntimeBundle.bundle.bundleURL
        let iconData = try LayoutLauncher.iconData(symbol: options.icon)
        let developmentValue = RuntimeBundle.bundle.object(forInfoDictionaryKey: "SlateRuntimeDevelopment")
        let development = developmentValue as? Bool == true || ["YES", "1"].contains(developmentValue as? String ?? "")
        let info: [String: Any] = ["CFBundleExecutable": "SlateLayoutApp", "CFBundleName": options.name,
            "CFBundleDisplayName": options.name, "CFBundleIconFile": "LayoutIcon.icns", "SlateLauncherIcon": options.icon,
            "CFBundleIdentifier": "com.slateterm.layoutapp.\(id.uuidString.lowercased())", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1", "LSMinimumSystemVersion": "27.0",
            "SlateLayoutAppID": id.uuidString, "SlateLayoutID": layoutID.uuidString,
            "SlateShellRuntimeABI": shellABI,
            "SlateParentBundleID": Bundle.main.bundleIdentifier ?? "com.slateterm.app", "SlateParentPath": Bundle.main.bundlePath,
            "NSAppleEventsUsageDescription": "Allow this app to automate actions you request.",
            "NSDocumentsFolderUsageDescription": "Access documents used by your terminals and workspace.",
            "NSDownloadsFolderUsageDescription": "Access downloads used by your terminals and workspace.",
            "NSDesktopFolderUsageDescription": "Access desktop files used by your terminals and workspace."]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let parentBase = self.parentBase
        let parentBuild = RuntimeBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let prepared = try await Self.work {
            let manager = FileManager.default
            let prepared = PreparedCreation(stage: stage, destination: destination)
            do {
                prepared.preflight = try LayoutAppCreationPreflight.prepare(base: base, parentBase: parentBase,
                                                                           recipe: recipe, copyPluginData: copyPluginData)
                try Task.checkCancellation()
                try manager.createDirectory(at: stage.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                try manager.createDirectory(at: stage.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
                try manager.copyItem(at: executable, to: stage.appendingPathComponent("Contents/MacOS/SlateLayoutApp"))
                try manager.copyItem(at: runtime, to: Self.runtime(at: stage))
                try Task.checkCancellation()
                let resources = stage.appendingPathComponent("Contents/Resources")
                try manager.createDirectory(at: resources, withIntermediateDirectories: true)
                try iconData.write(to: resources.appendingPathComponent("LayoutIcon.icns"))
                try infoData.write(to: stage.appendingPathComponent("Contents/Info.plist"))
                try Self.signGeneratedShell(stage, development: development)
                let hash = try Self.verifiedCodeHash(stage)
                let record = Record(layoutAppID: id, layoutID: layoutID, name: options.name, path: destination.path, shellCodeHash: hash)
                prepared.record = record
                prepared.snapshot = Self.inspect(record, app: stage, candidateExists: true, parentBuild: parentBuild, parentABI: shellABI)
                try Task.checkCancellation()
                return prepared
            } catch {
                prepared.finish()
                throw error
            }
        }
        do {
            await pausePreparedCreationForTesting(stage: stage, base: base, destination: destination)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try operation.validateCaller()
            try validate()
            try manager.moveItem(at: stage, to: destination)
            prepared.destinationOwned = true
            let record = prepared.record!
            records.append(record)
            try PrivateJSONStore(url: indexURL, prettyPrinted: true).save(records)
            prepared.published = true
            prepared.preflight!.retainPublishedState()
            invalidate(destination.standardizedFileURL.resolvingSymlinksInPath().path)
            // Registration failure does not undo a published app or invite a blind creation retry.
            let registrationStatus = LSRegisterURL(destination as CFURL, true)
            let snapshot = prepared.snapshot.object!
            onChange?("host.layoutapp.created", snapshot.filter { ["layoutAppID", "runtimeBuild", "runtimeVersion", "revision"].contains($0.key) }, operation)
            let result: JSONValue = .object(["id": .string(layoutID.uuidString), "path": .string(destination.path), "layoutAppID": .string(id.uuidString),
                "runtimeVersion": snapshot["runtimeVersion"]!, "runtimeBuild": snapshot["runtimeBuild"]!,
                "syncedPluginIDs": .array(prepared.preflight!.syncedPluginIDs.map(JSONValue.string)),
                "unavailablePlugins": try .encoding(prepared.preflight!.unavailablePlugins),
                "copiedPluginDataIDs": .array(prepared.preflight!.copiedPluginDataIDs.map(JSONValue.string)),
                "launchServicesRegistered": .bool(registrationStatus == noErr),
                "launchServicesStatus": .integer(Int(registrationStatus))])
            await Task.detached(executorPreference: BlockingIOExecutor.shared, priority: .utility) { prepared.finish() }.value
            return result
        } catch {
            await Task.detached(executorPreference: BlockingIOExecutor.shared, priority: .utility) { prepared.finish() }.value
            throw error
        }
    }

    /// Ownership transfers worker -> main actor -> cleanup worker, with no overlapping access.
    /// The preflight lease remains alive until cleanup finishes, including cancelled requests.
    private nonisolated final class PreparedCreation: @unchecked Sendable {
        let stage: URL
        let destination: URL
        var preflight: LayoutAppCreationPreflight?
        var record: Record?
        var snapshot: JSONValue = .null
        var published = false
        var destinationOwned = false
        init(stage: URL, destination: URL) { self.stage = stage; self.destination = destination }
        func finish() {
            try? FileManager.default.removeItem(at: stage)
            if !published && destinationOwned { try? FileManager.default.removeItem(at: destination) }
            preflight = nil
        }
    }

    func creationUnavailablePlugins() async throws -> [LayoutAppCreationPreflight.UnavailablePlugin] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("slate-layout-preview-\(UUID().uuidString)")
        let parentBase = self.parentBase
        return try await Self.work {
            let preview = try LayoutAppCreationPreflight.prepare(base: base, parentBase: parentBase,
                                                                recipe: nil, copyPluginData: false)
            defer { withExtendedLifetime(preview) {} }
            try Task.checkCancellation()
            return preview.unavailablePlugins
        }
    }

    nonisolated static func signGeneratedShell(_ stage: URL, development: Bool) throws {
        let manager = FileManager.default
        // The executable's compiled policy remains authoritative; metadata cannot weaken it.
        let entitlements = stage.deletingLastPathComponent().appendingPathComponent(".slate-entitlements-\(UUID().uuidString).plist")
        let constraint = stage.deletingLastPathComponent().appendingPathComponent(".slate-constraint-\(UUID().uuidString).plist")
        defer { try? manager.removeItem(at: entitlements); try? manager.removeItem(at: constraint) }
        let shellEntitlements = ["com.apple.security.cs.disable-library-validation": true,
                                 "com.apple.security.automation.apple-events": true]
        try PropertyListSerialization.data(fromPropertyList: shellEntitlements, format: .xml, options: 0).write(to: entitlements)
        try PropertyListSerialization.data(fromPropertyList: ["team-identifier": "YWRT8FQN6F"], format: .xml, options: 0).write(to: constraint)
        try Self.run("/usr/bin/xattr", ["-cr", stage.path])
        var arguments = ["--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlements.path]
        if !development { arguments += ["--library-constraint", constraint.path] }
        arguments.append(stage.path)
        try Self.run("/usr/bin/codesign", arguments)
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
        if !development {
            let readback = try Self.run("/usr/bin/codesign", ["--display", "--verbose=6", stage.path])
            guard readback.contains("Has Library Load Constraints"), readback.contains("[Key] team-identifier"),
                  readback.contains("[String] YWRT8FQN6F") else {
                throw RPCFailure(code: -32000, message: "The required runtime publisher constraint was not embedded")
            }
        }
    }

    nonisolated static func verifiedCodeHash(_ bundle: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw RPCFailure(code: -32022, message: "The layout app signature is invalid")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let data = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw RPCFailure(code: -32022, message: "The layout app signing identity is unavailable")
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated static func run(_ command: String, _ arguments: [String], refresh: Bool = false) throws -> String {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
        // A file avoids pipe-capacity deadlocks while retaining a bounded failure message.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("slate-layout-operation-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: (try? Data(contentsOf: log).prefix(4096)) ?? Data(), as: UTF8.self)
            let codes: [Int32: Int] = [75: -32051, 76: APIError.conflict, 77: -32053]
            throw RPCFailure(code: refresh ? (codes[process.terminationStatus] ?? -32000) : -32000, message: "Layout app operation failed: \(detail)")
        }
        return String(decoding: try Data(contentsOf: log).prefix(1_048_576), as: UTF8.self)
    }
}
