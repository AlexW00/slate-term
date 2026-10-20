#!/usr/bin/env python3
"""VM-only V1/V2 upgrade checks; requires two separately signed staged fixtures.

Runner: --tests layout-app-upgrades --app V1.app --upgrade-app V2.app
        --incompatible-upgrade-app ABI2.app
The incompatible fixture must have a valid signature, not edited unsigned metadata.
V1 uses the former New Tab fallback; V2 uses each layout app's display name.
"""
import ctypes
import fcntl
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import api_fixture
from api_fixture import AppFixture, ROOT, eventually
from plugin_package_fixture import package_fixture

spec = importlib.util.spec_from_file_location('layout_app_lifecycle', Path(__file__).with_name('verify-layout-apps.py'))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
RUNTIME = Path('Contents/Frameworks/SlateRuntime.framework')
PUBLISHER = 'anchor apple generic and certificate leaf[subject.OU] = "YWRT8FQN6F" and identifier "com.slateterm.runtime"'


class PageReceiptServer:
    """Record a real page Promise result outside the process being restarted."""
    def __enter__(self):
        self.receipts = []
        self.token = uuid.uuid4().hex
        owner = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                body = b'<!doctype html><title>Restart reply fixture</title><p>Owned update fixture</p>'
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                length = int(self.headers.get('Content-Length', '0'))
                if self.path != '/' + owner.token or not 0 < length <= 65536:
                    self.send_error(400)
                    return
                owner.receipts.append(json.loads(self.rfile.read(length)))
                self.send_response(204)
                self.send_header('Content-Length', '0')
                self.end_headers()
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/'
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def bundle_path(value):
    path = Path(value).resolve(strict=True)
    if path.suffix == '.app' and path.is_dir():
        return path
    assert path.parent.name == 'MacOS' and path.parent.parent.name == 'Contents', path
    return path.parent.parent.parent


def info(app):
    return plistlib.loads((app / RUNTIME / 'Resources/Info.plist').read_bytes())


def revision(app):
    return hashlib.sha256((app / RUNTIME / 'SlateRuntime').read_bytes()).hexdigest()


def executable(app):
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return app / 'Contents/MacOS' / metadata['CFBundleExecutable']


def signature(app):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + PUBLISHER, str(app / RUNTIME)], check=True, capture_output=True)


def shell_files(app):
    """Compare every stable-shell file, including its original signing resources."""
    answer = {}
    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app)
        if relative == RUNTIME or RUNTIME in relative.parents or (path.is_dir() and not path.is_symlink()):
            continue
        answer[str(relative)] = ('link:' + os.readlink(path)) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest()
    return answer


def requirement(app):
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)], capture_output=True, text=True, check=True)
    assert 'designated =>' in result.stdout, result.stderr
    return result.stdout


def refresh(app, parent, expected=None, succeeds=True):
    env = {key: value for key, value in app.env.items() if key != 'SLATE_TERM_SOCKET'}
    result = subprocess.run([str(app.executable), '--slate-refresh-only', '--expected-bundle-revision',
        expected or revision(app.bundle), '--slate-parent-path', str(parent)], env=env,
        capture_output=True, text=True, timeout=60)
    assert (result.returncode == 0) == succeeds, (result.returncode, result.stderr)
    return {'exitCode': result.returncode, 'message': result.stderr.strip()}



def pinned_restart_checks(app, parent, expected_version):
    """A changed selected parent must not strand a restart or weaken manual guards."""
    app.start()
    app.rpc('command.run', id='tab.title.set', tab=app.rpc('workspace.snapshot')['tabs'][0]['id'],
            title='Retained pinned-parent workspace')
    tabs = [(row['id'], row.get('manualTitle')) for row in app.rpc('workspace.snapshot')['tabs']]
    app.stop()
    original = revision(app.bundle)
    outer = shell_files(app.bundle)
    workspace = app.root / 'state/workspace.json'
    checks = {}
    cases = {
        'changed-revision': ['--slate-parent-path', str(parent), '--slate-expected-parent-revision', 'changed'],
        'changed-code-hash': ['--slate-parent-path', str(parent), '--slate-expected-parent-code-hash', 'changed'],
        'missing-parent': ['--slate-parent-path', str(parent.with_name('Missing Selected Parent.app')),
                           '--slate-expected-parent-revision', revision(parent)],
    }
    for name, arguments in cases.items():
        before = workspace.read_bytes()
        env = {key: value for key, value in app.env.items() if key != 'SLATE_TERM_SOCKET'}
        refused = subprocess.run([str(app.executable), '--slate-refresh-only',
            '--expected-bundle-revision', original, *arguments], env=env,
            capture_output=True, text=True, timeout=40)
        assert refused.returncode == 76, (name, refused.returncode, refused.stderr)
        assert workspace.read_bytes() == before
        app.start(arguments)
        assert app.rpc('version')['appVersion'] == expected_version
        assert [(row['id'], row.get('manualTitle')) for row in app.rpc('workspace.snapshot')['tabs']] == tabs
        assert revision(app.bundle) == original and shell_files(app.bundle) == outer
        assert not (app.root / 'refresh.plist').exists()
        app.stop()
        checks[name] = {'manualExitCode': 76, 'normalStartupRestored': True,
                        'runtimeAndShellUnchanged': True}
    return checks


def stop_parent(parent):
    if parent.process.poll() is None:
        parent.process.terminate()
        parent.process.wait(timeout=20)


