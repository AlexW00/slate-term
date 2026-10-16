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
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
MACHINE = '/Applications/VMPal.app/Contents/Helpers/VMPalMachine.app/Contents/MacOS/VMPalMachine'
NATIVE = {
    'terminal': ('verify-terminal.sh', '.build/terminal-gate/terminal-lifecycle'),
    'text-checking': ('verify-text-checking.sh', '.build/text-checking-gate/text-checking'),
    'browser-navigation': ('verify-browser-navigation.sh', '.build/browser-navigation-gate/browser-navigation'),
}
EXCLUDED = {'model-mutations'}  # Compiles deliberately mutated sources, not a UI gate.


def gates():
    result = {name: ['bash', 'scripts/' + script] for name, (script, _) in NATIVE.items()}
    for script in sorted((ROOT / 'scripts').glob('verify-*.py')):
        name = script.stem.removeprefix('verify-')
        if name not in EXCLUDED | {'vm'}:
            result[name] = ['python3', 'scripts/' + script.name]
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
            if pending:
                receipt['interruptedDuringCleanup'] = pending
                receipt['exitCode'] = 128 + pending[-1]
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


def run_gate(command, log_path, timeout):
    with log_path.open('w') as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        captured = None
        deadline = time.monotonic() + timeout
        try:
            while True:
                # Keep identities before parents exit/reparent helpers, not only at failure time.
                captured = capture_owned(ROOT, seeds=(process.pid,))
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    status = process.wait(timeout=min(.25, remaining))
                    break
                except subprocess.TimeoutExpired:
                    pass
            leaked = cleanup_apps(ROOT, captured=capture_owned(ROOT))
            captured = None
            if leaked:
                log.write('\nFAIL: gate leaked owned processes: ' + str(leaked) + '\n')
                status = status or 1
            return status
        except subprocess.TimeoutExpired:
            log.write('\nFAIL VM gate: deadline exceeded\n')
            captured = capture_owned(ROOT, seeds=(process.pid,))
            os.killpg(process.pid, signal.SIGINT)  # Let Python fixtures execute their finally blocks.
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            return 124
        finally:
            if process.poll() is None:
                captured = captured or capture_owned(ROOT, seeds=(process.pid,))
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            if captured:
                cleanup_apps(ROOT, captured=captured)


def require_guest():
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    if not model.startswith('VirtualMac'):
        raise SystemExit('Refusing guest execution outside a macOS VM')
    return model


