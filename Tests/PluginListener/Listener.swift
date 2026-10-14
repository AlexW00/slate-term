import Darwin
import Foundation

@main struct ListenerGate {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-listener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let python = ProcessInfo.processInfo.environment["SLATE_TEST_PYTHON"]!
        let available = try PluginListener.availablePort()
        let code = "import socket,time,pathlib,sys;s=socket.socket();s.bind(('127.0.0.1',int(sys.argv[2])));s.listen();pathlib.Path(sys.argv[1]).write_text(str(s.getsockname()[1]));time.sleep(60)"
        let server = try PluginProcess(executable: python, arguments: ["-c", code, portFile.path, String(available)], directory: nil, environment: ProcessInfo.processInfo.environment)
        let unrelated = try PluginProcess(executable: "/bin/sleep", arguments: ["60"], directory: nil, environment: [:])
        defer { server.close(); unrelated.close() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        let port = UInt16(try String(contentsOf: portFile, encoding: .utf8))!
        guard port == available, port > 0, PluginListener.owns(port: port, group: server.pid) else { throw Failure(message: "Owned listening socket was not recognized") }
        guard !PluginListener.owns(port: port, group: unrelated.pid), !PluginListener.owns(port: port, group: 0) else { throw Failure(message: "Unrelated server was accepted as ready") }
        await server.stop()
        guard !PluginListener.owns(port: port, group: server.pid), kill(unrelated.pid, 0) == 0 else { throw Failure(message: "Dead socket was accepted or unrelated process was changed") }
        print("PASS plugin listener: actual IPv4 socket ownership, unrelated process rejection, exit and invalid group")
    }
    struct Failure: Error { let message: String }
}