def restart_parent(parent, installation):
    assert parent.process.poll() is not None
    parent.ready.unlink(missing_ok=True)
    parent.env.pop('SLATE_TERM_SOCKET', None)
    api_fixture.APP = executable(installation)
    api_fixture.CLI = installation / RUNTIME / 'Helpers/slate-term'
    parent.process = subprocess.Popen([str(api_fixture.APP)], env=parent.env, stdout=parent.log, stderr=parent.log, start_new_session=True)
    eventually('upgraded parent control socket', lambda: parent.ready.exists() and parent.process.poll() is None, timeout=40)
    parent.path = parent.ready.read_text().strip()
    parent.env['SLATE_TERM_SOCKET'] = parent.path
    assert parent.rpc('api.describe')['mode'] == 'standard'


def copy_runtime(source, destination):
    shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)


def default_tab_behavior(app, expected):
    """Exercise compiled behavior, including explicit-name priority and clearing the override."""
    before = [tab['id'] for tab in app.rpc('workspace.snapshot')['tabs']]
    created = app.rpc('command.run', id='tab.new')['tabId']
    try:
        tab = next(tab for tab in app.rpc('workspace.snapshot')['tabs'] if tab['id'] == created)
        assert tab['title'] == expected and tab['manualTitle'] is None, tab
        explicit = app.rpc('command.run', id='tab.title.set', tab=created, title='Explicit upgrade fixture')
        assert explicit['title'] == 'Explicit upgrade fixture'
        cleared = app.rpc('command.run', id='tab.title.clear', tab=created)
        assert cleared['title'] == expected and cleared['manualTitle'] is None, cleared
        return {'automatic': tab['title'], 'explicit': explicit['title'], 'cleared': cleared['title']}
    finally:
        app.rpc('command.run', id='tab.close', tab=created, force=True)
        assert [tab['id'] for tab in app.rpc('workspace.snapshot')['tabs']] == before


RUNNING_OWNED_APP = r"""
ObjC.import('AppKit'); function run(args) {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(args[0]);
    const expected = ObjC.unwrap($.NSURL.fileURLWithPath(args[1]).URLByResolvingSymlinksInPath.path);
    const ids = [];
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        if (!app.isTerminated && ObjC.unwrap(app.bundleURL.URLByResolvingSymlinksInPath.path) === expected)
            ids.push(Number(app.processIdentifier));
    }
    return JSON.stringify(ids);
}
"""


def release_relaunch_maintenance(app, held):
    """Keep the real helper's replacement blocked beyond the former ten-second limit."""
    lock = (app.root / 'maintenance.lock').resolve()
    identity = restart_process_info(app.pid)
    assert identity.get('path') == str(app.executable.resolve()), identity

    def waiting():
        current = restart_process_info(app.pid)
        assert current.get('killZeroSucceeded') and current.get('startIdentity') == identity.get('startIdentity'), current
        opened = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(app.pid), '-Fpn', str(lock)],
                                capture_output=True, text=True, timeout=5)
        assert opened.returncode in (0, 1), (opened.returncode, opened.stderr)
        return any(line.startswith('n') and Path(line[1:]).resolve() == lock for line in opened.stdout.splitlines())

    # An open maintenance descriptor while our exclusive lease is held proves actual contention.
    eventually('helper replacement opened the held maintenance lease', waiting, timeout=15)
    observed = time.monotonic()
    before = (app.root / 'state/workspace.json').read_bytes()
    before_revision = revision(app.bundle)
    samples = 0
    while time.monotonic() - observed < 12:
        current = restart_process_info(app.pid)
        assert current.get('killZeroSucceeded') and current.get('startIdentity') == identity.get('startIdentity'), current
        assert not list((app.root / 'control').glob('*.sock')), 'Waiting replacement published a control endpoint'
        assert (app.root / 'state/workspace.json').read_bytes() == before
        samples += 1
        time.sleep(.1)
    waited = time.monotonic() - observed
    assert revision(app.bundle) == before_revision, 'Waiting replacement changed its runtime'
    fcntl.flock(held, fcntl.LOCK_UN)
    return {'actualContentionObserved': True, 'waitedSecondsAfterObservation': waited,
            'normalWaitLimitSeconds': 60, 'samplesWithoutControlEndpoint': samples,
            'workspaceUnchangedWhileHeld': True, 'runtimeUnchangedWhileHeld': True}


def adopt_relaunched_app(app, old_pid, old_instance, maintenance_lease=None):
    """Observe the product helper's launch. Never issue another launch to make this check pass."""
    def relaunched():
        matches = json.loads(lifecycle.jxa(RUNNING_OWNED_APP, app.bundle_id, app.bundle.resolve()))
        replacements = [pid for pid in matches if pid != old_pid]
        assert len(replacements) <= 1, ('Ambiguous relaunched fixture', matches)
        if old_pid in matches or not replacements:
            return False
        app.pid = replacements[0]
        return True
    eventually('product restart helper launches exact owned app', relaunched, timeout=60)
    contention = release_relaunch_maintenance(app, maintenance_lease) if maintenance_lease is not None else None

    def ready():
        sockets = list((app.root / 'control').glob('*.sock'))
        if len(sockets) != 1:
            return False
        app.path = str(sockets[0])
        try:
            description = app.rpc('api.describe')
        except (OSError, ValueError):
            return False
        assert description['mode'] == 'layoutApp' and description['layoutAppID'] == app.record['layoutAppID'], description
        if description['appInstanceId'] == old_instance:
            return False
        app.instance = description['appInstanceId']
        return bool(app.rpc('workspace.get')['panes']) and bool(app.rpc('window.list')['windows'])
    eventually('relaunched app publishes a fresh owned socket and workspace', ready, timeout=40)
    app.env['SLATE_TERM_SOCKET'] = app.path
    return {'oldPID': old_pid, 'newPID': app.pid, 'oldInstance': old_instance, 'newInstance': app.instance,
            'bundleID': app.bundle_id, 'bundlePath': str(app.bundle), 'socket': app.path,
            'maintenanceContention': contention}


class RestartBSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid',
        'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


def restart_process_info(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    info = RestartBSDInfo()
    ctypes.set_errno(0)
    size = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    result = {'pid': pid, 'procInfoBytes': size, 'procInfoErrno': ctypes.get_errno()}
    if size == ctypes.sizeof(info):
        path = ctypes.create_string_buffer(4096)
        count = library.proc_pidpath(pid, path, len(path))
        result.update(startIdentity=f'{info.start_sec}:{info.start_usec}', parentPID=info.ppid,
                      status=info.status, path=os.path.realpath(os.fsdecode(path.value)) if count > 0 else None)
    try:
        os.kill(pid, 0)
        result['killZeroSucceeded'] = True
    except ProcessLookupError:
        result['killZeroSucceeded'] = False
    return result


RESTART_PARENT = r"""
import json, os, runpy, select, subprocess, sys
sys.path.insert(0, os.path.dirname(sys.argv[1]))
read_info = runpy.run_path(sys.argv[1])['restart_process_info']
identity = read_info(os.getpid())['startIdentity']
helper = subprocess.Popen([sys.argv[2], '--slate-relaunch-after', str(os.getpid()),
    '--slate-relaunch-identity', identity, '--slate-parent-path', sys.argv[3],
    '--slate-expected-parent-revision', sys.argv[4], '--slate-expected-parent-code-hash', sys.argv[5]],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
try:
    assert select.select([helper.stdout], [], [], 5)[0], 'Helper readiness timed out'
    assert helper.stdout.read(6) == b'READY\n', 'Helper did not acknowledge readiness'
    print(json.dumps({'parent': read_info(os.getpid()), 'helper': read_info(helper.pid)}), flush=True)
    assert select.select([sys.stdin], [], [], 5)[0], 'Driver release timed out'
    assert sys.stdin.readline() == 'exit\n', 'Unexpected driver release'
    os._exit(0)
finally:
    # This is our unreaped direct child, so its PID cannot have been reused.
    if helper.poll() is None:
        helper.terminate()
        helper.wait(timeout=5)
"""


def unreaped_parent_restart(app, source, evidence):
    """Keep a real exited parent unreaped; the installed helper must survive until reaping."""
    report = {'events': [], 'unreapedSamples': []}
    evidence['unreaped-parent-helper-restart'] = report
    destination = ROOT / 'artifacts/layout-app-unreaped-parent.json'
    queue = select.kqueue()
    python_parent = None
    parent_identity = helper_identity = None
    completed = False
    started = time.monotonic()
    note_exit, note_exitstatus = 0x80000000, 0x04000000

    def events(timeout):
        for event in queue.control(None, 8, timeout):
            report['events'].append({'pid': int(event.ident), 'fflags': int(event.fflags),
                'data': int(event.data), 'elapsed': time.monotonic() - started})

    def exited(pid):
        return any(event['pid'] == pid and event['fflags'] & note_exit for event in report['events'])

    def stop_owned(identity):
        if identity is None or exited(identity['pid']):
            return
        assert identity.get('startIdentity') and identity.get('path'), ('Missing cleanup identity', identity)
        current = restart_process_info(identity['pid'])
        if current.get('startIdentity') == identity.get('startIdentity') and current.get('path') == identity.get('path'):
            os.kill(identity['pid'], signal.SIGTERM)
            deadline = time.monotonic() + 5
            while not exited(identity['pid']) and time.monotonic() < deadline:
                events(min(0.1, max(0, deadline - time.monotonic())))
            assert exited(identity['pid']), ('Owned restart fixture did not exit', identity)
        else:
            assert not current['killZeroSucceeded'] or not current.get('startIdentity'), ('Restart fixture PID was reused', current)

    try:
        signature(source)
        before = app.rpc('workspace.snapshot')
        pane_ids = [row['id'] for row in app.panes()]
        tabs = [(row['id'], row.get('manualTitle')) for row in before['tabs']]
        old_instance = app.instance
        app.stop()
        report['stoppedAppInstance'] = old_instance
        signing = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(source / RUNTIME)],
                                 capture_output=True, text=True, check=True, timeout=10)
        hashes = [line.split('=', 1)[1] for line in (signing.stdout + signing.stderr).splitlines() if line.startswith('CDHash=')]
        assert len(hashes) == 1 and len(hashes[0]) == 40, ('Missing source runtime CDHash', hashes)
        environment = {key: value for key, value in app.env.items() if key != 'SLATE_TERM_SOCKET'}
        with (ROOT / 'artifacts/layout-app-unreaped-parent.log').open('w') as log:
            python_parent = subprocess.Popen([sys.executable, '-c', RESTART_PARENT, str(Path(__file__).resolve()),
                str(app.executable), str(source), revision(source), hashes[0]], env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
            parent_identity = restart_process_info(python_parent.pid)
            assert parent_identity.get('startIdentity') and parent_identity.get('path'), parent_identity
            queue.control([select.kevent(python_parent.pid, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT, fflags=note_exit | note_exitstatus)], 0, 0)
            assert select.select([python_parent.stdout], [], [], 10)[0], 'Python parent did not report helper readiness'
            ready = json.loads(python_parent.stdout.readline(4096))
            assert ready['parent']['startIdentity'] == parent_identity['startIdentity'], ready
            helper_identity = ready['helper']
            assert helper_identity.get('startIdentity') and helper_identity.get('path') == str(app.executable.resolve()), ready
            assert helper_identity['parentPID'] == python_parent.pid, ready
            report['ready'] = ready
            queue.control([select.kevent(helper_identity['pid'], filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT, fflags=note_exit | note_exitstatus)], 0, 0)
            python_parent.stdin.write(b'exit\n')
            python_parent.stdin.flush()
            deadline = time.monotonic() + 5
            while not exited(python_parent.pid) and time.monotonic() < deadline:
                events(min(0.1, max(0, deadline - time.monotonic())))
            assert exited(python_parent.pid), 'Python parent did not exit'
            # Keep this Popen referenced and do not poll/wait until the deliberate hold ends.
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                report['unreapedSamples'].append(restart_process_info(python_parent.pid))
                events(min(0.05, max(0, deadline - time.monotonic())))
            report['helperExitedBeforeReap'] = exited(helper_identity['pid'])
            report['helperBeforeReap'] = restart_process_info(helper_identity['pid'])
            matches = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', RUNNING_OWNED_APP,
                app.bundle_id, str(app.bundle.resolve())], capture_output=True, text=True, check=True, timeout=5)
            report['appsBeforeReap'] = json.loads(matches.stdout)
            assert report['unreapedSamples'] and all(row['killZeroSucceeded'] for row in report['unreapedSamples']), report
            assert any(row['procInfoBytes'] == 0 for row in report['unreapedSamples']), ('Zombie BSD-info gap was not exercised', report)
            assert not report['helperExitedBeforeReap'] and report['helperBeforeReap']['killZeroSucceeded'], ('Helper exited while its parent was unreaped', report)
            assert report['appsBeforeReap'] == [], ('Helper launched before its parent was reaped', report)
            report['parentExitCode'] = python_parent.wait(timeout=5)
            assert report['parentExitCode'] == 0, report
            report['relaunch'] = adopt_relaunched_app(app, python_parent.pid, old_instance)
            deadline = time.monotonic() + 5
            while not exited(helper_identity['pid']) and time.monotonic() < deadline:
                events(min(0.1, max(0, deadline - time.monotonic())))
            assert exited(helper_identity['pid']), ('Restart helper did not exit after relaunch', report)
            helper_exit = next(event['data'] for event in report['events'] if event['pid'] == helper_identity['pid'] and event['fflags'] & note_exit)
            report['helperExitStatus'] = helper_exit
            assert os.WIFEXITED(helper_exit) and os.WEXITSTATUS(helper_exit) == 0, report
            assert revision(app.bundle) == revision(source)
            assert app.rpc('version')['appVersion'] == info(source)['CFBundleShortVersionString']
            assert app.rpc('updates.get')['phase'] == 'current'
            assert [row['id'] for row in app.panes()] == pane_ids
            assert [(row['id'], row.get('manualTitle')) for row in app.rpc('workspace.snapshot')['tabs']] == tabs
            report.update(preservedPanes=pane_ids, preservedTabs=tabs, result='passed')
            completed = True
    except BaseException as error:
        report.update(result='failed', error=type(error).__name__ + ': ' + str(error)[:2000])
        raise
    finally:
        cleanup_errors = []
        try:
            if not completed:
                try:
                    stop_owned(helper_identity)
                except Exception as error:
                    cleanup_errors.append(str(error))
            if python_parent is not None:
                # EOF lets an unreleased Python parent clean its own helper before exiting.
                python_parent.stdin.close()
                try:
                    report['parentExitCode'] = python_parent.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    stop_owned(parent_identity)
                    report['parentExitCode'] = python_parent.wait(timeout=5)
                python_parent.stdout.close()
        except Exception as error:
            cleanup_errors.append(str(error))
        finally:
            if cleanup_errors:
                report['cleanupErrors'] = cleanup_errors
            queue.close()
            destination.write_text(json.dumps(report, indent=2) + '\n')
        assert not cleanup_errors, ('Owned restart fixture cleanup failed', cleanup_errors)