def guest_main(plan):
    model = require_guest()
    artifacts = ROOT / 'artifacts'
    artifacts.mkdir(exist_ok=True)
    results = {'guestModel': model, 'tests': {}, 'completed': False}
    exit_code = 1
    try:
        receipt = json.loads((ROOT / '.vm-receipt.json').read_text())
        for name, expected in {**receipt['sourceHashes'], **receipt['binaryHashes']}.items():
            if digest(ROOT / name) != expected:
                raise RuntimeError('Transferred artifact/source mismatch: ' + name)
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
        for name, command in plan['tests'].items():
            print('VM RUN ' + name, flush=True)
            command = [str(ROOT / arg) if arg.startswith('scripts/') else arg for arg in command]
            status = run_gate(command, artifacts / (name + '.log'), plan['timeout'])
            leaked = cleanup_apps(ROOT)
            if leaked:
                print('FAIL: cleaned up leaked test processes: ' + str(leaked), flush=True)
                status = status or 1
            results['tests'][name] = status
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
            (artifacts / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return exit_code


def host_main(args):
    available = gates()
    if args.list or not args.tests:
        for name in sorted(available):
            print(name)
        return 0
    selected = list(dict.fromkeys(args.tests))
    unknown = set(selected) - available.keys()
    if unknown:
        raise SystemExit('Unknown tests: ' + ', '.join(sorted(unknown)) + '. Use --list.')
    if (args.timeout + 20) * len(selected) + 60 > 86400:
        raise SystemExit('Selection exceeds VMPal\'s 24-hour command limit; select fewer tests')
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('This workflow requires an Apple Silicon macOS host')
    executable = args.vmpal or shutil.which('vmpal') or MACHINE
    cli = [executable] + (['--cli'] if Path(executable).name == 'VMPalMachine' else [])
    if not os.access(executable, os.X_OK):
        raise SystemExit('VMPal executable not found: ' + executable)
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    output = ROOT / 'artifacts/vm' / run_id
    output.mkdir(parents=True)
    receipt = {'vm': args.vm, 'tests': selected, 'sourceHashes': {}, 'binaryHashes': {}, 'exitCode': 1}
    remote = None
    copied_results = False
    locked = False
    guest_process = None
    execution_started = False
    guest_stopped = True
    lock = '/tmp/slate-ui-tests.lock'

    def vm_exec(command, capture=False, **kwargs):
        stdout = kwargs.pop('stdout', subprocess.PIPE if capture else None)
        return checked(cli + ['exec', args.vm, '--timeout', '2m', '--', *command],
                       text=True, stdout=stdout, **kwargs)

    def shell(text, capture=False):
        return vm_exec(['/bin/sh', '-c', text], capture=capture)

    try:
        checked(cli + ['start', args.vm, '--background', '--wait', '--timeout', '2m'])
        home = shell('printf "%s" "$HOME"', capture=True).stdout
        runtime = home + '/Developer/slate-vm/runtime/bin'
        shell('test -x ' + shlex.quote(runtime + '/python3') + ' || { echo "Missing prepared guest runtime: ' + runtime + '" >&2; exit 1; }')
        # One UI run at a time across agents. Never break a stale/foreign lock automatically.
        shell('mkdir ' + lock + ' && printf %s ' + shlex.quote(run_id) + ' > ' + lock + '/owner')
        locked = True
        files = source_files()
        receipt['sourceHashes'] = source_hashes(files)
        with (output / 'host-build.log').open('w') as log:
            def build(command, **kwargs):
                print('HOST BUILD ' + shlex.join(command), flush=True)
                checked(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, **kwargs)
            needs_app = any(name not in NATIVE for name in selected)
            framework = ROOT / '.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a'
            if ('terminal' in selected or needs_app) and not framework.is_file():
                build(['bash', 'scripts/build-ghostty.sh'])
            if needs_app:
                build(['bash', 'scripts/build-app.sh'])
            elif 'browser-navigation' in selected:
                build(['swift', 'build', '--product', 'slate-term', '--jobs', '4'])
            for name in selected:
                if name in NATIVE:
                    env = dict(os.environ, SLATE_VM_BUILD_ONLY='1')
                    env.pop('SLATE_VM_PREBUILT', None)
                    build(['bash', 'scripts/' + NATIVE[name][0]], env=env)
            if 'web' in selected:
                (ROOT / '.build/vm-tests').mkdir(parents=True, exist_ok=True)
                build(['swiftc', 'Tests/WebOperations/CheckScreenshot.swift', '-o', '.build/vm-tests/check-screenshot'])
        if source_hashes(source_files()) != receipt['sourceHashes']:
            raise RuntimeError('Source changed during the build; rerun on a stable working tree')
        with tempfile.TemporaryDirectory(prefix='slate-vm-bundle-') as temporary:
            bundle = Path(temporary) / 'bundle'
            bundle.mkdir()
            for name in files:
                source, target = ROOT / name, bundle / name
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_symlink():
                    if not source.resolve().is_relative_to(ROOT):
                        raise RuntimeError('Source symlink escapes repository: ' + name)
                    target.symlink_to(os.readlink(source))
                else:
                    shutil.copy2(source, target)
            products = [NATIVE[name][1] for name in selected if name in NATIVE]
            if needs_app:
                products.append('.derived/Build/Products/Debug/Slate Terminal.app')
            if 'terminal' in selected:
                products.append('.build/bootstrap/ghostty/zig-out/share/ghostty')
            if 'web' in selected:
                products.append('.build/vm-tests/check-screenshot')
            for product in products:
                source, target = ROOT / product, bundle / product
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target, symlinks=True)
                    for path in source.rglob('*'):
                        if path.is_file():
                            receipt['binaryHashes'][str(path.relative_to(ROOT))] = digest(target / path.relative_to(source))
                else:
                    shutil.copy2(source, target)
                    receipt['binaryHashes'][product] = digest(target)
            if source_hashes(source_files()) != receipt['sourceHashes']:
                raise RuntimeError('Source changed while packaging; rerun on a stable working tree')
            plan = {'tests': {name: available[name] for name in selected}, 'timeout': args.timeout}
            (bundle / '.vm-plan.json').write_text(json.dumps(plan) + '\n')
            (bundle / '.vm-receipt.json').write_text(json.dumps(receipt) + '\n')
            archive = Path(temporary) / 'bundle.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(bundle, arcname='.')
            directory = shell('mktemp -d /tmp/slate-ui.XXXXXXXX', capture=True).stdout.strip()
            if not re.fullmatch(r'/tmp/slate-ui\.[A-Za-z0-9]{8}', directory):
                raise RuntimeError('Unexpected guest temporary directory; refusing transfer/cleanup: ' + directory)
            remote = directory
            receipt['guestDirectory'] = remote
            checked(cli + ['cp', '--timeout', '5m', str(archive), args.vm + ':' + remote + '/bundle.tar.gz'])
        guest_command = ('set -eu; cd ' + shlex.quote(remote) + '; mkdir source; tar -xzf bundle.tar.gz -C source; '
                         'cd source; export PATH=' + shlex.quote(runtime + ':/usr/bin:/bin:/usr/sbin:/sbin') + '; '
                         'exec /usr/bin/caffeinate -dimsu python3 -u ' + shlex.quote(remote + '/source/scripts/verify-vm.py') +
                         ' --guest .vm-plan.json')
        with (output / 'vm-exec.log').open('w') as log:
            execution_started, guest_stopped = True, False
            guest_process = subprocess.Popen(cli + ['exec', args.vm, '--timeout', str((args.timeout + 20) * len(selected) + 60) + 's',
                                                    '--', '/bin/sh', '-c', guest_command], stdout=log, stderr=subprocess.STDOUT,
                                             start_new_session=True)
            status = guest_process.wait()
        receipt['exitCode'] = status if status >= 0 else 128 - status
    except (Exception, KeyboardInterrupt) as error:
        receipt['error'] = str(error) or 'Interrupted'
        receipt['exitCode'] = interruption_status(error) if isinstance(error, KeyboardInterrupt) else 1
        print('FAIL: ' + receipt['error'], file=sys.stderr)
    finally:
        with finalization_guard(receipt, output, lambda: locked):
            if guest_process is not None and guest_process.poll() is None:
                # VMPal forwards cancellation into the guest; confirm teardown separately.
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
                    guest_result = json.loads((output / 'results.json').read_text())
                    copied_results = not guest_result.get('cleanupError')
                    if (not guest_result.get('completed') or set(guest_result['tests']) != set(selected)
                            or any(guest_result['tests'].values())):
                        receipt['exitCode'] = receipt['exitCode'] or 1
                except (subprocess.CalledProcessError, OSError, ValueError, KeyError):
                    receipt['artifactCopyFailed'] = True
                    receipt['exitCode'] = receipt['exitCode'] or 1
                if copied_results and guest_stopped and not args.keep_guest:
                    try:
                        shell('rm -rf ' + shlex.quote(remote))
                    except subprocess.CalledProcessError:
                        receipt['cleanupFailed'] = True
                        receipt['exitCode'] = receipt['exitCode'] or 1
                else:
                    print('Preserved guest files: ' + remote, file=sys.stderr)
            if locked and not guest_stopped:
                receipt['lockRetained'] = True
                print('VM lock retained: teardown unconfirmed; inspect ' + lock + ' inside the VM', file=sys.stderr)
            if locked and guest_stopped:
                try:
                    shell('read -r owner < ' + lock + '/owner; test "$owner" != ' + shlex.quote(run_id) + ' || rm -rf ' + lock)
                    locked = False
                except subprocess.CalledProcessError:
                    receipt['lockCleanupFailed'] = True
                    receipt['exitCode'] = receipt['exitCode'] or 1
    return receipt['exitCode']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tests', nargs='*', help='Test names from --list; no selection lists tests without running them')
    parser.add_argument('--list', action='store_true', help='List supported tests without starting a VM or building')
    parser.add_argument('--vm', default=os.environ.get('SLATE_TEST_VM', 'slate-term'))
    parser.add_argument('--vmpal', help='VMPal CLI executable (bundled helper used if not on PATH)')
    parser.add_argument('--timeout', type=int, default=600, help='Seconds per guest test (default: 600)')
    parser.add_argument('--keep-guest', action='store_true', help='Keep the isolated guest run directory for debugging')
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
