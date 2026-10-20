import AppKit
import CryptoKit
import Darwin
import Security
import SlateTermCore

/// A local offer is bound to verified parent code and is checked again before restarting.
nonisolated struct LayoutAppUpdateSource: Sendable {
    let parent: URL
    let version: String
    let build: String
    let revision: String
    let codeHash: String
    let updateID: String

    struct InspectionInput: Equatable, Sendable {
        let parentID: String
        let candidates: [URL]
        let development: Bool
    }

    @MainActor static func captureInspectionInput() throws -> InspectionInput {
        let shell = Bundle.main
        guard ApplicationLaunchContext.current.isLayoutApp,
              let parentID = shell.object(forInfoDictionaryKey: "SlateParentBundleID") as? String else {
            throw unavailable("This action is available in a layout app.")
        }
        var candidates: [URL] = []
        if let path = shell.object(forInfoDictionaryKey: "SlateParentPath") as? String { candidates.append(URL(fileURLWithPath: path)) }
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parentID), !candidates.contains(found) { candidates.append(found) }
        let development = ["1", "YES"].contains(String(describing: RuntimeBundle.bundle.object(forInfoDictionaryKey: "SlateRuntimeDevelopment") ?? "0"))
        return InspectionInput(parentID: parentID, candidates: candidates, development: development)
    }

    static func verifiedParents(_ input: InspectionInput) throws -> [URL] {
        try Task.checkCancellation()
        return input.candidates.filter { candidate in
            guard let info = dictionary(candidate.appendingPathComponent("Contents/Info.plist")) else { return false }
            return info["CFBundleIdentifier"] as? String == input.parentID && info["SlateLayoutAppID"] == nil
                && validCode(candidate, runtime: false, development: input.development)
        }
    }

    static func parentApplication(_ input: InspectionInput) throws -> URL {
        guard let parent = try verifiedParents(input).first else { throw unavailable("The verified Slate Terminal application could not be found.") }
        try Task.checkCancellation()
        return parent
    }

    static func inspect(_ input: InspectionInput) throws -> Self {
        let candidates = try verifiedParents(input)
        for candidate in candidates {
            try Task.checkCancellation()
            let runtime = candidate.appendingPathComponent("Contents/Frameworks/SlateRuntime.framework")
            guard runtime.resolvingSymlinksInPath().path == candidate.resolvingSymlinksInPath().appendingPathComponent("Contents/Frameworks/SlateRuntime.framework").path,
                  validCode(runtime, runtime: true, development: input.development), let codeHash = signedCodeHash(runtime), let metadata = dictionary(runtime.appendingPathComponent("Resources/Info.plist")),
                  String(describing: metadata["SlateRuntimeABI"] ?? "") == "1",
                  let version = metadata["CFBundleShortVersionString"] as? String,
                  let build = metadata["CFBundleVersion"] as? String, !build.isEmpty, build.utf8.count <= 64,
                  let data = try? Data(contentsOf: runtime.appendingPathComponent("SlateRuntime"), options: .mappedIfSafe) else { continue }
            let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let identity = Data((candidate.path + "\n" + revision + "\n" + codeHash + "\n" + version + "\n" + build).utf8)
            let id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            try Task.checkCancellation()
            return Self(parent: candidate, version: version, build: build, revision: revision, codeHash: codeHash, updateID: id)
        }
        throw unavailable("A compatible, verified Slate Terminal installation is unavailable. Open or reinstall Slate Terminal, then check again.")
    }

    private static func dictionary(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func signedCodeHash(_ url: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any], let hash = fields[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func validCode(_ url: URL, runtime: Bool, development: Bool) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSRestrictSymlinks)
        let identifier = runtime ? "com.slateterm.runtime" : "com.alexandermoritzweichart.slateterm"
        var requirement: SecRequirement?
        let predicate = "anchor apple generic and certificate leaf[subject.OU] = \"YWRT8FQN6F\" and identifier \"\(identifier)\""
        guard SecRequirementCreateWithString(predicate as CFString, [], &requirement) == errSecSuccess else { return false }
        if SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess { return true }
        // Match the shell's compiled development policy; production runtimes cannot enable this exception.
        guard development else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let flagsValue = info[kSecCodeInfoFlags as String] as? NSNumber,
              flagsValue.uint32Value & 0x2 != 0 else { return false }
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    /// The worker transfers exclusive helper ownership to the main actor after readiness.
    /// A rejected or cancelled request returns ownership to a worker for termination and reaping.
    nonisolated final class PreparedRelaunch: @unchecked Sendable {
        private var process: Process?
        fileprivate init(_ process: Process) { self.process = process }
        func commit() { process = nil }
        func cancel() {
            guard let process else { return }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            self.process = nil
        }
    }

    @MainActor static func prepareRelaunch(source: Self) async throws -> PreparedRelaunch {
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, size) == size,
              let executable = Bundle.main.executableURL else { throw unavailable("The app could not prepare a safe restart.") }
        let arguments = ["--slate-relaunch-after", String(getpid()), "--slate-relaunch-identity", "\(process.pbi_start_tvsec):\(process.pbi_start_tvusec)", "--slate-parent-path", source.parent.path, "--slate-expected-parent-revision", source.revision, "--slate-expected-parent-code-hash", source.codeHash]
        return try await BlockingIOExecutor.run {
            let helper = Process()
            helper.executableURL = executable
            helper.arguments = arguments
            helper.standardInput = FileHandle.nullDevice
            let readiness = Pipe()
            helper.standardOutput = readiness
            helper.standardError = FileHandle.nullDevice
            defer {
                try? readiness.fileHandleForWriting.close()
                try? readiness.fileHandleForReading.close()
            }
            try helper.run()
            let prepared = PreparedRelaunch(helper)
            do {
                try? readiness.fileHandleForWriting.close()
                var descriptor = pollfd(fd: readiness.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let readable = poll(&descriptor, 1, 3_000) > 0 && descriptor.revents & Int16(POLLIN) != 0
                let acknowledgement = readable ? try readiness.fileHandleForReading.read(upToCount: 6) : nil
                guard acknowledgement == Data("READY\n".utf8) else {
                    throw unavailable("The restart helper could not start safely. This app remains open.")
                }
                try Task.checkCancellation()
                return prepared
            } catch {
                prepared.cancel()
                throw error
            }
        }
    }

    static func unavailable(_ message: String) -> RPCFailure { RPCFailure(code: APIError.unavailable, message: message) }
}