def capture_local_update(app, name, evidence):
    folder = ROOT / 'artifacts/layout-app-updates-ui'
    folder.mkdir(exist_ok=True)
    environment = {key: value for key, value in app.env.items() if key != 'SLATE_TERM_SOCKET'}
    activated = json.loads(lifecycle.jxa(lifecycle.LAUNCH.replace('configuration.activates = false;',
        'configuration.activates = true;'), app.bundle, json.dumps(environment)))
    assert activated.get('pid') == app.pid, activated
    shown = app.rpc('updates.show')
    assert shown['source'] == 'localParent' and shown['windowVisible'], shown
    eventually('local update window is active and key', lambda: (
        lambda state: state['appActive'] and state['windowKey'])(app.rpc('debug.updates')))
    paths = []
    for appearance in ['light', 'dark']:
        app.rpc('debug.updates', appearance=appearance)
        time.sleep(0.25)
        path = folder / (name + '-' + appearance + '.png')
        captured = app.rpc('debug.updates')
        subprocess.run(['/usr/sbin/screencapture', '-x', str(path)], check=True, capture_output=True)
        assert captured['source'] == 'localParent' and captured['phase'] == shown['phase'], captured
        assert path.is_file() and path.stat().st_size > 0, path
        paths.append(str(path.relative_to(ROOT)))
    evidence[name] = {'phase': shown['phase'], 'source': shown['source'], 'screenshots': paths,
                      'fixtureStateUsed': False}


