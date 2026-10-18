import Darwin
import Foundation
import SlateTermCore

/// Native adapter checks. The shared operation store's ownership, retention, capacity and
/// waiter tests also run in SlateTermCoreTests. Runs are session-owned operations: a wait's
/// timeout or cancellation ends only that wait, never the operation's tracking.
@main
@MainActor
struct TerminalRunsChecks {
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await checkQuotingAndSynchronousCompletion()
            try await checkValidation()
            try await checkInputClaims()
            try await checkCallerIndependentAdoption()
            try await checkMatchingAndInterruption()
            try await checkOutputBounds()
            try await checkReplacementAndSendFailure()
            try await checkTimeoutAndCancellation()
            try await checkReconnectableWaits()
            try await checkCapacityAndClose()
            try await checkLayoutReservations()
            try await checkRacesAndLifetime()
            try await checkReorderedReports()
            try await checkShellRunLines()
            print("PASS all terminal run checks")
        } catch {
            fputs("FAIL terminal runs: \(error)\n", stderr)
            exit(1)
        }
    }

    static func checkLayoutReservations() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let panes = Set((1...32).map(PaneID.init))
        try runs.reserve(panes)
        try await expectError(.overloaded(maximumPending: 32)) {
            try await runs.run(pane: PaneID(33), sessionID: "s", command: "must not run") { throw Failure(message: "Reservation was stolen") }
        }
        try await expectError(.alreadyRunning(PaneID(1))) {
            try await runs.run(pane: PaneID(1), sessionID: "s", command: "must not run") { throw Failure(message: "Startup target was stolen") }
        }
        _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: "reserved", usingReservation: true) {
            try complete(runs, screen: "done")
        }
        try runs.reserve([PaneID(33)])
        runs.remove(pane: PaneID(2))
        try runs.reserve([PaneID(34)])
        runs.close()
        try await expectError(.closed) {
            try await runs.run(pane: PaneID(3), sessionID: "s", command: "closed", usingReservation: true) {}
        }
        let overfull = TerminalRuns()
        do {
            try overfull.reserve(Set((1...33).map(PaneID.init)))
            throw Failure(message: "Over-capacity reservation accepted")
        } catch TerminalRunError.overloaded(maximumPending: 32) {}
        try overfull.reserve(panes)
        overfull.close()
        print("PASS startup reservations are atomic, cannot be stolen, and release on removal/completion/close")
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
            let result = try await runs.run(pane: PaneID(1), sessionID: "session", command: command) {
                sent += 1
                try require(runs.pendingCount == 1, "send must see the pane already adopted")
                let line = try runs.claimInput(pane: PaneID(1), sessionID: "session", emptyBuffer: true)
                let marker = try markerPrefix(line)
                try require(markers.insert(marker).inserted, "command marker reused")
                try require(line == "\(marker) builtin eval $'\(quoted)'", "incorrect ANSI-C quoting: \(line.debugDescription)")
                try require(!line.utf8.contains { $0 < 32 || $0 == 127 }, "literal control keystroke or Return in claimed input")
                runs.observe(pane: PaneID(1), sessionID: "session", report: report(.running, 1, command: line)) {
                    captures += 1; return "premature"
                }
                runs.observe(pane: PaneID(1), sessionID: "session", report: report(.prompt, 2, exit: 7)) {
                    captures += 1; return "actual terminal 日本語\n"
                }
                runs.observe(pane: PaneID(1), sessionID: "session", report: report(.prompt, 3, exit: 0)) {
                    captures += 1; return "duplicate"
                }
                throw SendFailure() // A late delivery error must not replace an observed completion.
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
                _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: command) { sends += 1 }
                throw Failure(message: "invalid command accepted")
            } catch let error as TerminalRunError {
                guard case .invalidCommand = error else { throw error }
            }
            do {
                _ = try runs.start(pane: PaneID(1), sessionID: "s", command: command) { sends += 1 }
                throw Failure(message: "invalid started command accepted")
            } catch let error as TerminalRunError {
                guard case .invalidCommand = error else { throw error }
            }
        }
        for milliseconds in [Int.min, -1, 0, 295_001, Int.max] {
            try await expectError(.invalidTimeout(milliseconds)) {
                try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok", timeoutMilliseconds: milliseconds) { sends += 1 }
            }
        }
        try require(sends == 0 && runs.pendingCount == 0, "invalid input sent bytes or reserved state")
        for command in [String(repeating: "a", count: 16_384), String(repeating: "🐈", count: 4_096)] {
            _ = try await runs.run(pane: PaneID(1), sessionID: "s", command: command, timeoutMilliseconds: 295_000) {
                try complete(runs, screen: "")
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
        try require(claimed == line, "Claim changed command or included an input Return")
        do {
            _ = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true)
            throw Failure(message: "Command could be claimed twice")
        } catch TerminalRunError.replaced {}
        task.cancel()
        try await expectCancellation { try await task.value }
        try require(runs.pendingCount == 1, "Cancelling the wait retired the claimed operation")
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: line)) { "" }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) { "finished" }
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

    /// Validation happens before adoption. Afterwards the terminal session, not the caller, owns the operation.
    static func checkCallerIndependentAdoption() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        var callerLive = true
        let id = try runs.start(pane: PaneID(1), sessionID: "s", command: "adopted",
            validateCaller: { if !callerLive { throw CancellationError() } }, send: { callerLive = false })
        try complete(runs, screen: "session owned")
        try require(try runs.result(id).text == "session owned", "caller retirement destroyed adopted work")
        callerLive = false
        var sends = 0
        do {
            _ = try runs.start(pane: PaneID(1), sessionID: "s", command: "never",
                validateCaller: { if !callerLive { throw CancellationError() } }, send: { sends += 1 })
            throw Failure(message: "Retired caller adopted work")
        } catch is CancellationError {}
        try require(sends == 0 && runs.pendingCount == 0, "Retired caller sent input or retained an operation")
        print("PASS caller validated before adoption; adopted work survives caller retirement")
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
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: line), capture: capture)
        for sequence in [10, 11] {
            runs.observe(pane: pane, sessionID: "s", report: report(.prompt, sequence, exit: 0), capture: capture)
        }
        try require(runs.pendingCount == 1 && captures == 0, "non-subsequent prompt completed run")
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 12, exit: 0), capture: capture)
        try require(try await task.value.text == "matched" && captures == 1, "matching completion failed")

        for afterMatch in [false, true] {
            let (interrupted, sent) = try await start(runs)
            if afterMatch {
                runs.observe(pane: pane, sessionID: "s", report: report(.running, 1, command: sent)) { "never" }
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

    /// Reports travel on separate connections, so they can arrive in any order.
    static func checkReorderedReports() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let pane = PaneID(1)

        // The prompt overtakes its running report.
        var (task, line) = try await start(runs, baseline: 5)
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 7, exit: 3)) { "early" }
        try require(runs.pendingCount == 1, "a prompt without its running report completed the run")
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 6, command: line)) { "late" }
        var result = try await task.value
        try require(result.exitCode == 3 && result.text == "late", "overtaking prompt lost its status")

        // Reports sent before the run belong to earlier commands, even when they arrive late.
        (task, line) = try await start(runs, baseline: 10)
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 9, command: "make")) { "never" }
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 10, exit: 1)) { "never" }
        try require(runs.pendingCount == 1, "an earlier command's late report affected the run")
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: line)) { "" }
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 12, exit: 0)) { "done" }
        try require(try await task.value.exitCode == 0, "baseline run did not complete")

        // A later command's prompt overtakes the run's own: end the run without claiming that status.
        (task, line) = try await start(runs, baseline: 10)
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: line)) { "" }
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 13, command: "later")) { "never" }
        try require(runs.pendingCount == 1, "a later command interrupted a run that already started")
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 14, exit: 9)) { "after later" }
        result = try await task.value
        try require(result.exitCode == nil, "another command's status was reported as the run's")
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 12, exit: 0)) { fatalError("finished run captured again") }

        // After the widget claimed the line, a later command's running report may overtake ours.
        (task, line) = try await start(runs, baseline: 10)
        _ = try runs.claimInput(pane: pane, sessionID: "s", emptyBuffer: true)
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 13, command: "later")) { "never" }
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: line)) { "" }
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 12, exit: 4)) { "claimed" }
        try require(try await task.value.exitCode == 4, "overtaking later command broke a claimed run")

        // The shell claims only at an empty prompt, so after a claim an earlier command's late report
        // means that command had finished; the run still executed and completes normally.
        (task, line) = try await start(runs, baseline: 10)
        _ = try runs.claimInput(pane: pane, sessionID: "s", emptyBuffer: true)
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: "true")) { "never" }
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 13, command: line)) { "" }
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: "true")) { "never" }
        runs.observe(pane: pane, sessionID: "s", report: report(.prompt, 14, exit: 5)) { "ran" }
        result = try await task.value
        try require(result.exitCode == 5, "a finished earlier command marked a claimed run as interrupted")
        // The prompt number of the run itself is never another command's start.
        (task, line) = try await start(runs, baseline: 10)
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: line)) { "" }
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 12, command: "impossible")) { "never" }
        try await expectError(.interrupted) { try await task.value }

        // Before the claim, any other command means the user got there first.
        (task, _) = try await start(runs, baseline: 10)
        runs.observe(pane: pane, sessionID: "s", report: report(.running, 11, command: "typed first")) { "never" }
        try await expectError(.interrupted) { try await task.value }
        try require(runs.pendingCount == 0, "reordering leaked a run")
        print("PASS reordered prompts, late earlier reports, overtaking later commands and claimed runs")
    }

    static func checkShellRunLines() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        for shell in ShellKind.allCases {
            let (task, line) = try await start(runs, shell: shell)
            try require(line.hasPrefix(shell == .fish ? "true __SLATE_RUN_" : ": __SLATE_RUN_"), "\(shell) run line")
            try require(!line.unicodeScalars.contains { $0.value < 32 }, "\(shell) run line has control characters")
            try require(try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true) == line, "\(shell) claim changed the line")
            let marker = String(line[...line.firstIndex(of: ";")!])
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: marker + " eval")) { "" }
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) { "\(shell)" }
            try require(try await task.value.text == "\(shell)", "\(shell) marker did not complete")
        }
        print("PASS zsh, bash and fish run lines carry their own marker and complete")
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
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: line)) { "not completion" }
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
            try await runs.run(pane: PaneID(1), sessionID: "new", command: "next") { sends += 1 }
        }
        runs.observe(pane: PaneID(1), sessionID: "new", report: report(.prompt, 1, exit: 0)) { sends += 100; return "wrong session" }
        try await expectError(.replaced) { try await first.value }
        try require(sends == 0, "duplicate sent input or replacement captured successor text")
        let (removed, _) = try await start(runs)
        runs.remove(pane: PaneID(1))
        runs.remove(pane: PaneID(1))
        try await expectError(.replaced) { try await removed.value }
        let (next, line) = try await start(runs, sessionID: "new")
        runs.observe(pane: PaneID(1), sessionID: "new", report: report(.running, 1, command: line)) { "" }
        runs.observe(pane: PaneID(1), sessionID: "new", report: report(.prompt, 2, exit: 0)) { "successor" }
        try require(try await next.value.text == "successor", "replacement prevented successor run")
        // A delivery failure is retained in the operation's status rather than lost.
        try await expectError(.submissionFailed) {
            try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok") { throw SendFailure() }
        }
        try require(runs.pendingCount == 0, "send failure leaked reservation")
        let failed = try runs.start(pane: PaneID(1), sessionID: "s", command: "ok") { throw SendFailure() }
        try require(try runs.status(failed).failure == .submissionFailed, "start lost its delivery failure")
        // Removal during a reentrant capture ends the operation as session loss, never a stale result.
        let reentrant = TerminalRuns()
        try await expectError(.replaced) {
            try await reentrant.run(pane: PaneID(1), sessionID: "s", command: "ok") {
                let line = try reentrant.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true)
                reentrant.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: line)) { "" }
                reentrant.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) {
                    reentrant.remove(pane: PaneID(1)); reentrant.close(); return "captured"
                }
                throw SendFailure()
            }
        }
        try require(reentrant.pendingCount == 0, "reentrant capture leaked")
        for close in [false, true] {
            let tracker = TerminalRuns()
            try await expectError(.replaced) {
                try await tracker.run(pane: PaneID(1), sessionID: "s", command: "ok") {
                    if close { tracker.close() } else { tracker.remove(pane: PaneID(1)) }
                    throw SendFailure()
                }
            }
        }
        print("PASS one run per pane, replaced session/removal, successor reuse, retained delivery failures and reentrant session loss")
    }

    static func checkTimeoutAndCancellation() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let began = ContinuousClock.now
        let (timedOut, line) = try await start(runs, timeout: 60)
        try await expectError(.timeout) { try await timedOut.value }
        try require(began.duration(to: .now) >= .milliseconds(50) && runs.pendingCount == 1, "deadline too early or discarded the operation")
        try require(runs.waitingCount == 0, "timed-out waiter was retained")
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: line)) { "" }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) { "after timeout" }
        try require(runs.pendingCount == 0, "late completion after timeout was not recorded")
        try await expectError(.timeout) {
            try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok", timeoutMilliseconds: 1) {}
        }
        runs.remove(pane: PaneID(1))
        let (cancelled, _) = try await start(runs, timeout: 80)
        cancelled.cancel()
        try await expectCancellation { try await cancelled.value }
        try require(runs.pendingCount == 1 && runs.waitingCount == 0, "cancellation discarded the operation or kept its waiter")
        runs.remove(pane: PaneID(1))
        let (successor, successorLine) = try await start(runs)
        try await Task.sleep(for: .milliseconds(120))
        try require(runs.pendingCount == 1, "stale cancelled timer ended successor")
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 20, command: successorLine)) { "" }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 21, exit: 0)) { "still alive" }
        try require(try await successor.value.text == "still alive", "successor lost to old deadline")
        var sends = 0
        let alreadyCancelled = Task {
            try await runs.run(pane: PaneID(1), sessionID: "s", command: "ok") { sends += 1 }
        }
        alreadyCancelled.cancel()
        try await expectCancellation { try await alreadyCancelled.value }
        try require(sends == 0 && runs.pendingCount == 0, "already cancelled caller sent input")
        print("PASS real timeout (including 1 ms boundary), cancellation and pre-entry cancellation end only the wait; stale timer isolation; no process-control input")
    }

    static func checkReconnectableWaits() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        let id = try runs.start(pane: PaneID(1), sessionID: "s", command: "echo test") {}
        try await expectError(.timeout) { try await runs.wait(id, timeoutMilliseconds: 1) }
        try require(runs.pendingCount == 1, "timeout discarded operation")
        let cancelled = Task { try await runs.wait(id, timeoutMilliseconds: 295_000) }
        try await eventually("operation waiter registration") { runs.waitingCount == 1 }
        cancelled.cancel()
        try await expectCancellation { try await cancelled.value }
        try require(runs.pendingCount == 1 && runs.waitingCount == 0, "cancellation discarded operation or retained waiter")
        try require(try runs.status(id).state == .awaitingInput, "status changed without a report")
        do { _ = try runs.result(id); throw Failure(message: "unfinished result returned") }
        catch TerminalRunError.notReady {}
        try complete(runs, screen: "reconnected")
        for _ in 0..<3 {
            try require(try await runs.wait(id, timeoutMilliseconds: 100).text == "reconnected", "result consumed")
        }
        try require(try runs.result(id).text == "reconnected", "result not repeatable")
        try require(try runs.status(id).state == .completed && runs.list().contains { $0.commandId == id }, "handle missing")
        do { _ = try runs.status(UUID()); throw Failure(message: "unknown handle resolved") }
        catch TerminalRunError.unavailable {}
        runs.remove(pane: PaneID(1))
        try require(try runs.result(id).text == "reconnected", "pane removal discarded a finished result")
        print("PASS timeout/cancellation leave session ownership intact; repeatable waits/status/result/list; unknown handles")
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
            try await runs.run(pane: PaneID(33), sessionID: "s", command: "ok") { throw Failure(message: "overloaded send") }
        }
        tasks[0].cancel()
        try await expectCancellation { try await tasks[0].value }
        try require(runs.pendingCount == 32, "cancelled wait released its operation slot")
        runs.remove(pane: PaneID(1))
        let (replacement, _) = try await start(runs)
        tasks[0] = replacement
        try require(runs.pendingCount == 32, "removed slot not reusable")
        runs.close()
        runs.close()
        for task in tasks { try await expectError(.replaced) { try await task.value } }
        try await expectError(.closed) {
            try await runs.run(pane: PaneID(33), sessionID: "s", command: "ok") { throw Failure(message: "closed send") }
        }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 99, exit: 0)) { fatalError("closed capture") }
        try require(runs.pendingCount == 0, "close leaked pending runs")
        print("PASS 32-run global cap, overload without dropping work, slot reuse after removal, idempotent close and closed admission")
    }

    static func checkRacesAndLifetime() async throws {
        let runs = TerminalRuns()
        defer { runs.close() }
        for index in 0..<24 {
            let (task, line) = try await start(runs, timeout: 10)
            if index.isMultiple(of: 3) { try await Task.sleep(for: .milliseconds(10)) }
            if index.isMultiple(of: 2) { task.cancel() }
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: line)) { "" }
            runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: 0)) { "race" }
            task.cancel()
            do {
                try require(try await task.value.text == "race", "race returned invalid result")
            } catch is CancellationError {
            } catch let error as TerminalRunError {
                try require(error == .timeout, "race returned unexpected error")
            }
            try require(runs.pendingCount == 0 && runs.waitingCount == 0, "race leaked an operation or waiter")
        }
        var owned: TerminalRuns? = TerminalRuns()
        weak let weakRuns = owned
        var task: Task<TerminalRunResult, Error>? = Task { [tracker = owned!] in
            try await tracker.run(pane: PaneID(1), sessionID: "s", command: "ok", timeoutMilliseconds: 295_000) {}
        }
        try await eventually("owned run registration") { owned!.waitingCount == 1 }
        task!.cancel()
        try await expectCancellation { try await task!.value }
        task = nil
        owned = nil
        try await eventually("cancelled timer retained tracker") { weakRuns == nil }
        print("PASS completion/cancellation/deadline races and tracker release after maximum-deadline cancellation")
    }

    /// Starts a blocking run and returns its unclaimed run line, as the shell widget would claim it.
    static func start(_ runs: TerminalRuns, pane: PaneID = PaneID(1), sessionID: String = "s", timeout: Int = 5_000,
                      shell: ShellKind = .zsh, baseline: Int? = nil) async throws -> (Task<TerminalRunResult, Error>, String) {
        var sent = false
        let task = Task {
            try await runs.run(pane: pane, sessionID: sessionID, command: "echo test", timeoutMilliseconds: timeout,
                               shell: shell, baseline: baseline) { sent = true }
        }
        try await eventually("run did not send") { sent }
        let status = try unwrap(runs.list().last { $0.paneId == pane && !$0.state.isFinished }, "run was not adopted")
        return (task, shell.runLine(status.commandId, command: "echo test"))
    }

    /// Claims and completes the pane 1 operation in session "s".
    static func complete(_ runs: TerminalRuns, screen: String) throws {
        let line = try runs.claimInput(pane: PaneID(1), sessionID: "s", emptyBuffer: true)
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.running, 1, command: line)) { "early" }
        runs.observe(pane: PaneID(1), sessionID: "s", report: report(.prompt, 2, exit: nil)) { screen }
    }

    static func markerPrefix(_ line: String) throws -> String {
        let prefix = ": __SLATE_RUN_"
        guard line.hasPrefix(prefix), let semicolon = line.firstIndex(of: ";") else {
            throw Failure(message: "missing marker")
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

    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    struct Failure: Error { let message: String }
    struct SendFailure: Error { }
}
