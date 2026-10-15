import Darwin
import Foundation
import SlateTermCore

@main
@MainActor
struct TerminalRunsChecks {
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await checkQuotingAndSynchronousCompletion()
            try await checkValidation()
            try await checkInputClaims()
            try await checkCallerRetirement()
            try await checkMatchingAndInterruption()
            try await checkOutputBounds()
            try await checkReplacementAndSendFailure()
            try await checkTimeoutAndCancellation()
            try await checkCapacityAndClose()
            try await checkRacesAndLifetime()
            print("PASS all terminal run checks")
        } catch {
            fputs("FAIL terminal runs: \(error)\n", stderr)
            exit(1)
        }
    }

    static func checkQuotingAndSynchronousCompletion() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        var fixtures = [
            ("echo 'hi' \\ $HOME; $(false)", "echo \\x27hi\\x27 \\x5c $HOME; $(false)"),
            ("echo 日本語 🐈 e\u{301}", "echo 日本語 🐈 e\u{301}"),
            ("first\nsecond\r\tthird", "first\\x0asecond\\x0d\\x09third"),
        ]
        for byte in Array(UInt8(1)...UInt8(31)) + [127] {
            fixtures.append((String(UnicodeScalar(byte)), String(format: "\\x%02x", byte)))
        }
        var markers = Set<String>()
        for (command, quoted) in fixtures {
            var captures = 0
            var sent = 0
            let result = try await runs.run(pane: PaneID(1), sessionID: "session", command: command) { line in
                sent += 1
                try require(runs.pendingCount == 1, "send must see the pane already reserved")
                let marker = try markerPrefix(line)
                try require(markers.insert(marker).inserted, "command marker reused")
                try require(line == "\(marker) builtin eval $'\(quoted)'\r", "incorrect ANSI-C quoting: \(line.debugDescription)")
                try require(!line.dropLast().utf8.contains { $0 < 32 || $0 == 127 }, "literal control keystroke sent")
                runs.observe(pane: PaneID(1), sessionID: "session", report: report(.running, 1, command: String(line.dropLast()))) {
                    captures += 1; return "premature"
                }
                runs.observe(pane: PaneID(1), sessionID: "session", report: report(.prompt, 2, exit: 7)) {
                    captures += 1; return "actual terminal 日本語\n"
                }
                runs.observe(pane: PaneID(1), sessionID: "session", report: report(.prompt, 3, exit: 0)) {
                    captures += 1; return "duplicate"
                }
            }
            try require(sent == 1 && captures == 1 && runs.pendingCount == 0, "synchronous completion was missed or repeated")
            try require(result.paneId == PaneID(1) && result.sessionId == "session", "result identity lost")
            try require(UUID(uuidString: result.commandId) != nil && markers.contains(": __SLATE_RUN_\(result.commandId);"), "result commandId is not marker UUID")
            try require(result.exitCode == 7 && result.text == "actual terminal 日本語\n" && !result.truncated, "nonzero completion treated as failure or text changed")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
            try require(Set(encoded.keys) == ["paneId", "sessionId", "commandId", "exitCode", "text", "truncated"], "result encoding keys changed")
        }
        print("PASS single-line ANSI-C quoting (all ASCII controls, apostrophe, backslash, Unicode, multiline), unique markers, synchronous reports and nonzero result")
    }

    static func checkValidation() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        var sends = 0
        for command in ["", "a\0b", String(repeating: "a", count: 16_385), String(repeating: "🐈", count: 4_097)] {
            do {
                _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: command) { _ in sends += 1 }
                throw Failure(message: "invalid command accepted")
            } catch let error as TerminalRunError {
                guard case .invalidCommand = error else { throw error }
            }
        }
        for milliseconds in [Int.min, -1, 0, 295_001, Int.max] {
            try await expectError(.invalidTimeout(milliseconds)) {
                try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok", timeoutMilliseconds: milliseconds) { _ in sends += 1 }
            }
        }
        try require(sends == 0 && runs.pendingCount == 0, "invalid input sent bytes or reserved state")
        for command in [String(repeating: "a", count: 16_384), String(repeating: "🐈", count: 4_096)] {
            _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: command, timeoutMilliseconds: 295_000) { line in
                let marker = try markerPrefix(line)
                runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: marker + " builtin eval")) { "" }
                runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) { "" }
            }
        }
        print("PASS empty/NUL/UTF-8-byte command bounds, timeout bounds and no send/bookkeeping on rejection")
    }

    static func checkInputClaims() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let (task, line) = try await start(runs)
        do {
            _ = try runs.claimInput(pane: PaneID(1), sessionID: "old", emptyBuffer: true)
            throw Failure(message: "Old session claimed input")
        } catch TerminalRunError.replaced {}
        try require(runs.pendingCount == 1, "Wrong-session claim cancelled current run")
        let claimed = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true)
        try require(claimed == String(line.dropLast()), "Claim changed command or included an input Return")
        do {
            _ = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true)
            throw Failure(message: "Command could be claimed twice")
        } catch TerminalRunError.replaced {}
        task.cancel()
        try await expectCancellation { try await task.value }
        let (draft, _) = try await start(runs)
        do {
            _ = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: false)
            throw Failure(message: "Nonempty editing buffer accepted")
        } catch TerminalRunError.editingBufferNotEmpty {}
        try await expectError(.editingBufferNotEmpty) { try await draft.value }
        try require(runs.pendingCount == 0, "Refusal retained a pending run")
        do {
            _ = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true)
            throw Failure(message: "Retired command was delivered")
        } catch TerminalRunError.replaced {}
        print("PASS shell-side input claim: one delivery, session ownership, draft refusal and retired request rejection")
    }

    static func checkCallerRetirement() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        var callerLive = true
        var claimed = false
        do {
            _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: "must not execute",
                validateCaller: { if !callerLive { throw CancellationError() } }, send: { _ in
                    // Retire and claim synchronously: cancellation cleanup cannot run first.
                    callerLive = false
                    do { _ = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true); claimed = true }
                    catch is CancellationError { }
                    if claimed { throw Failure(message: "Retired caller's input was delivered") }
                })
            throw Failure(message: "Retired caller's run succeeded")
        } catch is CancellationError { }
        try require(!claimed && runs.pendingCount == 0, "Retired caller retained or delivered pending input")
        print("PASS caller lifetime revalidated at input claim before asynchronous cancellation cleanup")
    }

    static func checkMatchingAndInterruption() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let pane = PaneID(1)
        let (task, line) = try await start(runs)
        var captures = 0
        let capture = { captures += 1; return "matched" }
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 10, exit: 0), capture: capture)
        runs.observe(pane: PaneID(2), sessionID: "elsewhere", report: report(.running, 11, command: "wrong"), capture: capture)
        try require(runs.pendingCount == 1 && captures == 0, "prompt without preexec or another pane completed run")
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: String(line.dropLast())), capture: capture)
        for sequence in [10, 11] {
            runs.observe(pane: pane, sessionID: "s", report: report(.prompt, sequence, exit: 0), capture: capture)
        }
        try require(runs.pendingCount == 1 && captures == 0, "non-subsequent prompt completed run")
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 12, exit: 0), capture: capture)
        try require(try await task.value.text == "matched" && captures == 1, "matching completion failed")

        for afterMatch in [false, true] {
            let (interrupted, sent) = try await start(runs)
            if afterMatch {
                runs.observe(pane: pane, sessionID: "s", report: report(.running, 1, command: String(sent.dropLast()))) { "never" }
            }
            let marker = try markerPrefix(sent)
            // A marker-looking command with an extended UUID is not the matching prefix.
            let wrong = String(marker.dropLast()) + "X; builtin eval $'echo test'"
            runs.observe(pane: pane, sessionID: "s", report: report(.running, 2, command: wrong)) { captures += 1; return "wrong" }
            runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 3, exit: 0)) { captures += 1; return "wrong" }
            try await expectError(.interrupted) { try await interrupted.value }
        }
        try require(captures == 1 && runs.pendingCount == 0, "interruption captured text or leaked")
        print("PASS matching marker boundary, preexec-before-prompt and greater-sequence requirement, pane isolation and different-command interruption")
    }

    static func checkOutputBounds() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let maximum = 128 * 1_024
        let fixtures: [(String, String, Bool)] = [
            ("", "", false),
            (String(repeating: "a", count: maximum), String(repeating: "a", count: maximum), false),
            ("old" + String(repeating: "z", count: maximum), String(repeating: "z", count: maximum), true),
            // A byte suffix starts inside a multibyte scalar: drop that partial scalar, not replace it.
            ("old🐈" + String(repeating: "x", count: maximum - 1), String(repeating: "x", count: maximum - 1), true),
            ("old" + String(repeating: "🐈", count: maximum / 4), String(repeating: "🐈", count: maximum / 4), true),
        ]
        for (text, expected, truncated) in fixtures {
            let (task, line) = try await start(runs)
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: String(line.dropLast()))) { "not completion" }
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: nil)) { text }
            let result = try await task.value
            try require(result.text == expected && result.truncated == truncated, "output suffix/truncation incorrect")
            try require(result.text.utf8.count <= maximum && !result.text.contains("�"), "output exceeded byte cap or broke UTF-8")
            try require(result.exitCode == nil, "optional status was fabricated")
        }
        print("PASS capture only at completion, 128 KiB suffix bound, explicit truncation, valid UTF-8 and optional exit status")
    }

    static func checkReplacementAndSendFailure() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        var sends = 0
        let (first, _) = try await start(runs)
        try await expectError(.alreadyRunning(PaneID(1))) {
            try await runs.run(pane: PaneID(1), sessionID: "new", command: "next") { _ in sends += 1 }
        }
        runs.observe(pane: PaneID(1), sessionID: "new", report: report(.prompt, 1, exit: 0)) { sends += 100; return "wrong session" }
        try await expectError(.replaced) { try await first.value }
        try require(sends == 0, "duplicate sent input or replacement captured successor text")
        let (removed, _) = try await start(runs)
        runs.remove(pane: PaneID(1))
        runs.remove(pane: PaneID(1))
        try await expectError(.replaced) { try await removed.value }
        let (next, line) = try await start(runs, sessionID: "new")
        runs.observe(pane: PaneID(1), sessionID: "new", report: report(.running, 1, command: String(line.dropLast()))) { "" }
        runs.observe(pane: PaneID(1), sessionID: "new", report: report(.prompt, 2, exit: 0)) { "successor" }
        try require(try await next.value.text == "successor", "replacement prevented successor run")
        do {
            _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok") { _ in throw SendFailure() }
            throw Failure(message: "send error swallowed")
        } catch is SendFailure { }
        try require(runs.pendingCount == 0, "send failure leaked reservation")
        // First terminal outcome wins even when send re-enters observe/remove/close and then throws.
        let reentrant = TerminalRuns()
        let result = try await reentrant.run(pane: PaneID(1), sessionID: "s", command: "ok") { line in
            reentrant.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: String(line.dropLast()))) { "" }
            reentrant.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) {
                reentrant.remove(pane: PaneID(1)); reentrant.close(); return "captured"
            }
            throw SendFailure()
        }
        try require(result.text == "captured" && reentrant.pendingCount == 0, "reentrant capture resolved twice")
        for close in [false, true] {
            let tracker = TerminalRuns()
            try await expectError(close ? .closed : .replaced) {
                try await tracker.run(pane: PaneID(1), sessionID: "s", command: "ok") { _ in
                    if close { tracker.close() } else { tracker.remove(pane: PaneID(1)) }
                    throw SendFailure()
                }
            }
        }
        print("PASS one run per pane, replaced session/removal, successor reuse, synchronous send errors and reentrant first-outcome resolution")
    }

    static func checkTimeoutAndCancellation() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let began = ContinuousClock.now
        let (timedOut, _) = try await start(runs, timeout: 60)
        try await expectError(.timeout) { try await timedOut.value }
        try require(began.duration(to: .now) >= .milliseconds(50) && runs.pendingCount == 0, "deadline too early or leaked")
        try await expectError(.timeout) {
            try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok", timeoutMilliseconds: 1) { _ in }
        }
        let (cancelled, _) = try await start(runs, timeout: 80)
        cancelled.cancel()
        try await expectCancellation { try await cancelled.value }
        try require(runs.pendingCount == 0, "cancellation failed to release reservation")
        let (successor, line) = try await start(runs)
        try await Task.sleep(for: .milliseconds(120))
        try require(runs.pendingCount == 1, "stale cancelled timer ended successor")
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 20, command: String(line.dropLast()))) { "" }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 21, exit: 0)) { "still alive" }
        try require(try await successor.value.text == "still alive", "successor lost to old deadline")
        var sends = 0
        let alreadyCancelled = Task {
            try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok") { _ in sends += 1 }
        }
        alreadyCancelled.cancel()
        try await expectCancellation { try await alreadyCancelled.value }
        try require(sends == 0 && runs.pendingCount == 0, "already cancelled caller sent input")
        print("PASS real timeout (including 1 ms boundary), cancellation, pre-entry cancellation, released slots and stale timer isolation; no process-control input")
    }

    static func checkCapacityAndClose() async throws {
        let runs = TerminalRuns()
        var tasks: [Task<TerminalRunResult, Error>] = []
        for pane in 1...32 {
            let (task, _) = try await start(runs, pane: PaneID(pane))
            tasks.append(task)
        }
        try require(runs.pendingCount == 32, "global capacity changed")
        try await expectError(.overloaded(maximumPending: 32)) {
            try await runs.run(pane: PaneID(33), sessionID: "s", command: "ok") { _ in throw Failure(message: "overloaded send") }
        }
        tasks[0].cancel()
        try await expectCancellation { try await tasks[0].value }
        let (replacement, _) = try await start(runs)
        tasks[0] = replacement
        try require(runs.pendingCount == 32, "cancelled slot not reusable")
        runs.close()
        runs.close()
        for task in tasks { try await expectError(.closed) { try await task.value } }
        try await expectError(.closed) {
            try await runs.run(pane: PaneID(33), sessionID: "s", command: "ok") { _ in throw Failure(message: "closed send") }
        }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 99, exit: 0)) { fatalError("closed capture") }
        try require(runs.pendingCount == 0, "close leaked pending runs")
        print("PASS 32-run global cap, overload without dropping work, slot reuse, idempotent close and closed admission")
    }

    static func checkRacesAndLifetime() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        for index in 0..<24 {
            let (task, line) = try await start(runs, timeout: 10)
            if index.isMultiple(of: 3) { try await Task.sleep(for: .milliseconds(10)) }
            if index.isMultiple(of: 2) { task.cancel() }
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: String(line.dropLast()))) { "" }
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) { "race" }
            task.cancel()
            do {
                try require(try await task.value.text == "race", "race returned invalid result")
            } catch is CancellationError {
            } catch let error as TerminalRunError {
                try require(error == .timeout, "race returned unexpected error")
            }
            try require(runs.pendingCount == 0, "race leaked continuation")
        }
        var owned: TerminalRuns? = TerminalRuns()
        weak let weakRuns = owned
        var task: Task<TerminalRunResult, Error>? = Task { [tracker = owned!] in
            try await tracker.run(pane: PaneID(1), sessionID: "s", command: "ok", timeoutMilliseconds: 295_000) { _ in }
        }
        try await eventually("owned run registration") { owned!.pendingCount == 1 }
        task!.cancel()
        try await expectCancellation { try await task!.value }
        task = nil
        owned = nil
        try await eventually("cancelled timer retained tracker") { weakRuns == nil }
        print("PASS completion/cancellation/deadline races and tracker release after maximum-deadline cancellation")
    }

    static func start(_ runs: TerminalRuns, pane: PaneID = PaneID(1), sessionID: String = "s", timeout: Int = 5_000) async throws -> (Task<TerminalRunResult, Error>, String) {
        var sent: String?
        let task = Task {
            try await runs.run(pane: pane, sessionID: sessionID, command: "echo test", timeoutMilliseconds: timeout) { line in sent = line }
        }
        try await eventually("run did not send") { sent != nil }
        return (task, sent!)
    }

    static func markerPrefix(_ line: String) throws -> String {
        let prefix = ": __SLATE_RUN_"
        guard line.hasPrefix(prefix), let semicolon = line.firstIndex(of: ";"), line.last == "\r" else {
            throw Failure(message: "missing marker or final Return")
        }
        let uuid = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<semicolon])
        try require(UUID(uuidString: uuid) != nil, "marker has no UUID")
        return String(line[...semicolon])
    }

    static func report(_ state: ShellReport.State, _ sequence: Int, command: String? = nil, exit: Int? = nil) -> ShellReport {
        ShellReport(state: state, pid: 123, sequence: sequence, workingDirectory: "/tmp", command: command, exitCode: exit)
    }

    static func eventually(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func expectError(_ expected: TerminalRunError, _ operation: () async throws -> TerminalRunResult) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "expected error: \(expected)")
        } catch let actual as TerminalRunError {
            try require(actual == expected, "expected \(expected), got \(actual)")
        }
    }

    static func expectCancellation(_ operation: () async throws -> TerminalRunResult) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "expected CancellationError")
        } catch is CancellationError { }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    struct Failure: Error { let message: String }
    struct SendFailure: Error { }
}