def recovery_checks(app, v1, v2, evidence):
    runtime = app.bundle / RUNTIME
    baseline = shell_files(app.bundle)
    journal = app.root / 'refresh.plist'
    # Bootstrap owns these private paths; this fixture only synthesizes states at its swap boundary.
    app.root.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ['before-swap', 'after-swap', 'invalid-installed-rollback']:
        copy_runtime(v1 / RUNTIME, runtime)
        transaction = app.bundle.parent / ('.slate-runtime-' + str(uuid.uuid4()))
        transaction.mkdir(mode=0o700)
        stage = transaction / 'SlateRuntime.framework'
        if name == 'before-swap':
            shutil.copytree(v2 / RUNTIME, stage, symlinks=True)
            expected = revision(v1)
            selected_parent = v1
        else:
            shutil.copytree(v1 / RUNTIME, stage, symlinks=True)
            copy_runtime(v2 / RUNTIME, runtime)
            expected = revision(v2)
            selected_parent = v2
            if name == 'invalid-installed-rollback':
                metadata = runtime / 'Resources/Info.plist'
                value = plistlib.loads(metadata.read_bytes())
                value['FixtureTamper'] = True
                metadata.write_bytes(plistlib.dumps(value))
                expected = revision(v1)
                selected_parent = v1
        journal.write_bytes(plistlib.dumps({'staged': str(stage), 'previousRevision': revision(v1), 'nextRevision': revision(v2)}))
        journal.chmod(0o600)
        evidence[name] = refresh(app, selected_parent, expected=expected)
        assert revision(app.bundle) == expected
        assert not transaction.exists() and not journal.exists()
        assert shell_files(app.bundle) == baseline
        signature(app.bundle)
    assert not (app.root / 'state/workspace.json').exists(), 'Maintenance recovery started a workspace'


