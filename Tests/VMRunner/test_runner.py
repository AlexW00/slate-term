"""Window-free tests for the host-build / guest-run boundary."""
import argparse
import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vm_runner', REPO / 'scripts/verify-vm.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class VMRunnerTests(unittest.TestCase):
    def test_host_build_does_not_adopt_shared_sdk_services(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)), \
                mock.patch.object(runner, 'capture_owned') as capture, mock.patch.object(runner, 'cleanup_apps') as cleanup:
            self.assertEqual(runner.run_gate([sys.executable, '-c', 'pass'], Path(temporary) / 'build.log', 5,
                                             track_descendants=False), 0)
            capture.assert_not_called()
            cleanup.assert_not_called()

    def test_host_build_timeout_still_stops_its_process_group(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)), \
                mock.patch.object(runner, 'capture_owned') as capture:
            self.assertEqual(runner.run_gate([sys.executable, '-c', 'import time; time.sleep(30)'],
                                             Path(temporary) / 'build.log', .1, track_descendants=False), 124)
            capture.assert_not_called()

    def test_full_certificate_is_withheld_after_cleanup_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            root = Path(temporary)
            (root / 'artifacts').mkdir()
            receipt = {'exitCode': 0, '_fullCertificate': {'checks': ['gate']}}
            with runner.finalization_guard(receipt, root, lambda: False):
                os.kill(os.getpid(), signal.SIGTERM)
            self.assertEqual(receipt['exitCode'], 143)
            self.assertFalse((root / 'artifacts/verification.json').exists())
            self.assertNotIn('PASS complete suite', output.getvalue())
            self.assertNotIn('_fullCertificate', json.loads((root / 'receipt.json').read_text()))

    def test_full_certificate_is_withdrawn_after_publication_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            root = Path(temporary)
            (root / 'artifacts').mkdir()
            original_replace = Path.replace
            def replace(path, destination):
                result = original_replace(path, destination)
                if Path(destination).name == 'verification.json':
                    os.kill(os.getpid(), signal.SIGTERM)
                return result
            receipt = {'exitCode': 0, '_fullCertificate': {'checks': ['gate']}}
            with mock.patch.object(Path, 'replace', replace), runner.finalization_guard(receipt, root, lambda: False):
                pass
            self.assertEqual(receipt['exitCode'], 143)
            self.assertFalse((root / 'artifacts/verification.json').exists())
            self.assertFalse((root / 'artifacts/verification-checks.txt').exists())
            self.assertNotIn('PASS complete suite', output.getvalue())

    def test_full_certificate_is_withdrawn_after_publication_io_failure(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)), \
                contextlib.redirect_stdout(io.StringIO()):
            root = Path(temporary)
            (root / 'artifacts').mkdir()
            original_write = Path.write_text
            def write(path, *args, **kwargs):
                if path.name == 'verification-checks.txt':
                    raise OSError('injected publication failure')
                return original_write(path, *args, **kwargs)
            receipt = {'exitCode': 0, '_fullCertificate': {'checks': ['gate']}}
            with mock.patch.object(Path, 'write_text', write), runner.finalization_guard(receipt, root, lambda: False):
                pass
            self.assertEqual(receipt['exitCode'], 1)
            self.assertFalse((root / 'artifacts/verification.json').exists())
            self.assertEqual(receipt['finalizationError'], 'injected publication failure')

    def test_full_certificate_commits_after_successful_finalization(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            root = Path(temporary)
            (root / 'artifacts').mkdir()
            receipt = {'exitCode': 0, '_fullCertificate': {'checks': ['gate']}}
            with runner.finalization_guard(receipt, root, lambda: False):
                pass
            self.assertEqual(receipt['exitCode'], 0)
            self.assertEqual(json.loads((root / 'artifacts/verification.json').read_text())['checks'], ['gate'])
            self.assertIn('PASS complete suite: all 1 inventory gates', output.getvalue())

    def test_layout_capture_requires_exact_usable_display_clamp(self):
        source = ast.parse((REPO / 'scripts/verify-saved-layouts.py').read_text())
        function = next(node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == 'expected_content_size')
        namespace = {}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<layout-fixture>', 'exec'), namespace)
        expected = namespace['expected_content_size']
        frame = {'maximumVisibleContentWidth': 1249, 'maximumVisibleContentHeight': 672}
        self.assertEqual(expected(frame, (1060, 680)), (1060, 672))
        self.assertEqual(expected(frame, (1000, 560)), (1000, 560))
        self.assertEqual(expected(dict(frame, maximumVisibleContentHeight=900), (1060, 680)), (1060, 680))
        for changes in [{'maximumVisibleContentWidth': 1059}, {'maximumVisibleContentHeight': 559}]:
            with self.assertRaises(AssertionError):
                expected(dict(frame, **changes), (1060, 680))

    def test_list_is_side_effect_free(self):
        args = argparse.Namespace(list=True, tests=[])
        with mock.patch.object(runner, 'checked') as execute, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(runner.host_main(args), 0)
        execute.assert_not_called()
        self.assertIn('terminal', output.getvalue())
        self.assertIn('browser', output.getvalue())
        self.assertNotIn('model-mutations', output.getvalue())
        self.assertNotIn('\nvm\n', output.getvalue())

    def test_unknown_test_never_starts_vm(self):
        args = argparse.Namespace(list=False, tests=['not-a-test'])
        with mock.patch.object(runner, 'checked') as execute:
            with self.assertRaisesRegex(SystemExit, 'Unknown test'):
                runner.host_main(args)
        execute.assert_not_called()

    def test_guest_mode_refuses_host_hardware(self):
        with mock.patch.object(runner.subprocess, 'check_output', return_value='Mac16,5\n'):
            with self.assertRaisesRegex(SystemExit, 'Refusing guest execution'):
                runner.guest_main({})

    def test_gate_failure_status_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)):
            status = runner.run_gate([sys.executable, '-c', 'print("owned failure"); raise SystemExit(7)'],
                                     Path(temporary) / 'gate.log', 5)
            self.assertEqual(status, 7)
            self.assertIn('owned failure', (Path(temporary) / 'gate.log').read_text())

    def test_gate_timeout_is_a_failure(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)):
            self.assertEqual(runner.run_gate([sys.executable, '-c', 'import time; time.sleep(30)'],
                                            Path(temporary) / 'gate.log', .1), 124)

    def test_cleanup_tracks_external_descendants_and_avoids_pid_reuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            processes = {
                111: dict(parent=1, state='S', started='original', command=str(root / 'App')),
                112: dict(parent=111, state='S', started='child', command='/usr/bin/python3 worker.py'),
                222: dict(parent=1, state='S', started='foreign', command='/Applications/Unrelated.app/App'),
            }
            def kill(pid, sig):
                if pid == 111:
                    # The root exits and this PID is reused; never signal its replacement.
                    processes[111] = dict(parent=1, state='S', started='replacement', command='/bin/foreign')
                    processes[112]['parent'] = 1
                elif pid == 112 and sig == signal.SIGKILL:
                    processes.pop(112)
            with mock.patch.object(runner, 'process_snapshot', side_effect=lambda: {p: dict(row) for p, row in processes.items()}), \
                    mock.patch.object(runner.os, 'kill', side_effect=kill) as send, \
                    mock.patch.object(runner.time, 'monotonic', side_effect=range(0, 100, 6)):
                self.assertEqual(runner.cleanup_apps(root), [111, 112])
            calls = {call.args for call in send.call_args_list}
            self.assertEqual(calls, {(111, signal.SIGTERM), (112, signal.SIGTERM), (112, signal.SIGKILL)})
            self.assertFalse((root / '.vm-owned.json').exists())

    def test_cleanup_excludes_ancestors_and_cancellation_handshake(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pid = os.getpid()
            rows = {
                pid: dict(parent=900, state='S', started='self', command=str(root / 'scripts/verify-vm.py')),
                900: dict(parent=1, state='S', started='parent', command='caffeinate ' + str(root / 'scripts/verify-vm.py')),
                901: dict(parent=1, state='S', started='cleanup', command=str(root / 'scripts/verify-vm.py') + ' --cleanup-guest'),
                902: dict(parent=pid, state='S', started='child', command=str(root / 'App')),
                903: dict(parent=pid, state='S', started='monitor', command='caffeinate python3 ' + str(root / 'scripts/verify-vm.py')),
            }
            (root / '.vm-owned.json').write_text(json.dumps({str(p): row['started'] for p, row in rows.items()}))
            with mock.patch.object(runner, 'process_snapshot', return_value=rows):
                self.assertEqual(runner.capture_owned(root), {902: 'child'})

    def test_persisted_orphan_is_a_root_for_new_descendants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / '.vm-owned.json').write_text(json.dumps({'111': 'orphan'}))
            rows = {
                111: dict(parent=1, state='S', started='orphan', command='/usr/bin/node worker.js'),
                112: dict(parent=111, state='S', started='child', command='/bin/sh worker.sh'),
            }
            with mock.patch.object(runner, 'process_snapshot', return_value=rows):
                self.assertEqual(runner.capture_owned(root), {111: 'orphan', 112: 'child'})

    def test_gate_tracks_helper_before_it_is_reparented(self):
        # Reparent only after the runner has observed the helper. A fixed sleep
        # tests scheduler luck rather than retention of a captured identity.
        code = ('import json,pathlib,subprocess,sys,time\n'
                'child = subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],start_new_session=True)\n'
                'ledger = pathlib.Path(sys.argv[1])\n'
                'while not ledger.exists() or str(child.pid) not in json.loads(ledger.read_text()):\n'
                '    time.sleep(.02)\n')
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'ROOT', Path(temporary)):
            log = Path(temporary) / 'gate.log'
            ledger = Path(temporary) / '.vm-owned.json'
            self.assertEqual(runner.run_gate([sys.executable, '-c', code, str(ledger)], log, 5), 1)
            self.assertIn('leaked owned processes', log.read_text())

    def test_signal_during_finalization_still_writes_failure_receipt(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            receipt = {'exitCode': 0}
            with runner.finalization_guard(receipt, Path(temporary), lambda: False):
                os.kill(os.getpid(), signal.SIGTERM)
                receipt['cleanupFinished'] = True
            saved = json.loads((Path(temporary) / 'receipt.json').read_text())
            self.assertEqual(saved['exitCode'], 143)
            self.assertTrue(saved['cleanupFinished'])

    def test_unexpected_finalization_error_keeps_receipt_and_lock(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            receipt = {'exitCode': 0}
            with runner.finalization_guard(receipt, Path(temporary), lambda: True):
                raise OSError('fixture cleanup error')
            saved = json.loads((Path(temporary) / 'receipt.json').read_text())
            self.assertNotEqual(saved['exitCode'], 0)
            self.assertTrue(saved['lockRetained'])

    def test_web_pixel_checker_has_prebuilt_and_default_branches(self):
        # Load only the actual function and its os import: importing the full UI gate would launch its app.
        tree = ast.parse((REPO / 'scripts/verify-web.py').read_text())
        nodes = [node for node in tree.body if (isinstance(node, ast.FunctionDef) and node.name == 'screenshot_checker')
                 or (isinstance(node, ast.Import) and any(alias.name == 'os' for alias in node.names))]
        namespace = {'ROOT': REPO}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), '<pixel-checker>', 'exec'), namespace)
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(namespace['screenshot_checker']()[0], 'swift')
        with mock.patch.dict(os.environ, {'SLATE_VM_SCREENSHOT_CHECK': '/prebuilt/check'}):
            self.assertEqual(namespace['screenshot_checker'](), ['/prebuilt/check'])

    def test_unclean_descendants_keep_ownership_ledger(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            row = {111: dict(parent=1, state='S', started='same', command=str(root / 'App'))}
            with mock.patch.object(runner, 'process_snapshot', return_value=row), \
                    mock.patch.object(runner.os, 'kill'), \
                    mock.patch.object(runner.time, 'monotonic', side_effect=range(0, 100, 6)):
                with self.assertRaisesRegex(RuntimeError, 'survived cleanup'):
                    runner.cleanup_apps(root)
            self.assertTrue((root / '.vm-owned.json').exists())

    def test_corrupted_bundle_fails_before_any_gui_or_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'input').write_text('changed')
            (root / '.vm-receipt.json').write_text(json.dumps({'sourceHashes': {'input': 'wrong'}, 'binaryHashes': {}}))
            with mock.patch.object(runner, 'ROOT', root), \
                    mock.patch.object(runner, 'require_guest', return_value='VirtualMac2,1'), \
                    mock.patch.object(runner, 'process_snapshot', return_value={}), \
                    mock.patch.object(runner.ctypes, 'CDLL') as graphics, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runner.guest_main({'tests': {}, 'timeout': 1}), 1)
                graphics.assert_not_called()
            self.assertIn('mismatch', json.loads((root / 'artifacts/results.json').read_text())['error'])

    def test_native_build_only_never_executes_test_binary(self):
        for name, (script, product) in runner.NATIVE.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'scripts').mkdir()
                shutil.copy2(REPO / 'scripts' / script, root / 'scripts' / script)
                shutil.copy2(REPO / 'scripts/native-gate.sh', root / 'scripts/native-gate.sh')
                for relative in ['Tests/TerminalRuns/TerminalRuns.swift', 'Native/WorkspaceWindow.swift',
                                 'Tests/TabOverview/TabOverview.swift']:
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('// fake compiler input\n')
                fake_bin = root / 'fake-bin'
                fake_bin.mkdir()
                marker = root / 'test-was-executed'
                swiftc = fake_bin / 'swiftc'
                swiftc.write_text('#!' + sys.executable + '\nimport pathlib,sys\n'
                                  'path=pathlib.Path(sys.argv[sys.argv.index("-o")+1])\n'
                                  'path.parent.mkdir(parents=True,exist_ok=True)\n'
                                  'path.write_text("#!/bin/sh\\nprintf launched >> ' + str(marker) + '\\n")\n'
                                  'path.chmod(0o755)\n')
                swiftc.chmod(0o755)
                swift = fake_bin / 'swift'
                swift.write_text('#!/bin/sh\nprintf "%s\\n" "' + str(root / '.build/fake') + '"\n')
                swift.chmod(0o755)
                (root / '.build/fake').mkdir(parents=True)
                (root / '.build/fake/SlateTermSettings.o').touch()
                cli = root / '.build/fake/slate-term'
                cli.write_text('#!/bin/sh\nprintf launched >> ' + str(marker) + '\n')
                cli.chmod(0o755)
                for name, message in [('git', 'fixture-commit'), ('xcrun', 'fixture Swift version'),
                                      ('sw_vers', 'fixture macOS version')]:
                    tool = fake_bin / name
                    tool.write_text('#!/bin/sh\necho ' + message + '\n')
                    tool.chmod(0o755)
                framework = root / '.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64'
                framework.mkdir(parents=True)
                (framework / 'libghostty-internal.a').touch()
                env = dict(os.environ, PATH=str(fake_bin) + ':' + os.environ['PATH'], SLATE_VM_BUILD_ONLY='1')
                env.pop('SLATE_VM_PREBUILT', None)
                result = subprocess.run(['bash', str(root / 'scripts' / script)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((root / product).is_file())
                self.assertFalse(marker.exists(), 'Host build-only mode executed a test!')

    def check_host_result(self, transport_status, guest_status, copy_fails=False, cleanup_fails=False,
                          cancelled=False, source_changes=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / runner.NATIVE['text-checking'][1]
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'fake prebuilt binary')
            calls = []
            def execute(command, **kwargs):
                calls.append((command, kwargs))
                out = ''
                if command[-1] == 'printf "%s" "$HOME"':
                    out = '/Users/guest'
                elif command[-1] == 'mktemp -d /tmp/slate-ui.XXXXXXXX':
                    out = '/tmp/slate-ui.UnitTest'
                elif command[-1] == '--cleanup-guest' and cleanup_fails:
                    raise subprocess.CalledProcessError(1, command)
                elif 'cp' in command and '/source/artifacts/.' in command[-2]:
                    if copy_fails:
                        raise subprocess.CalledProcessError(1, command)
                    (Path(command[-1]) / 'results.json').write_text(json.dumps({
                        'tests': {'text-checking': guest_status}, 'completed': True,
                    }))
                return subprocess.CompletedProcess(command, 0, stdout=out)
            args = argparse.Namespace(list=False, tests=['text-checking'], vm='test-vm', vmpal='/fake/vmpal',
                                      timeout=10, keep_guest=False)
            guest_process = mock.Mock()
            guest_process.wait.return_value = transport_status
            guest_process.poll.return_value = transport_status
            if cancelled:
                guest_process.wait.side_effect = [runner.Interrupted(signal.SIGTERM), 130]
                guest_process.poll.return_value = None
            hash_calls = []
            def changed_hashes(_files):
                hash_calls.append(1)
                return {'file': 'old' if len(hash_calls) == 1 else 'new'}
            hashes = (mock.patch.object(runner, 'source_hashes', side_effect=changed_hashes)
                      if source_changes else contextlib.nullcontext())
            def prepare(command, _log, _timeout, **kwargs):
                calls.append((command, kwargs))
                return 0
            with hashes, mock.patch.object(runner, 'ROOT', root), \
                    mock.patch.object(runner, 'validate'), \
                    mock.patch.object(runner, 'run_gate', side_effect=prepare), \
                    mock.patch('vm_test_bundle.stage_products', return_value=({}, {})), \
                    mock.patch.object(runner, 'gates', return_value={'text-checking': ['bash', 'scripts/verify-text-checking.sh']}), \
                    mock.patch.object(runner, 'source_files', return_value=[]), \
                    mock.patch.object(runner, 'checked', side_effect=execute), \
                    mock.patch.object(runner.platform, 'machine', return_value='arm64'), \
                    mock.patch.object(runner.sys, 'platform', 'darwin'), \
                    mock.patch.object(runner.os, 'access', return_value=True), \
                    mock.patch.object(runner.subprocess, 'Popen', return_value=guest_process) as launch, \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                status = runner.host_main(args)
            receipt = json.loads(next((root / 'artifacts/vm').glob('*/receipt.json')).read_text())
            build = next((command, kwargs) for command, kwargs in calls if command[0] == 'bash')
            self.assertEqual(build[1]['env']['SLATE_VM_BUILD_ONLY'], '1')
            self.assertFalse(any('SLATE_VM_PREBUILT' in kwargs.get('env', {}) for _, kwargs in calls))
            self.last_guest_process = guest_process
            self.guest_started = launch.called
            return status, receipt, calls

    def test_lock_is_taken_after_host_builds_and_records_the_guest_directory(self):
        status, receipt, calls = self.check_host_result(0, 0)
        self.assertEqual(status, 0)
        commands = [command[-1] if command[0] != 'bash' else 'HOST BUILD' for command, _ in calls]
        take = next(index for index, command in enumerate(commands) if command.startswith('mkdir ' + runner.LOCK))
        self.assertLess(max(index for index, command in enumerate(commands) if command == 'HOST BUILD'), take)
        recorded = next(command for command in commands if 'owner.json' in command and '/tmp/slate-ui.UnitTest' in command)
        self.assertIn('"pid": ' + str(os.getpid()), recorded)

    def test_host_returns_guest_failure_and_retrieves_logs(self):
        status, receipt, calls = self.check_host_result(7, 7)
        self.assertEqual(status, 7)
        self.assertEqual(receipt['exitCode'], 7)
        self.assertTrue(any('cp' in command and '/source/artifacts/.' in command[-2] for command, _ in calls))

    def test_success_requires_matching_guest_results(self):
        self.assertEqual(self.check_host_result(0, 0)[0], 0)
        self.assertNotEqual(self.check_host_result(0, 7)[0], 0)

    def test_unconfirmed_cleanup_retains_lock_and_guest_files(self):
        status, receipt, calls = self.check_host_result(0, 0, cleanup_fails=True)
        self.assertNotEqual(status, 0)
        self.assertTrue(receipt['lockRetained'])
        self.assertFalse(any('rm -rf' in command[-1] for command, _ in calls))

    def test_sigterm_cancels_guest_cli_then_confirms_teardown(self):
        status, receipt, calls = self.check_host_result(0, 0, cancelled=True)
        self.assertEqual(status, 143)
        self.last_guest_process.send_signal.assert_called_once_with(signal.SIGINT)
        self.assertTrue(any(command[-1] == '--cleanup-guest' for command, _ in calls))
        self.assertNotIn('lockRetained', receipt)

    def test_changed_source_never_starts_guest_tests(self):
        status, receipt, _ = self.check_host_result(0, 0, source_changes=True)
        self.assertNotEqual(status, 0)
        self.assertIn('Source changed', receipt['error'])
        self.assertFalse(self.guest_started)

    def test_artifact_copy_failure_is_not_success_or_destructive_cleanup(self):
        status, receipt, calls = self.check_host_result(0, 0, copy_fails=True)
        self.assertNotEqual(status, 0)
        self.assertTrue(receipt['artifactCopyFailed'])
        self.assertFalse(any(command[-1] == 'rm -rf /tmp/slate-ui.UnitTest' for command, _ in calls))


class FakeGuestLock:
    """The guest's lock directory, driven through the same shell commands the runner sends."""

    def __init__(self, owner=None, legacy=None):
        self.owner, self.legacy, self.commands = owner, legacy, []

    def __call__(self, command, capture=False):
        self.commands.append(command)
        if command.startswith('mkdir ' + runner.LOCK):
            if self.owner is not None or self.legacy is not None:
                raise subprocess.CalledProcessError(1, command)
            self.owner = json.loads(shlex.split(command.split('printf %s ')[-1].split(' > ')[0])[0])
            return subprocess.CompletedProcess(command, 0, stdout='')
        if command.startswith('cat ' + runner.LOCK):
            if self.owner is None:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(self.owner))
        if command.startswith('! [ "$(cat ' + runner.LOCK) and 'rm -rf' in command:
            if self.owner is not None and shlex.quote(str(self.owner.get('runId'))) in command:
                self.owner = None
            return subprocess.CompletedProcess(command, 0, stdout='')
        raise AssertionError('Unexpected guest command: ' + command)


class VMLockTests(unittest.TestCase):
    me = {'runId': 'new-run', 'host': 'this-mac', 'pid': 100, 'started': 'Fri Oct 17 10:00:00 2026'}

    def dead(self, **extra):
        return dict({'runId': 'old-run', 'host': 'this-mac', 'pid': 42, 'started': 'Fri Oct 17 09:00:00 2026'}, **extra)

    def test_only_a_dead_owner_on_this_host_is_stale(self):
        alive = lambda pid: 'Fri Oct 17 09:00:00 2026'
        gone = lambda pid: None
        reused = lambda pid: 'Fri Oct 17 11:00:00 2026'
        unknown = lambda pid: ''
        owner = self.dead()
        self.assertTrue(runner.lock_owner_alive(owner, 'this-mac', alive))
        self.assertFalse(runner.lock_owner_alive(owner, 'this-mac', gone))
        self.assertFalse(runner.lock_owner_alive(owner, 'this-mac', reused), 'A reused PID is not the owner')
        self.assertTrue(runner.lock_owner_alive(owner, 'this-mac', unknown), 'Unknown liveness is never broken')
        self.assertTrue(runner.lock_owner_alive(owner, 'other-mac', gone), 'Another host cannot be checked')
        self.assertTrue(runner.lock_owner_alive(None, 'this-mac', gone), 'Old-format locks are never broken')
        self.assertTrue(runner.lock_owner_alive(dict(owner, started=''), 'this-mac', gone))

    def test_process_start_distinguishes_live_and_ended_processes(self):
        self.assertTrue(runner.process_start(os.getpid()))
        child = subprocess.Popen([sys.executable, '-c', 'pass'])
        child.wait()
        self.assertIsNone(runner.process_start(child.pid))

    def test_free_lock_is_taken_with_an_owner_record(self):
        guest = FakeGuestLock()
        self.assertEqual(runner.acquire_lock(guest, self.me, 0, recover=mock.Mock()), [])
        self.assertEqual(guest.owner, self.me)

    def test_dead_owner_is_cleaned_up_then_replaced(self):
        guest = FakeGuestLock(owner=self.dead(remote='/tmp/slate-ui.AbCd1234'))
        recover = mock.Mock()
        with mock.patch.object(runner, 'lock_owner_alive', return_value=False), contextlib.redirect_stderr(io.StringIO()):
            recovered = runner.acquire_lock(guest, self.me, 0, recover)
        recover.assert_called_once()
        self.assertEqual(recovered[0]['runId'], 'old-run')
        self.assertEqual(guest.owner, self.me)

    def test_failed_guest_cleanup_keeps_the_dead_runs_lock(self):
        guest = FakeGuestLock(owner=self.dead())
        recover = mock.Mock(side_effect=subprocess.CalledProcessError(1, 'cleanup'))
        with mock.patch.object(runner, 'lock_owner_alive', return_value=False), self.assertRaises(subprocess.CalledProcessError):
            runner.acquire_lock(guest, self.me, 0, recover)
        self.assertEqual(guest.owner['runId'], 'old-run')

    def test_live_owner_is_waited_for_then_reported(self):
        guest = FakeGuestLock(owner=self.dead())
        clock = iter(range(0, 1000, 15))
        sleeps = []
        with mock.patch.object(runner, 'lock_owner_alive', return_value=True), contextlib.redirect_stderr(io.StringIO()) as err, \
                self.assertRaises(RuntimeError) as failure:
            runner.acquire_lock(guest, self.me, 60, mock.Mock(), sleep=sleeps.append, clock=lambda: next(clock))
        self.assertEqual(guest.owner['runId'], 'old-run', 'A live owner keeps its lock')
        self.assertTrue(sleeps and 'old-run' in str(failure.exception))
        self.assertEqual(err.getvalue().count('Waiting for VM lock'), 1, 'Announce each owner once')

    def test_lock_released_while_waiting_is_taken(self):
        guest = FakeGuestLock(owner=self.dead())
        def release(_seconds):
            guest.owner = None
        with mock.patch.object(runner, 'lock_owner_alive', return_value=True), contextlib.redirect_stderr(io.StringIO()):
            runner.acquire_lock(guest, self.me, 60, mock.Mock(), sleep=release, clock=lambda: 0)
        self.assertEqual(guest.owner, self.me)

    def test_lock_lifecycle_runs_in_a_real_shell(self):
        """The guest commands themselves, run by /bin/sh against a temporary lock directory."""
        def sh(command, capture=False):
            return subprocess.run(['/bin/sh', '-c', command], check=True, capture_output=True, text=True)
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner, 'LOCK', temporary + '/lock'):
            lock = Path(temporary) / 'lock'
            me = dict(self.me, host='this-mac', pid=os.getpid(), started=runner.process_start(os.getpid()))
            self.assertEqual(runner.acquire_lock(sh, me, 0, mock.Mock()), [])
            self.assertEqual((lock / 'owner').read_text(), 'new-run')
            runner.record_owner(sh, dict(me, remote='/tmp/slate-ui.AbCd1234'))
            self.assertEqual(json.loads((lock / 'owner.json').read_text())['remote'], '/tmp/slate-ui.AbCd1234')
            # A second runner waits for the live owner and never takes or breaks its lock.
            other = dict(me, runId='other-run')
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError), \
                    mock.patch.object(runner.socket, 'gethostname', return_value='this-mac'):
                runner.acquire_lock(sh, other, 0, mock.Mock())
            runner.release_lock(sh, 'other-run')
            self.assertTrue(lock.is_dir(), 'Only the owner releases the lock')
            # The owner process ends without releasing: the next runner recovers the lock.
            child = subprocess.Popen([sys.executable, '-c', 'pass'])
            child.wait()
            dead = dict(me, pid=child.pid, started='Thu Jan  1 00:00:00 1970')
            runner.record_owner(sh, dead)
            recover = mock.Mock()
            with contextlib.redirect_stderr(io.StringIO()):
                recovered = runner.acquire_lock(sh, other, 0, recover)
            recover.assert_called_once()
            self.assertEqual([item['runId'] for item in recovered], ['new-run'])
            self.assertEqual((lock / 'owner').read_text(), 'other-run')
            runner.release_lock(sh, 'other-run')
            self.assertFalse(lock.exists())

    def test_old_format_lock_is_never_recovered(self):
        guest = FakeGuestLock(legacy='20261017T015651Z-62f6aa4f')
        recover = mock.Mock()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
            runner.acquire_lock(guest, self.me, 0, recover)
        recover.assert_not_called()


if __name__ == '__main__':
    unittest.main()
