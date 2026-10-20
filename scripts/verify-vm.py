#!/usr/bin/env python3
"""Build selected UI gates here; execute their prebuilt artifacts only in VMPal."""
import argparse
import contextlib
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
MACHINE = '/Applications/VMPal.app/Contents/Helpers/VMPalMachine.app/Contents/MacOS/VMPalMachine'
sys.path.insert(0, str(ROOT / 'scripts'))
from verification_gates import ALIASES, BY_NAME, GATES, select, validate
from vm_test_bundle import APP_GUEST_PATH, UPGRADE_APPS, app_provenance, app_tree_hash, selected_app

NATIVE = {gate.name: (Path(gate.command[1]).name, gate.product) for gate in GATES if gate.native}


def gates():
    result = {gate.name: list(gate.command) for gate in GATES}
    result.update({alias: result[name] for alias, name in ALIASES.items()})
    return result


def source_files():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    files = sorted({name for name in names.decode().split('\0') if name and (ROOT / name).is_file()})
    for name in files:
        if (ROOT / name).is_symlink() and not (ROOT / name).resolve().is_relative_to(ROOT):
            raise RuntimeError('Source symlink escapes repository: ' + name)
    return files


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(files):
    return {name: digest(ROOT / name) for name in files}


def checked(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


class Interrupted(KeyboardInterrupt):
    def __init__(self, signum):
        self.signum = signum
        super().__init__('Interrupted by signal ' + str(signum))


def interrupted(signum, _frame):
    raise Interrupted(signum)


def interruption_status(error):
    return 128 + getattr(error, 'signum', signal.SIGINT)


@contextlib.contextmanager
def deferred_interruptions():
    """Finish bounded teardown/receipts even if another cancellation arrives."""
    pending = []
    previous = {sig: signal.signal(sig, lambda signum, _frame: pending.append(signum))
                for sig in [signal.SIGINT, signal.SIGTERM]}
    try:
        yield pending
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


@contextlib.contextmanager
def finalization_guard(receipt, output, lock_held):
    with deferred_interruptions() as pending:
        try:
            yield
        except (Exception, KeyboardInterrupt) as error:
            receipt['finalizationError'] = str(error) or 'Interrupted'
            receipt['exitCode'] = (interruption_status(error) if isinstance(error, KeyboardInterrupt)
                                   else receipt['exitCode'] or 1)
            if lock_held():
                receipt['lockRetained'] = True
        finally:
            certificate = receipt.pop('_fullCertificate', None)
            target = ROOT / 'artifacts/verification.json'
            checks = ROOT / 'artifacts/verification-checks.txt'
            published = False
            try:
                # Publish only AFTER bounded teardown, never while cancellation is already pending.
                if certificate and receipt['exitCode'] == 0 and not pending:
                    temporary = target.with_suffix('.tmp.json')
                    temporary.write_text(json.dumps(certificate, indent=2) + '\n')
                    temporary.replace(target)
                    published = True
                    checks.write_text('\n'.join(certificate['checks']) + '\n')
                if pending:
                    receipt['interruptedDuringCleanup'] = list(pending)
                    receipt['exitCode'] = 128 + pending[-1]
                if published and receipt['exitCode']:
                    target.unlink(missing_ok=True)
                    checks.unlink(missing_ok=True)
                    published = False
                (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
                # A signal received during the publication/receipt I/O invalidates that commit too.
                if pending and receipt['exitCode'] != 128 + pending[-1]:
                    receipt['interruptedDuringCleanup'] = list(pending)
                    receipt['exitCode'] = 128 + pending[-1]
                    if published:
                        target.unlink(missing_ok=True)
                        checks.unlink(missing_ok=True)
                        published = False
                    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
                if published:
                    print('PASS complete suite: all ' + str(len(certificate['checks'])) + ' inventory gates', flush=True)
            except Exception as error:
                if published:
                    target.unlink(missing_ok=True)
                    checks.unlink(missing_ok=True)
                receipt['finalizationError'] = str(error)
                receipt['exitCode'] = receipt['exitCode'] or 1
                (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
            print('Results: ' + str(output), flush=True)


def process_snapshot():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,stat=,lstart=,command='], text=True).splitlines()
    result = {}
    for row in rows:
        fields = row.strip().split(None, 8)
        if len(fields) == 9:
            result[int(fields[0])] = dict(parent=int(fields[1]), state=fields[2],
                                          started=' '.join(fields[3:8]), command=fields[8])
    return result


def capture_owned(root, seeds=()):
    processes = process_snapshot()
    prefixes = {str(root) + '/', str(root).replace('/private/tmp/', '/tmp/', 1) + '/'}
    excluded = {os.getpid()}
    ancestor = os.getpid()
    while ancestor in processes and processes[ancestor]['parent'] not in excluded:
        ancestor = processes[ancestor]['parent']
        excluded.add(ancestor)
    # A cancellation handshake must not be killed by the interrupted runner's finally block.
    excluded |= {pid for pid, row in processes.items()
                 if 'verify-vm.py' in row['command'] and '--cleanup-guest' in row['command']}
    # caffeinate may exec Python and leave its assertion monitor as our child.
    excluded |= {pid for pid, row in processes.items() if row['parent'] == os.getpid()
                 and Path(row['command'].split()[0]).name == 'caffeinate'}
    ledger = root / '.vm-owned.json'
    persisted = ({int(pid): start for pid, start in json.loads(ledger.read_text()).items() if int(pid) not in excluded}
                 if ledger.exists() else {})
    owned = {pid for pid, row in processes.items() if pid not in excluded
             and (pid in seeds or any(prefix in row['command'] for prefix in prefixes)
                  or persisted.get(pid) == row['started'])}
    while True:
        descendants = {pid for pid, row in processes.items() if pid not in excluded and row['parent'] in owned}
        if descendants <= owned:
            break
        owned |= descendants
    identities = {**persisted, **{pid: processes[pid]['started'] for pid in owned}}
    if root.is_dir():
        temporary = ledger.with_name(ledger.name + '.' + str(os.getpid()))
        temporary.write_text(json.dumps(identities) + '\n')
        temporary.replace(ledger)
    return identities


def cleanup_apps(root, captured=None):
    """Verify every captured descendant, including reparented shells/Node/Python."""
    owned = captured if captured is not None else capture_owned(root)
    def live():
        return {pid for pid, row in process_snapshot().items() if pid in owned
                and row['started'] == owned[pid] and not row['state'].startswith('Z')}
    initial = live() if owned else set()
    remaining = initial
    for sig in [signal.SIGTERM, signal.SIGKILL]:
        remaining = live() if owned else set()
        for pid in remaining:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while remaining and time.monotonic() < deadline:
            remaining = live()
            if remaining:
                time.sleep(.1)
        remaining = live() if remaining else set()
        if not remaining:
            (root / '.vm-owned.json').unlink(missing_ok=True)
            return sorted(initial)
    raise RuntimeError('Owned processes survived cleanup: ' + str(sorted(remaining)))


def run_gate(command, log_path, timeout, env=None, ownership_root=None, append=False, track_descendants=True):
    root = ownership_root or ROOT
    with log_path.open('a' if append else 'w') as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        captured = None
        deadline = time.monotonic() + timeout
        try:
            while True:
                # Keep identities before parents exit/reparent helpers, not only at failure time.
                if track_descendants:
                    captured = capture_owned(root, seeds=(process.pid,))
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    status = process.wait(timeout=min(.25, remaining))
                    break
                except subprocess.TimeoutExpired:
                    pass
            # Host compiler drivers may leave shared SDK build services alive by design.
            leaked = cleanup_apps(root, captured=capture_owned(root)) if track_descendants else []
            captured = None
            if leaked:
                log.write('\nFAIL: gate leaked owned processes: ' + str(leaked) + '\n')
                status = status or 1
            return status
        except subprocess.TimeoutExpired:
            log.write('\nFAIL gate: deadline exceeded\n')
            captured = capture_owned(root, seeds=(process.pid,)) if track_descendants else None
            os.killpg(process.pid, signal.SIGINT)  # Let Python fixtures execute their finally blocks.
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            return 124
        finally:
            if process.poll() is None:
                if track_descendants:
                    captured = captured or capture_owned(root, seeds=(process.pid,))
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            if captured:
                cleanup_apps(root, captured=captured)


def require_guest():
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    if not model.startswith('VirtualMac'):
        raise SystemExit('Refusing guest execution outside a macOS VM')
    return model


def artifact_snapshot(directory):
    return {str(path.relative_to(directory)): (path.stat().st_mtime_ns, path.stat().st_size)
            for path in directory.rglob('*') if path.is_file()
            and path.relative_to(directory).parts[0] != 'gates'
            and path.name not in {'results.json', 'results.tmp.json'}}


def checkpoint_results(directory, results):
    temporary = directory / 'results.tmp.json'
    temporary.write_text(json.dumps(results, indent=2) + '\n')
    temporary.replace(directory / 'results.json')


def guest_main(plan):
    model = require_guest()
    artifacts = ROOT / 'artifacts'
    artifacts.mkdir(exist_ok=True)
    results = {'guestModel': model, 'guestOS': platform.mac_ver()[0], 'tests': {}, 'completed': False}
    exit_code = 1
    try:
        receipt = json.loads((ROOT / '.vm-receipt.json').read_text())
        for name, expected in {**receipt['sourceHashes'], **receipt['binaryHashes']}.items():
            if digest(ROOT / name) != expected:
                raise RuntimeError('Transferred artifact/source mismatch: ' + name)
        for role, provenance in receipt.get('upgradeApps', {}).items():
            if app_tree_hash(ROOT / provenance['guestPath']) != provenance['treeSHA256']:
                raise RuntimeError('Transferred upgrade app mismatch: ' + role)
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cg.CGPreflightScreenCaptureAccess.restype = ctypes.c_bool
        if not cg.CGPreflightScreenCaptureAccess():
            raise RuntimeError('Grant VMPal Tools Screen & System Audio Recording permission INSIDE the VM')
        deadline = time.monotonic() + 10
        while not cg.CGDisplayIsActive(cg.CGMainDisplayID()):
            if time.monotonic() >= deadline:
                raise RuntimeError('Guest display is asleep despite caffeinate; no UI gates were run')
            time.sleep(.1)
        checked(['/usr/sbin/screencapture', '-x', str(artifacts / 'display-preflight.png')])
        app = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app'
        if app.is_dir():
            checked(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                     '-f', str(app)])
        # Fail closed if a gate accidentally attempts to compile in the guest.
        blockers = ROOT / '.vm-bin'
        blockers.mkdir(exist_ok=True)
        for name in ['swift', 'swiftc', 'xcrun', 'xcodebuild']:
            path = blockers / name
            path.write_text('#!/bin/sh\necho "FAIL: guest compilation is disabled" >&2\nexit 125\n')
            path.chmod(0o755)
        os.environ['PATH'] = str(blockers) + ':' + os.environ['PATH']
        os.environ['SLATE_VM_PREBUILT'] = '1'
        os.environ.pop('SLATE_VM_BUILD_ONLY', None)
        os.environ['SLATE_VM_SCREENSHOT_CHECK'] = str(ROOT / '.build/vm-tests/check-screenshot')
        checkpoint_results(artifacts, results)
        for name, command in plan['tests'].items():
            print('VM RUN ' + name, flush=True)
            before = artifact_snapshot(artifacts)
            command = [str(ROOT / arg) if arg.startswith('scripts/') else arg for arg in command]
            status = run_gate(command, artifacts / (name + '.log'), plan['timeout'],
                              env=guest_gate_environment(name, receipt))
            leaked = cleanup_apps(ROOT)
            if leaked:
                print('FAIL: cleaned up leaked test processes: ' + str(leaked), flush=True)
                status = status or 1
            results['tests'][name] = status
            for relative, stamp in artifact_snapshot(artifacts).items():
                if before.get(relative) != stamp:
                    target = artifacts / 'gates' / name / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(artifacts / relative, target)
            checkpoint_results(artifacts, results)
            print((artifacts / (name + '.log')).read_text(errors='replace'), flush=True)
            print('VM EXIT ' + name + ': ' + str(status), flush=True)
        results['completed'] = True
        exit_code = next((code if code > 0 else 128 - code for code in results['tests'].values() if code), 0)
    except (Exception, KeyboardInterrupt) as error:
        results['error'] = str(error) or 'Interrupted'
        print('FAIL VM runner: ' + results['error'], file=sys.stderr, flush=True)
        exit_code = interruption_status(error) if isinstance(error, KeyboardInterrupt) else 1
    finally:
        with deferred_interruptions() as pending:
            try:
                cleanup_apps(ROOT)
            except Exception as error:
                results['cleanupError'] = str(error)
                results['completed'] = False
                exit_code = exit_code or 1
            if pending:
                results['completed'] = False
                results['error'] = 'Interrupted during cleanup'
                exit_code = 128 + pending[-1]
            checkpoint_results(artifacts, results)
    return exit_code


LOCK = '/tmp/slate-ui-tests.lock'


def process_start(pid):
    """Start time of a local process, None when it no longer exists, '' when unknown.
    Comparing start times keeps a reused PID from looking like the original owner."""
    try:
        result = subprocess.run(['/bin/ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True, timeout=10)
    except Exception:
        return ''  # Unknown: a lock recording it is never treated as stale.
    started = result.stdout.strip() if isinstance(result.stdout, str) else ''
    return started or (None if result.returncode == 1 else '')


def lock_owner_alive(owner, host, start_of=process_start):
    """A lock is stale only when its owner ran on this host and that process is gone.
    Anything that cannot be checked, including old-format locks, counts as alive."""
    if not isinstance(owner, dict) or owner.get('host') != host:
        return True
    pid, started = owner.get('pid'), owner.get('started')
    if not isinstance(pid, int) or not isinstance(started, str) or not started:
        return True
    current = start_of(pid)
    return current == '' or current == started


def owned_by(run_id):
    """Shell test that the lock still belongs to `run_id`. The owner file has no final newline,
    which makes `read` fail, so compare its whole contents instead."""
    return '[ "$(cat ' + LOCK + '/owner 2>/dev/null)" = ' + shlex.quote(str(run_id)) + ' ]'


def record_owner(shell, owner):
    """Rewrite this run's owner record, for example once its guest directory exists."""
    shell(owned_by(owner['runId']) + ' && printf %s ' + shlex.quote(json.dumps(owner)) + ' > ' + LOCK + '/owner.json')


def release_lock(shell, run_id):
    """Remove the lock only if `run_id` still owns it."""
    shell('! ' + owned_by(run_id) + ' || rm -rf ' + LOCK)


def acquire_lock(shell, owner, wait_seconds, recover, sleep=time.sleep, clock=time.monotonic):
    """Take the guest lock, waiting for a live owner and recovering one whose host process died.
    Returns the recovered owners. `shell` raises CalledProcessError when a command fails."""
    record = shlex.quote(json.dumps(owner))
    take = ('mkdir ' + LOCK + ' && printf %s ' + shlex.quote(owner['runId']) + ' > ' + LOCK + '/owner && printf %s '
            + record + ' > ' + LOCK + '/owner.json')
    deadline = clock() + wait_seconds
    recovered, announced = [], None
    while True:
        try:
            shell(take)
            return recovered
        except subprocess.CalledProcessError:
            pass  # Held by another run, or the VM is busy with other commands.
        try:
            current = json.loads(shell('cat ' + LOCK + '/owner.json', capture=True).stdout)
        except (subprocess.CalledProcessError, ValueError):
            current = None
        if isinstance(current, dict) and not lock_owner_alive(current, owner['host']):
            # Stop what the dead run left in the guest before reusing the VM. If that cannot be
            # confirmed, keep the lock: its tests may still be running.
            recover(current)
            release_lock(shell, current.get('runId'))
            recovered.append(current)
            print('Recovered VM lock from ended run ' + str(current.get('runId')), file=sys.stderr, flush=True)
            continue
        if clock() >= deadline:
            raise RuntimeError('VM lock is held by ' + json.dumps(current) + '; inspect ' + LOCK + ' inside the VM')
        if announced != current:
            print('Waiting for VM lock held by ' + json.dumps(current), file=sys.stderr, flush=True)
            announced = current
        sleep(15)


def prebuilt_app_selection(args, selected):
    requested = getattr(args, 'app', None)
    if requested is None:
        return None
    if getattr(args, 'all', False) or any(gate.name == 'build' for gate in selected):
        raise ValueError('--app cannot be combined with --all or the build gate; prebuilt runs do not certify an app build')
    if not any(gate.requires_app for gate in selected):
        raise ValueError('--app requires a selected VM gate that runs the app')
    return selected_app(ROOT, requested)


def upgrade_app_selection(args, selected):
    requested = {'upgrade': getattr(args, 'upgrade_app', None),
                 'incompatible': getattr(args, 'incompatible_upgrade_app', None)}
    enabled = any(gate.name == 'layout-app-upgrades' for gate in selected)
    if enabled and not all(requested.values()):
        raise ValueError('layout-app-upgrades requires --upgrade-app and --incompatible-upgrade-app')
    if not enabled and any(requested.values()):
        raise ValueError('--upgrade-app and --incompatible-upgrade-app require the layout-app-upgrades gate')
    return {role: selected_app(ROOT, path) for role, path in requested.items() if path is not None}


def upgrade_provenance(apps):
    return {role: app_provenance(ROOT, path, guest_path=UPGRADE_APPS[role][0]) for role, path in apps.items()}


def guest_gate_environment(name, receipt):
    environment = dict(os.environ)
    for _, variable in UPGRADE_APPS.values():
        environment.pop(variable, None)
    if name == 'layout-app-upgrades':
        for role, (_, variable) in UPGRADE_APPS.items():
            environment[variable] = str(ROOT / receipt['upgradeApps'][role]['executable']['guestPath'])
    return environment


def host_main(args):
    available = gates()
    if args.list or (not args.tests and not getattr(args, 'all', False)):
        if any(getattr(args, key, None) is not None for key in ['app', 'upgrade_app', 'incompatible_upgrade_app']):
            raise SystemExit('Prebuilt app selection requires selected VM gates and cannot be combined with --list')
        validate(ROOT)
        for gate in GATES:
            print(gate.name + (' [host]' if gate.location == 'host' else ' [VM]'))
        print('app [alias for app-1]')
        return 0
    try:
        validate(ROOT)
        selected_gates = select(args.tests, complete=getattr(args, 'all', False))
        upgrade_apps = upgrade_app_selection(args, selected_gates)
        upgrades = upgrade_provenance(upgrade_apps)
        prebuilt_app = prebuilt_app_selection(args, selected_gates)
        prebuilt_provenance = app_provenance(ROOT, prebuilt_app) if prebuilt_app is not None else None
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
    selected = [gate.name for gate in selected_gates]
    vm_gates = [gate for gate in selected_gates if gate.location == 'vm']
    vm_names = [gate.name for gate in vm_gates]
    external_save_input = getattr(args, 'external_save_input', False)
    if external_save_input and 'layout-apps-ui' not in vm_names:
        raise SystemExit('--external-save-input requires the layout-apps-ui gate')
    external_browser_input = getattr(args, 'external_browser_input', False)
    if external_browser_input and 'web' not in vm_names:
        raise SystemExit('--external-browser-input requires the web gate')
    external_file_input = getattr(args, 'external_file_input', False)
    if external_file_input and 'web' not in vm_names:
        raise SystemExit('--external-file-input requires the web gate')
    if (args.timeout + 30) * len(vm_gates) + 60 > 86400:
        raise SystemExit('Selection exceeds VMPal\'s 24-hour command limit; select fewer tests or a shorter timeout')
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('This workflow requires an Apple Silicon macOS host')
    executable = args.vmpal or shutil.which('vmpal') or MACHINE
    cli = [executable] + (['--cli'] if Path(executable).name == 'VMPalMachine' else [])
    if vm_gates and not os.access(executable, os.X_OK):
        raise SystemExit('VMPal executable not found: ' + executable)
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    output = ROOT / 'artifacts/vm' / run_id
    output.mkdir(parents=True)
    receipt = {'vm': args.vm, 'tests': selected, 'fullSuite': getattr(args, 'all', False),
               'externalSaveInput': external_save_input,
               'externalFileInput': external_file_input, 'externalBrowserInput': external_browser_input,
               'sourceHashes': {}, 'binaryHashes': {}, 'hostBinaryHashes': {},
               'hostResults': {}, 'guestResults': {}, 'preparations': [],
               'completed': False, 'exitCode': 1}
    if prebuilt_provenance is not None:
        receipt['app'] = dict(prebuilt_provenance, selection='prebuilt', buildGateRun=False)
    if upgrades:
        receipt['upgradeApps'] = upgrades
    remote = None
    copied_results = False
    locked = False
    guest_process = None
    execution_started = False
    guest_stopped = True
    runtime = None
    package_bin = None
    lock = LOCK
    owner = {'runId': run_id, 'host': socket.gethostname(), 'pid': os.getpid(), 'worktree': str(ROOT)}
    host_env = dict(os.environ)
    host_env.pop('SLATE_VM_PREBUILT', None)
    host_env.pop('SLATE_VM_BUILD_ONLY', None)

    def vm_exec(command, capture=False, **kwargs):
        stdout = kwargs.pop('stdout', subprocess.PIPE if capture else None)
        return checked(cli + ['exec', args.vm, '--timeout', '2m', '--', *command],
                       text=True, stdout=stdout, **kwargs)

    def shell(text, capture=False):
        return vm_exec(['/bin/sh', '-c', text], capture=capture)

    def ensure_sources():
        now = source_hashes(source_files())
        changed = sorted(name for name in receipt['sourceHashes'].keys() | now.keys()
                         if receipt['sourceHashes'].get(name) != now.get(name))
        if changed:
            receipt['sourceChanged'] = changed
            raise RuntimeError('Source changed during verification: ' + ', '.join(changed))

    def host_gate(gate):
        print('HOST RUN ' + gate.name, flush=True)
        status = run_gate(list(gate.command), output / (gate.name + '.log'), 1800,
                          env=host_env, ownership_root=output, track_descendants=False)
        status = status if status >= 0 else 128 - status
        receipt['hostResults'][gate.name] = status
        ensure_sources()
        return status

    def aggregate_status():
        statuses = {**receipt['hostResults'], **receipt['guestResults']}
        receipt['completed'] = set(statuses) == set(selected)
        for name in selected:
            if statuses.get(name):
                status = statuses[name]
                return status if status > 0 else 128 - status
        return 0 if receipt['completed'] else 1

    try:
        files = source_files()
        receipt['sourceHashes'] = source_hashes(files)
        if receipt['fullSuite']:
            for name in ['verification.json', 'verification-checks.txt']:
                previous = ROOT / 'artifacts' / name
                if previous.exists():
                    shutil.copy2(previous, output / ('previous-' + name))
                    previous.unlink()
        if vm_gates:
            checked(cli + ['start', args.vm, '--background', '--wait', '--timeout', '2m'])
            home = shell('printf "%s" "$HOME"', capture=True).stdout
            runtime = home + '/Developer/slate-vm/runtime/bin'
            shell('test -x ' + shlex.quote(runtime + '/python3') + ' || { echo "Missing prepared guest runtime" >&2; exit 1; }')
        for gate in selected_gates:
            if gate.location == 'host' and gate.name != 'whitespace':
                status = host_gate(gate)
                if status and gate.name in {'engine', 'build'}:
                    raise RuntimeError('Build prerequisite failed: ' + gate.name)
        if vm_gates:
            needs_app = any(gate.requires_app for gate in vm_gates)
            needs_engine = (needs_app and prebuilt_app is None) or any(gate.native and gate.native.ghostty for gate in vm_gates)
            needs_package = any(gate.native and gate.native.package for gate in vm_gates)
            def build(command, env=None):
                print('HOST BUILD ' + shlex.join(command), flush=True)
                receipt['preparations'].append(command)
                with (output / 'host-build.log').open('a') as log:
                    log.write('\nHOST BUILD ' + shlex.join(command) + '\n')
                status = run_gate(command, output / 'host-build.log', 1800, env=env or host_env,
                                  ownership_root=output, append=True, track_descendants=False)
                if status:
                    raise subprocess.CalledProcessError(status, command)
            if needs_engine and 'engine' not in receipt['hostResults']:
                build(['bash', 'scripts/build-ghostty.sh'])
            if needs_app and prebuilt_app is None and 'build' not in receipt['hostResults']:
                build(['bash', 'scripts/build-app.sh'])
            elif needs_package and (not needs_app or prebuilt_app is not None):
                build(['swift', 'build', '--product', 'slate-term', '--jobs', '4'])
            if needs_package:
                package_bin = Path(checked(['swift', 'build', '--show-bin-path'], cwd=ROOT,
                                           text=True, stdout=subprocess.PIPE).stdout.strip())
            for gate in vm_gates:
                if gate.native:
                    build(list(gate.command), env=dict(host_env, SLATE_VM_BUILD_ONLY='1'))
            if 'web' in vm_names:
                (ROOT / '.build/vm-tests').mkdir(parents=True, exist_ok=True)
                build(['swiftc', 'Tests/WebOperations/CheckScreenshot.swift', '-o', '.build/vm-tests/check-screenshot'])
            ensure_sources()
            app = prebuilt_app or ROOT / APP_GUEST_PATH
            if needs_app:
                provenance = app_provenance(ROOT, app, configuration=None if prebuilt_app is not None else 'Debug')
                if prebuilt_provenance is not None and provenance != prebuilt_provenance:
                    raise RuntimeError('Prebuilt app changed before staging')
                receipt['app'] = dict(provenance, selection='prebuilt' if prebuilt_app is not None else 'host-build',
                                      buildGateRun='build' in receipt['hostResults'])
            if upgrade_provenance(upgrade_apps) != upgrades:
                raise RuntimeError('Upgrade app changed before staging')
            with tempfile.TemporaryDirectory(prefix='slate-vm-bundle-') as temporary:
                bundle = Path(temporary) / 'bundle'
                bundle.mkdir()
                for name in files:
                    source, target = ROOT / name, bundle / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if source.is_symlink():
                        target.symlink_to(os.readlink(source))
                    else:
                        shutil.copy2(source, target)
                from vm_test_bundle import stage_products
                receipt['binaryHashes'], receipt['hostBinaryHashes'] = stage_products(ROOT, bundle, vm_gates, package_bin, app=prebuilt_app, upgrade_apps=upgrade_apps)
                ensure_sources()
                if needs_app and app_tree_hash(app) != receipt['app']['treeSHA256']:
                    raise RuntimeError('App bundle changed during staging')
                if upgrade_provenance(upgrade_apps) != upgrades:
                    raise RuntimeError('Upgrade app changed during staging')
                plan = {'tests': {gate.name: list(gate.command) for gate in vm_gates}, 'timeout': args.timeout}
                if external_save_input:
                    plan['tests']['layout-apps-ui'].append('--external-save-input')
                if external_browser_input:
                    plan['tests']['web'].append('--external-browser-input')
                if external_file_input:
                    plan['tests']['web'].append('--external-file-input')
                (bundle / '.vm-plan.json').write_text(json.dumps(plan) + '\n')
                (bundle / '.vm-receipt.json').write_text(json.dumps(receipt) + '\n')
                archive = Path(temporary) / 'bundle.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    tar.add(bundle, arcname='.')
                # Lock only for guest work: host builds can take minutes and need no VM.
                def recover(stale):
                    remote_dir = stale.get('remote')
                    if isinstance(remote_dir, str) and re.fullmatch(r'/tmp/slate-ui\.[A-Za-z0-9]{8}', remote_dir):
                        script = remote_dir + '/source/scripts/verify-vm.py'
                        shell('test ! -f ' + shlex.quote(script) + ' || ' + shlex.quote(runtime + '/python3') + ' '
                              + shlex.quote(script) + ' --cleanup-guest')
                    receipt.setdefault('recoveredStaleLocks', []).append(stale)
                owner['started'] = process_start(os.getpid())
                acquire_lock(shell, owner, getattr(args, 'lock_wait', 0), recover)
                locked = True
                directory = shell('mktemp -d /tmp/slate-ui.XXXXXXXX', capture=True).stdout.strip()
                if not re.fullmatch(r'/tmp/slate-ui\.[A-Za-z0-9]{8}', directory):
                    raise RuntimeError('Unexpected guest temporary directory; refusing transfer/cleanup: ' + directory)
                remote = directory
                receipt['guestDirectory'] = remote
                # A later run that finds this owner dead cleans up this directory's processes.
                owner['remote'] = remote
                record_owner(shell, owner)
                checked(cli + ['cp', '--timeout', '5m', str(archive), args.vm + ':' + remote + '/bundle.tar.gz'])
            guest_command = ('set -eu; cd ' + shlex.quote(remote) + '; mkdir source; tar -xzf bundle.tar.gz -C source; '
                             'cd source; export PATH=' + shlex.quote(runtime + ':/usr/bin:/bin:/usr/sbin:/sbin') + '; '
                             'exec /usr/bin/caffeinate -dimsu python3 -u ' + shlex.quote(remote + '/source/scripts/verify-vm.py') +
                             ' --guest .vm-plan.json')
            with (output / 'vm-exec.log').open('w') as log:
                execution_started, guest_stopped = True, False
                guest_process = subprocess.Popen(cli + ['exec', args.vm, '--timeout', str((args.timeout + 30) * len(vm_gates) + 60) + 's',
                                                        '--', '/bin/sh', '-c', guest_command], stdout=log, stderr=subprocess.STDOUT,
                                                 start_new_session=True)
                status = guest_process.wait()
            receipt['exitCode'] = status if status >= 0 else 128 - status
        else:
            receipt['exitCode'] = aggregate_status()
        for gate in selected_gates:
            if gate.location == 'host' and gate.name == 'whitespace':
                host_gate(gate)
        if not vm_gates:
            receipt['exitCode'] = aggregate_status()
        ensure_sources()
    except (Exception, KeyboardInterrupt) as error:
        receipt['error'] = str(error) or 'Interrupted'
        receipt['exitCode'] = interruption_status(error) if isinstance(error, KeyboardInterrupt) else 1
        print('FAIL: ' + receipt['error'], file=sys.stderr)
    finally:
        with finalization_guard(receipt, output, lambda: locked):
            if guest_process is not None and guest_process.poll() is None:
                guest_process.send_signal(signal.SIGINT)
                try:
                    guest_process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    guest_process.kill()
                    guest_process.wait()
                    receipt['cancellationUnconfirmed'] = True
            if remote:
                if execution_started:
                    try:
                        with (output / 'guest-cleanup.log').open('w') as log:
                            vm_exec([runtime + '/python3', remote + '/source/scripts/verify-vm.py', '--cleanup-guest'],
                                    stderr=subprocess.STDOUT, stdout=log)
                        guest_stopped = True
                    except (subprocess.CalledProcessError, OSError):
                        receipt['guestCleanupUnconfirmed'] = True
                        receipt['exitCode'] = receipt['exitCode'] or 1
                try:
                    checked(cli + ['cp', '--timeout', '2m', args.vm + ':' + remote + '/source/artifacts/.', str(output)])
                    copied_results = True
                except (subprocess.CalledProcessError, OSError):
                    receipt['artifactCopyFailed'] = True
                    receipt['exitCode'] = receipt['exitCode'] or 1
                if copied_results:
                    try:
                        guest_result = json.loads((output / 'results.json').read_text())
                        receipt['guestResults'] = guest_result['tests']
                        if (not guest_result.get('completed') or set(guest_result['tests']) != set(vm_names)
                                or guest_result.get('cleanupError')):
                            receipt['guestResultsIncomplete'] = True
                            receipt['exitCode'] = receipt['exitCode'] or 1
                    except (OSError, ValueError, KeyError):
                        receipt['guestResultsUnavailable'] = True
                        receipt['exitCode'] = receipt['exitCode'] or 1
                if not receipt.get('error'):
                    receipt['exitCode'] = receipt['exitCode'] or aggregate_status()
                successful_guests = (copied_results and not receipt.get('guestResultsIncomplete')
                                     and not receipt.get('guestResultsUnavailable')
                                     and not any(receipt['guestResults'].values()))
                if successful_guests and guest_stopped and not args.keep_guest:
                    try:
                        shell('rm -rf ' + shlex.quote(remote))
                    except subprocess.CalledProcessError:
                        receipt['cleanupFailed'] = True
                        receipt['exitCode'] = receipt['exitCode'] or 1
                else:
                    print('Preserved guest files and fixture ownership metadata: ' + remote, file=sys.stderr)
            if locked and not guest_stopped:
                receipt['lockRetained'] = True
                print('VM lock retained: teardown unconfirmed; inspect ' + lock + ' inside the VM', file=sys.stderr)
            if locked and guest_stopped:
                try:
                    release_lock(shell, run_id)
                    locked = False
                except subprocess.CalledProcessError:
                    receipt['lockCleanupFailed'] = True
                    receipt['exitCode'] = receipt['exitCode'] or 1
            ensure_sources()
            if not receipt.get('error') and not receipt.get('exitCode'):
                receipt['exitCode'] = aggregate_status()
            else:
                aggregate_status()  # Record completeness even when the run failed.
            for name, expected in receipt['hostBinaryHashes'].items():
                if not (ROOT / name).is_file() or digest(ROOT / name) != expected:
                    receipt.setdefault('hostBinaryChanged', []).append(name)
                    receipt['exitCode'] = receipt['exitCode'] or 1
            if receipt.get('app'):
                app = Path(receipt['app']['hostPath'])
                if not app.is_dir() or app_tree_hash(app) != receipt['app']['treeSHA256']:
                    receipt['hostAppChanged'] = True
                    receipt['exitCode'] = receipt['exitCode'] or 1
                elif prebuilt_provenance is not None and app_provenance(ROOT, app) != prebuilt_provenance:
                    receipt['hostAppProvenanceChanged'] = True
                    receipt['exitCode'] = receipt['exitCode'] or 1
            if upgrade_provenance(upgrade_apps) != upgrades:
                receipt['hostUpgradeAppsChanged'] = True
                receipt['exitCode'] = receipt['exitCode'] or 1
            if receipt['fullSuite'] and receipt['completed'] and receipt['exitCode'] == 0:
                certificate = {'completedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                               'vm': args.vm, 'runDirectory': str(output), 'checks': selected,
                               'sources': receipt['sourceHashes'], 'binaries': receipt['binaryHashes'],
                               'hostBinaries': receipt['hostBinaryHashes']}
                receipt['_fullCertificate'] = certificate
    return receipt['exitCode']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tests', nargs='*', help='Test names from --list; no selection lists tests without running them')
    parser.add_argument('--list', action='store_true', help='List the complete gate inventory without starting a VM or building')
    parser.add_argument('--all', action='store_true', help='Run every inventory gate; compile on host and execute all native/UI gates in the VM')
    parser.add_argument('--app', type=Path, help='Run selected app VM gates with this absolute repository-owned prebuilt .app; excludes --all and build')
    parser.add_argument('--upgrade-app', type=Path, help='Repository-owned changed-build app for layout-app-upgrades')
    parser.add_argument('--incompatible-upgrade-app', type=Path, help='Repository-owned signed incompatible-ABI fixture for layout-app-upgrades')
    parser.add_argument('--vm', default=os.environ.get('SLATE_TEST_VM', 'slate-term'))
    parser.add_argument('--vmpal', help='VMPal CLI executable (bundled helper used if not on PATH)')
    parser.add_argument('--timeout', type=int, default=600, help='Seconds per guest test (default: 600)')
    parser.add_argument('--keep-guest', action='store_true', help='Keep the isolated guest run directory for debugging')
    parser.add_argument('--external-save-input', action='store_true',
                        help='Wait for VMPal input to confirm native save panels in layout-apps-ui')
    parser.add_argument('--external-browser-input', action='store_true', help='Wait for VMPal native download Save and popup login input in web')
    parser.add_argument('--external-file-input', action='store_true',
                        help='Wait for VMPal input to cancel and confirm native file pickers in web')
    parser.add_argument('--lock-wait', type=int, default=1800, metavar='SECONDS',
                        help='Wait this long for another run to release the VM (default: 1800)')
    parser.add_argument('--guest', help=argparse.SUPPRESS)
    parser.add_argument('--cleanup-guest', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    if args.timeout < 1 or args.timeout > 3600:
        parser.error('--timeout must be between 1 and 3600 seconds')
    if args.cleanup_guest:
        require_guest()
        with deferred_interruptions() as pending:
            cleanup_apps(ROOT)
            app = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app'
            if app.is_dir():
                checked(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                         '-u', str(app)])
        return 128 + pending[-1] if pending else 0
    if args.guest:
        return guest_main(json.loads(Path(args.guest).read_text()))
    return host_main(args)


if __name__ == '__main__':
    sys.exit(main())