def main():
    lifecycle.require_vm()
    primary = bundle_path(api_fixture.APP)
    assert os.environ.get('SLATE_TERM_TEST_UPGRADE_APP'), 'Stage --upgrade-app for changed-release coverage'
    assert os.environ.get('SLATE_TERM_TEST_INCOMPATIBLE_APP'), 'Stage --incompatible-upgrade-app for signed ABI refusal coverage'
    v2 = bundle_path(os.environ['SLATE_TERM_TEST_UPGRADE_APP'])
    incompatible = bundle_path(os.environ['SLATE_TERM_TEST_INCOMPATIBLE_APP'])
    for app in [primary, v2, incompatible]:
        signature(app)
    assert int(info(primary)['SlateRuntimeABI']) == int(info(v2)['SlateRuntimeABI']) == 1
    assert int(info(incompatible)['SlateRuntimeABI']) != 1
    assert int(info(v2)['CFBundleVersion']) > int(info(primary)['CFBundleVersion'])
    assert revision(primary) != revision(v2), 'V1/V2 must contain different compiled runtime bytes'
    v1_version = info(primary)['CFBundleShortVersionString']
    v2_version = info(v2)['CFBundleShortVersionString']
    assert v1_version != v2_version, 'Use different release versions to prove the loaded runtime changed'
    evidence = {'v1Version': v1_version, 'v2Version': v2_version,
                'v1Build': info(primary)['CFBundleVersion'], 'v2Build': info(v2)['CFBundleVersion'],
                'v1Revision': revision(primary), 'v2Revision': revision(v2), 'checks': {}}
    try:
        with tempfile.TemporaryDirectory(prefix='slate-upgrade-install-') as directory, PageReceiptServer() as page_receipts:
            installation = Path(directory) / 'Slate Terminal.app'
            shutil.copytree(primary, installation, symlinks=True)
            api_fixture.APP = executable(installation)
            api_fixture.CLI = installation / RUNTIME / 'Helpers/slate-term'
            with AppFixture('layout-app-upgrades', startup_timeout=40) as parent, lifecycle.InstalledApps() as installed:
                parent.capture_contracts()
                assert parent.rpc('version')['appVersion'] == v1_version
                marker = parent.root / 'recipe-starts'
                layout_id = str(uuid.uuid4())
                definition = {'version': 1, 'id': layout_id, 'name': 'Upgrade fixture', 'tabs': [{
                    'name': 'Upgrade', 'layout': {'kind': 'pane', 'pane': 'p1'},
                    'panes': [{'id': 'p1', 'type': 'terminal', 'configuration': {'directory': str(parent.root),
                        'command': 'printf "started\\n" >> ' + str(marker)}}]}]}
                parent.rpc('layouts.create', definition=definition)
                parent.rpc('plugins.register', packagePath=package_fixture({'id': 'upgrade-fixture', 'title': 'Upgrade Fixture',
                    'commands': [{'id': 'noop', 'title': 'No-op', 'executable': '/usr/bin/true'}]}, parent.root))
                parent.rpc('plugins.register', packagePath=package_fixture({
                    'id': 'upgrade-page', 'title': 'Upgrade Page',
                    'source': {'kind': 'url', 'url': page_receipts.url}}, parent.root))
                apps = []
                for name in ['manual', 'catchup', 'running', 'recovery']:
                    record = parent.rpc('layouts.launcher', id=layout_id, path=str(installed.root / (name + '.app')), name=name)
                    apps.append(lifecycle.LayoutApp(parent, record, 'upgrade-' + name))
                manual, catchup, running, recovery = apps
                # Keep the updater restart independent from the recipe replay/cold-start control below.
                update_layout = json.loads(json.dumps(definition))
                update_layout['id'] = str(uuid.uuid4())
                update_layout['name'] = 'Local update fixture'
                update_layout['tabs'][0]['panes'][0]['configuration'].pop('command')
                parent.rpc('layouts.create', definition=update_layout)
                update_record = parent.rpc('layouts.launcher', id=update_layout['id'],
                    path=str(installed.root / 'Local Update.app'), name='Local Update')
                updating = lifecycle.LayoutApp(parent, update_record, 'local-update')
                apps.append(updating)
                page_record = parent.rpc('layouts.launcher', id=update_layout['id'],
                    path=str(installed.root / 'Page Update.app'), name='Page Update')
                page_updating = lifecycle.LayoutApp(parent, page_record, 'page-update')
                apps.append(page_updating)
                pinned_record = parent.rpc('layouts.launcher', id=update_layout['id'],
                    path=str(installed.root / 'Pinned Restart.app'), name='Pinned Restart')
                pinned = lifecycle.LayoutApp(parent, pinned_record, 'pinned-restart')
                apps.append(pinned)
                original_catchup_path = catchup.bundle
                catchup.move(original_catchup_path.with_name('moved-catchup.app'))
                replacement_record = parent.rpc('layouts.launcher', id=layout_id, path=str(original_catchup_path), name='Replacement')
                replacement = lifecycle.LayoutApp(parent, replacement_record, 'replacement')
                refresh(replacement, v2)
                apps.append(replacement)
                original_shells = {app.number: shell_files(app.bundle) for app in apps}
                original_requirements = {app.number: requirement(app.bundle) for app in apps}
                try:
                    evidence['checks']['pinned-parent-restart-fallback'] = pinned_restart_checks(pinned, v2, v1_version)
                    # Refusal must leave the existing signed runtime and stable shell unchanged.
                    original = revision(manual.bundle)
                    evidence['checks']['stale'] = refresh(manual, v2, expected='stale-revision', succeeds=False)
                    assert evidence['checks']['stale']['exitCode'] == 76
                    evidence['checks']['incompatible'] = refresh(manual, incompatible, succeeds=False)
                    assert evidence['checks']['incompatible']['exitCode'] == 77
                    tampered = Path(directory) / 'Tampered.app'
                    shutil.copytree(v2, tampered, symlinks=True)
                    metadata = tampered / RUNTIME / 'Resources/Info.plist'
                    value = plistlib.loads(metadata.read_bytes())
                    value['FixtureTamper'] = True
                    metadata.write_bytes(plistlib.dumps(value))
                    invalid = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(tampered / RUNTIME)], capture_output=True)
                    assert invalid.returncode != 0, 'Tamper fixture unexpectedly retained a valid signature'
                    evidence['checks']['tampered-parent'] = refresh(manual, tampered, succeeds=False)
                    assert revision(manual.bundle) == original and shell_files(manual.bundle) == original_shells[manual.number]
                    signature(manual.bundle)
                    recovery_checks(recovery, primary, v2, evidence['checks'])
                    evidence['checks']['changed-manual-refresh'] = refresh(manual, v2)
                    assert revision(manual.bundle) == revision(v2)
                    signature(manual.bundle)
                    running.start()
                    assert running.rpc('version')['appVersion'] == v1_version
                    eventually('V1 recipe startup', lambda: marker.exists() and marker.read_text().splitlines() == ['started'], timeout=40)
                    eventually('V1 terminal prompt', lambda: running.rpc('context.get', pane=running.pane('terminal'), scope='pane')['terminal']['isAtPrompt'], timeout=40)
                    data = running.rpc('plugins.data.get', id='upgrade-fixture')
                    running.rpc('plugins.data.patch', id='upgrade-fixture', expectedDataRevision=data['revision'], operations=[{'op': 'set', 'key': 'owner', 'value': 'V1 state'}])
                    panes = [row['id'] for row in running.panes()]
                    running_pid = running.pid
                    evidence['checks']['behavior-v1-before-cold-upgrade'] = default_tab_behavior(running, 'New Tab')
                    page_updating.start()
                    eventually('page updater terminal is idle', lambda: page_updating.rpc('context.get',
                        pane=page_updating.pane('terminal'), scope='pane')['terminal']['isAtPrompt'], timeout=40)
                    page_panel = page_updating.rpc('command.run', id='split.right',
                        pane=page_updating.pane('terminal'))['paneId']
                    page_updating.rpc('command.run', id='pane.type', pane=page_panel, type='upgrade-page', force=True)
                    eventually('registered update page bridge', lambda: page_updating.rpc('debug.pluginEval',
                        pane=page_panel, script='typeof workspace') == 'object')
                    assert page_updating.rpc('version')['appVersion'] == v1_version
                    page_panes = [row['id'] for row in page_updating.panes()]
                    updating.start()
                    eventually('updater V1 terminal is idle', lambda: updating.rpc('context.get',
                        pane=updating.pane('terminal'), scope='pane')['terminal']['isAtPrompt'], timeout=40)
                    assert updating.rpc('version')['appVersion'] == v1_version
                    evidence['checks']['behavior-v1-before-update-install'] = default_tab_behavior(updating, 'New Tab')
                    update_tabs = updating.rpc('workspace.snapshot')['tabs']
                    updating.rpc('command.run', id='tab.title.set', tab=update_tabs[0]['id'], title='Retained updater workspace')
                    update_panes = [row['id'] for row in updating.panes()]
                    private = updating.rpc('plugins.data.get', id='upgrade-fixture')
                    updating.rpc('plugins.data.patch', id='upgrade-fixture', expectedDataRevision=private['revision'],
                        operations=[{'op': 'set', 'key': 'owner', 'value': 'Updater private state'}])
                    updating.rpc('config.patch', values={'terminal.font_size': 17},
                        expectedSourceRevision=updating.rpc('config.get')['sourceRevision'])
                    override_file = updating.root / 'config/overrides.toml'
                    override_bytes = override_file.read_bytes()
                    initial_update = updating.rpc('updates.get')
                    assert initial_update['source'] == 'localParent' and initial_update['phase'] == 'current', initial_update
                    capture_local_update(updating, 'v1-current', evidence['checks'])
                    assert revision(running.bundle) == revision(primary)
                    evidence['checks']['running-bootstrap-refusal'] = refresh(running, v2, succeeds=False)
                    assert evidence['checks']['running-bootstrap-refusal']['exitCode'] == 75
                    assert revision(running.bundle) == revision(primary)
                    # Replace only our stopped parent installation, retaining its path and the child identities.
                    stop_parent(parent)
                    shutil.rmtree(installation)
                    shutil.copytree(v2, installation, symlinks=True)
                    restart_parent(parent, installation)
                    assert parent.rpc('version')['appVersion'] == v2_version
                    cursor = parent.rpc('events.head')['cursor']
                    eventually('stopped V1 app catches up to V2', lambda: revision(catchup.bundle) == revision(v2), timeout=40)
                    eventually('recovery app catches up to V2', lambda: revision(recovery.bundle) == revision(v2), timeout=40)
                    eventually('pinned fallback app later catches up to V2', lambda: revision(pinned.bundle) == revision(v2), timeout=40)
                    assert running.pid == running_pid and revision(running.bundle) == revision(primary)
                    assert running.rpc('version')['appVersion'] == v1_version
                    assert running.rpc('plugins.data.get', id='upgrade-fixture')['values'] == {'owner': 'V1 state'}
                    update_pid, update_instance = updating.pid, updating.instance
                    assert updating.rpc('version')['appVersion'] == v1_version
                    assert revision(updating.bundle) == revision(primary)
                    ready = updating.rpc('updates.get')
                    assert ready['source'] == 'localParent' and ready['phase'] == 'ready', ready
                    assert ready['currentVersion'] == v1_version and ready['release']['version'] == v2_version, ready
                    assert ready['release']['downloadURL'] == '' and ready['release']['contentLength'] == 0, ready
                    assert ready['release']['signature'] == '' and ready['receivedBytes'] == ready['expectedBytes'] == 0, ready
                    assert updating.rpc('updates.show')['updateId'] == ready['updateId']
                    checked = updating.rpc('updates.check')
                    assert checked['source'] == 'localParent' and checked['phase'] == 'ready', checked
                    assert checked['updateId'] == ready['updateId']
                    parent_update = next(row for row in parent.rpc('layoutApps.list') if row['layoutAppID'] == update_record['layoutAppID'])
                    assert parent_update['running'] and parent_update['updateReady'], parent_update
                    capture_local_update(updating, 'v1-local-update-ready', evidence['checks'])
                    updating.rpc('updates.download', updateId=ready['updateId'], error=-32051)
                    updating.rpc('updates.install', updateId=ready['updateId'], error=-32602)
                    updating.rpc('updates.install', updateId=ready['updateId'], confirm=False, error=-32602)
                    updating.rpc('updates.install', updateId='stale-update-offer', confirm=True, error=-32050)
                    updating.rpc('updates.install', updateId=ready['updateId'], confirm=True,
                        expectedInstanceId='stale-app-instance', error=-32050)
                    assert updating.rpc('updates.get')['phase'] == 'ready'
                    assert updating.pid == update_pid and revision(updating.bundle) == revision(primary)
                    assert updating.rpc('version')['appVersion'] == v1_version
                    evidence['checks']['local-parent-ready-without-live-replacement-or-download'] = {
                        'updateID': ready['updateId'], 'pid': update_pid, 'parentUpdateReady': parent_update['updateReady'],
                        'missingConsentRejected': True, 'staleOfferRejected': True, 'staleInstanceRejected': True}
                    parent.rpc('layoutApps.refresh', error=-32051, layoutAppID=running.record['layoutAppID'], expectedBundleRevision=revision(primary))
                    parent.rpc('layoutApps.refresh', error=-32050, layoutAppID=catchup.record['layoutAppID'], expectedBundleRevision=revision(primary))
                    events = parent.rpc('events.poll', after=cursor, topics=['host.layoutapp.refreshed'], recipient='all', scope='global', waitMilliseconds=0)['events']
                    assert any(event['payload']['layoutAppID'] == catchup.record['layoutAppID'] and event['payload']['origin']['kind'] == 'native' for event in events), events
                    evidence['checks']['parent-catchup-and-running-deferral'] = 'passed'
                    evidence['checks']['moved-app-catchup-with-newer-replacement-at-old-path'] = 'passed'
                    eventually('updater shell is idle before normal quit', lambda: updating.rpc('context.get',
                        pane=updating.pane('terminal'), scope='pane')['terminal']['isAtPrompt'], timeout=40)
                    with (updating.root / 'maintenance.lock').open('r+b') as maintenance_lease:
                        fcntl.flock(maintenance_lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        try:
                            installing = updating.rpc('updates.install', updateId=ready['updateId'], confirm=True,
                                expectedInstanceId=update_instance)
                            assert installing['phase'] == 'installing' and installing['source'] == 'localParent', installing
                        finally:
                            # Cleanup must discover the replacement even if the install response transport closes.
                            updating.pid = None
                        relaunch = adopt_relaunched_app(updating, update_pid, update_instance, maintenance_lease)
                    evidence['checks']['updates-install-helper-outwaits-maintenance-beyond-ten-seconds'] = relaunch['maintenanceContention']
                    assert revision(updating.bundle) == revision(v2)
                    assert updating.rpc('version')['appVersion'] == v2_version
                    assert [row['id'] for row in updating.panes()] == update_panes
                    restored_tabs = updating.rpc('workspace.snapshot')['tabs']
                    assert [tab['id'] for tab in restored_tabs] == [tab['id'] for tab in update_tabs]
                    assert restored_tabs[0]['manualTitle'] == 'Retained updater workspace'
                    assert updating.rpc('plugins.data.get', id='upgrade-fixture')['values'] == {'owner': 'Updater private state'}
                    assert override_file.read_bytes() == override_bytes
                    assert updating.rpc('config.get')['current']['terminal']['font_size'] == 17
                    assert updating.rpc('layouts.startupStatus') == []
                    eventually('restarted updater uses a real idle terminal', lambda: updating.rpc('context.get',
                        pane=updating.pane('terminal'), scope='pane')['terminal']['isAtPrompt'], timeout=40)
                    evidence['checks']['behavior-v2-after-update-install'] = default_tab_behavior(updating, 'Local Update')
                    current_update = updating.rpc('updates.get')
                    assert current_update['source'] == 'localParent' and current_update['phase'] == 'current', current_update
                    capture_local_update(updating, 'v2-current-after-restart', evidence['checks'])
                    parent_updated = next(row for row in parent.rpc('layoutApps.list') if row['layoutAppID'] == update_record['layoutAppID'])
                    assert parent_updated['running'] and not parent_updated['updateReady'], parent_updated
                    evidence['checks']['updates-install-normal-quit-helper-relaunch-and-private-state'] = relaunch
                    page_ready = page_updating.rpc('updates.get')
                    assert page_ready['phase'] == 'ready' and page_ready['source'] == 'localParent', page_ready
                    page_pid, page_instance = page_updating.pid, page_updating.instance
                    # Start after debug.pluginEval returns. The receipt is written by the page's Promise callback.
                    script = '''(() => { setTimeout(() => {
                        workspace.call('updates.install', {updateId: UPDATE_ID, confirm: true, expectedInstanceId: INSTANCE_ID}).then(result => {
                            const receipt = new XMLHttpRequest();
                            receipt.open('POST', RECEIPT_URL, false);
                            receipt.send(JSON.stringify({result, instance: INSTANCE_ID, callbackRan: true}));
                        });
                    }, 100); return true; })()'''.replace('UPDATE_ID', json.dumps(page_ready['updateId'])).replace(
                        'INSTANCE_ID', json.dumps(page_instance)).replace('RECEIPT_URL', json.dumps('/' + page_receipts.token))
                    try:
                        assert page_updating.rpc('debug.pluginEval', pane=page_panel, script=script) is True
                        eventually('registered page received install result before restart',
                            lambda: len(page_receipts.receipts) == 1, timeout=20)
                        received = page_receipts.receipts[0]
                        assert received['callbackRan'] and received['instance'] == page_instance, received
                        assert received['result']['phase'] == 'installing', received
                        assert received['result']['source'] == 'localParent', received
                    finally:
                        page_updating.pid = None
                    page_relaunch = adopt_relaunched_app(page_updating, page_pid, page_instance)
                    assert revision(page_updating.bundle) == revision(v2)
                    assert page_updating.rpc('version')['appVersion'] == v2_version
                    assert [row['id'] for row in page_updating.panes()] == page_panes
                    assert page_updating.rpc('updates.get')['phase'] == 'current'
                    evidence['checks']['registered-page-received-reply-before-real-restart'] = {
                        'receipt': received, 'relaunch': page_relaunch, 'persistedPanes': page_panes}
                    unreaped_parent_restart(page_updating, installation, evidence['checks'])
                    evidence['checks']['standard-parent-default-title-remains-unchanged'] = default_tab_behavior(parent, 'New Tab')
                    # With the parent stopped, only the cold-launch bootstrap can upgrade this child.
                    stop_parent(parent)
                    running.stop()
                    running.start()
                    assert revision(running.bundle) == revision(v2)
                    assert running.rpc('version')['appVersion'] == v2_version
                    assert [row['id'] for row in running.panes()] == panes
                    assert running.rpc('plugins.data.get', id='upgrade-fixture')['values'] == {'owner': 'V1 state'}
                    assert running.rpc('layouts.startupStatus') == [] and marker.read_text().splitlines() == ['started']
                    evidence['checks']['behavior-v2-after-cold-upgrade'] = default_tab_behavior(running, 'running')
                    evidence['checks']['cold-upgrade-preserves-workspace-without-command-replay'] = 'passed'
                    for app in apps:
                        assert shell_files(app.bundle) == original_shells[app.number], app.number
                        assert requirement(app.bundle) == original_requirements[app.number], app.number
                        assert revision(app.bundle) == revision(v2), app.number
                        signature(app.bundle)
                    evidence['checks']['all-outer-files-and-designated-requirements-unchanged'] = 'passed'
                    print('PASS changed signed runtime refresh, stopped catch-up, running deferral, cold upgrade and preserved workspace', flush=True)
                    print('PASS stale/ABI/signature refusal and pre-swap/post-swap/rollback journal recovery with stable shell identity', flush=True)
                    print('PASS behavior-changing V2 and real local-parent update consent, normal quit/helper relaunch, preserved state and update-window captures', flush=True)
                finally:
                    failures = []
                    for app in apps:
                        try:
                            app.cleanup()
                        except BaseException as error:
                            failures.append({'path': str(app.bundle), 'pid': app.pid, 'error': str(error)})
                    if failures:
                        evidence['cleanupFailures'] = failures
                        parent.preserve_for_children = True
                        raise AssertionError('Owned upgrade-app cleanup failed: ' + json.dumps(failures))
    finally:
        (ROOT / 'artifacts/layout-app-upgrades-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
