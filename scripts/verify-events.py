#!/usr/bin/env python3
"""Actual IPC event replay, long polls, identity protection, cancellation and CLI streaming."""
import concurrent.futures
import json
import os
import pathlib
import select
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"
CLI = APP.parent.parent / "Helpers/slate-term"


def eventually(label, condition, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.03)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix="slate-events-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / "ready"
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SLATE_TERM_")}
    environment.update(SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                       SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(directory / "config.toml"))
    with (ROOT / "artifacts/events-process.log").open("w") as log:
        app = None
        watch = None

        def start():
            global app
            ready.unlink(missing_ok=True)
            app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
            eventually("App readiness", lambda: ready.exists() and app.poll() is None)
            environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

        def stop():
            if app is not None and app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait(timeout=5)

        try:
            start()

            def cli(*args, success=True):
                result = subprocess.run([str(CLI), *args, "--json"], env=environment, capture_output=True, text=True, timeout=30)
                if not success:
                    assert result.returncode != 0, args
                    return result.stderr
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli("rpc", method, "--params", json.dumps(params))

            head = cli("events", "head")["cursor"]
            assert cli("events", "poll", "--wait-milliseconds", "0")["events"] == []
            cli("panes", "split", "--right", "--pane", "p1")
            changes = cli("events", "poll", "--after", head, "--topic", "host.workspace.*", "--wait-milliseconds", "0")
            assert changes["events"] and all(event["source"] == {"kind": "host"} for event in changes["events"])
            cli("events", "emit", "--topic", "host.workspace.changed", "--payload", "{}", success=False)
            cli("rpc", "events.emit", "--params", json.dumps({"topic": "test.forged", "source": {"kind": "host"}}), success=False)
            cli("events", "emit", "--topic", "test.large", "--payload", json.dumps("x" * 20_000), success=False)
            cli("events", "poll", "--after", "invalid", "--wait-milliseconds", "0", success=False)
            cli("rpc", "events.poll", "--params", '{"topics":null}', success=False)
            cursor = cli("events", "head")["cursor"]
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(cli, "events", "poll", "--after", cursor, "--topic", "test.ready", "--wait-milliseconds", "5000")
                eventually("Poll is suspended", lambda: rpc("events.head")["pendingPolls"] == 1)
                cli("events", "emit", "--topic", "test.ignored", "--payload", "null")
                assert not pending.done(), "Unmatched publication completed a filtered poll"
                published = cli("events", "emit", "--topic", "test.ready", "--payload", '{"text":"日本語"}')
                received = pending.result(timeout=8)
            assert len(received["events"]) == 1 and received["events"][0] == published
            assert published["source"] == {"kind": "client"} and published["payload"] == {"text": "日本語"}
            assert rpc("events.head")["pendingPolls"] == 0
            replay = cli("events", "poll", "--after", cursor, "--topic", "test.*", "--limit", "1", "--wait-milliseconds", "0")
            assert replay["events"][0]["topic"] == "test.ignored"
            next_batch = cli("events", "poll", "--after", replay["cursor"], "--topic", "test.*", "--wait-milliseconds", "0")
            assert next_batch["events"] == [published]
            cursor = rpc("events.head")["cursor"]
            watch = subprocess.Popen([str(CLI), "events", "watch", "--after", cursor, "--topic", "test.watch", "--json"],
                                     env=environment, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
            eventually("CLI watch is polling", lambda: rpc("events.head")["pendingPolls"] == 1)
            cli("events", "emit", "--topic", "test.watch", "--payload", "42")
            readable, _, _ = select.select([watch.stdout], [], [], 5)
            assert readable, "Watch did not stream a JSON line"
            event = json.loads(watch.stdout.readline())
            assert event["topic"] == "test.watch" and event["payload"] == 42 and event["cursor"]
            eventually("Watch resumed polling", lambda: rpc("events.head")["pendingPolls"] == 1)
            os.killpg(watch.pid, signal.SIGTERM)
            watch.wait(timeout=5)
            eventually("Disconnect cancels the suspended poll", lambda: rpc("events.head")["pendingPolls"] == 0)
            old_cursor = rpc("events.head")["cursor"]
            stop()
            start()
            assert rpc("events.head")["cursor"].split(":")[0] != old_cursor.split(":")[0]
            failure = cli("events", "poll", "--after", old_cursor, "--wait-milliseconds", "0", success=False)
            assert "resync" in failure.lower(), failure
            print("PASS events: real IPC journal/replay, host identity, anti-spoofing, bounded payloads, long-poll filtering, ordered batches, streaming, disconnect cancellation and restart resync")
        finally:
            if watch is not None and watch.poll() is None:
                os.killpg(watch.pid, signal.SIGKILL)
                watch.wait(timeout=5)
            stop()
