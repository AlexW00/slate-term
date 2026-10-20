#!/usr/bin/env python3
"""A killed GUI parent must not orphan its non-daemonizing plugin group."""
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/Frameworks/SlateRuntime.framework/Helpers/slate-term"


def eventually(label, condition, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.03)
    raise AssertionError(label)


def running(pid):
    result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True, timeout=2)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


with tempfile.TemporaryDirectory(prefix="slate-watchdog-", dir="/tmp") as temporary:
    root = pathlib.Path(temporary)
    script = root / "parent.py"
    script.write_text('''import os,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[2])
command="echo $$ > '$D/service'; /bin/sleep 60 & echo $! > '$D/grandchild'; wait".replace("$D",str(root))
worker=subprocess.Popen([sys.argv[1],"_plugin-worker","--parent-pid",str(os.getpid()),"/bin/sh","-c",command],start_new_session=True)
(root/"worker").write_text(str(worker.pid))
time.sleep(60)
''')
    with (ROOT / "artifacts/plugin-worker-process.log").open("w") as log:
        parent = subprocess.Popen(["python3", str(script), str(CLI), temporary], stdout=log, stderr=log, start_new_session=True)
        worker = None
        try:
            eventually("Worker and service did not start", lambda: all((root / name).exists() for name in ["worker", "service", "grandchild"]))
            worker, service, grandchild = [int((root / name).read_text()) for name in ["worker", "service", "grandchild"]]
            assert os.getpgid(worker) == worker and os.getpgid(service) == worker and os.getpgid(grandchild) == worker
            assert all(running(pid) for pid in [worker, service, grandchild])
            os.kill(parent.pid, signal.SIGKILL)
            parent.wait(timeout=3)
            eventually("Parent death left a plugin process running", lambda: not any(running(pid) for pid in [worker, service, grandchild]))
            print("PASS plugin watchdog: real SIGKILL of parent removes worker, service, and owned grandchild")
        finally:
            if parent.poll() is None:
                os.killpg(parent.pid, signal.SIGKILL)
                parent.wait(timeout=3)
            if worker is None and (root / "worker").exists():
                worker = int((root / "worker").read_text())
            if worker is not None and running(worker):
                os.killpg(worker, signal.SIGKILL)
