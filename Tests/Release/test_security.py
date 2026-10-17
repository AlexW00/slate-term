"""Security boundaries for publishable-file and complete-history scanning."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
spec = importlib.util.spec_from_file_location('security_scan', SCRIPTS / 'security-scan.py')
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)


class SecurityTests(unittest.TestCase):
    def test_private_files_are_blocked_but_reference_templates_are_allowed(self):
        for name in ('.env', '.env.local', 'keys/AuthKey.p8', 'identity.p12', '.netrc',
                     'app.xcodeproj/xcuserdata/owner.xcuserdatad/state'):
            self.assertTrue(scan.private_filename(name), name)
        for name in ('.env.example', 'config/release.env.op.example', 'LICENSE', 'app.keynote'):
            self.assertFalse(scan.private_filename(name), name)

    def test_symlink_scan_never_reads_the_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'source'
            root.mkdir()
            outside = Path(temp) / 'private'
            outside.write_text('PRIVATE CONTENT MUST NOT BE COPIED')
            (root / 'link').symlink_to(outside)
            destination = Path(temp) / 'scan'
            scan.stage_files(root, destination, ['link'])
            self.assertFalse((destination / 'link').is_symlink())
            self.assertEqual((destination / 'link').read_text(), str(outside))

    def test_parent_symlink_rejected_before_scanning_external_content(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'source'
            root.mkdir()
            outside = Path(temp) / 'private'
            outside.mkdir()
            (outside / 'nested').mkdir()
            (outside / 'nested' / 'file').write_text('PRIVATE CONTENT MUST NOT BE COPIED')
            (root / 'linked').symlink_to(outside, target_is_directory=True)
            destination = Path(temp) / 'scan'
            with self.assertRaises(scan.ScanError):
                scan.stage_files(root, destination, ['linked/nested/file'])
            self.assertFalse(destination.exists())
            with mock.patch.object(scan, 'git', return_value=b'linked/nested/file\0'):
                with self.assertRaises(scan.ScanError):
                    scan.publishable_paths(root, True)

    def test_deleted_binary_key_and_side_branch_private_paths_block_history(self):
        with tempfile.TemporaryDirectory(prefix='private history ') as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', temp, *args], stderr=subprocess.DEVNULL)
            git('init', '-b', 'main')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            (root / 'ordinary').write_text('public fixture')
            git('add', '.')
            git('commit', '-m', 'initial')
            clean = git('rev-parse', 'HEAD').decode().strip()
            # Binary P12 material need not match any text-based credential rule.
            (root / 'deleted signing.p12').write_bytes(bytes(range(256)))
            git('add', '.')
            git('commit', '-m', 'add binary fixture')
            git('rm', 'deleted signing.p12')
            git('commit', '-m', 'remove binary fixture')
            git('checkout', '-b', 'side')
            (root / '.env.private').write_text('fake fixture')
            git('add', '.')
            git('commit', '-m', 'side branch')
            git('checkout', 'main')
            self.assertEqual(scan.historical_private_paths(root, clean), [])
            self.assertEqual(scan.historical_private_paths(root, 'main'), ['deleted signing.p12'])
            self.assertEqual(scan.historical_private_paths(root, None), ['.env.private', 'deleted signing.p12'])
            self.assertFalse(any(scan.private_filename(name) for name in scan.publishable_paths(root, False)))
            # Filename rejection must happen before downloading or running Gitleaks.
            with mock.patch.object(scan.Path, 'cwd', return_value=root):
                with mock.patch.object(scan, 'scanner') as binary:
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(scan.main(['--ref', 'main']), 1)
                    binary.assert_not_called()

    def test_history_contains_deleted_and_unmerged_blobs(self):
        with tempfile.TemporaryDirectory(prefix='history with spaces ') as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', temp, *args], stderr=subprocess.DEVNULL)
            git('init', '-b', 'main')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            (root / 'deleted').write_text('old fixture content')
            git('add', '.')
            git('commit', '-m', 'initial')
            deleted = git('rev-parse', 'HEAD:deleted').decode().strip()
            git('rm', 'deleted')
            git('commit', '-m', 'remove')
            git('checkout', '-b', 'side')
            (root / 'side').write_text('unmerged fixture content')
            git('add', '.')
            git('commit', '-m', 'side')
            side = git('rev-parse', 'HEAD:side').decode().strip()
            git('checkout', 'main')
            inventory = dict(scan.object_inventory(root, None))
            self.assertEqual(inventory[deleted], 'blob')
            self.assertEqual(inventory[side], 'blob')
            self.assertEqual(sum(kind == 'commit' for kind in inventory.values()), 3)
            selected = dict(scan.object_inventory(root, 'main'))
            self.assertNotIn(side, selected)

    def test_untracked_and_deleted_file_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'new').touch()
            with mock.patch.object(scan, 'git', return_value=b'new\0removed\0'):
                self.assertEqual(scan.publishable_paths(root, True), ['new'])

    def test_report_never_retains_matched_text_or_secret(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / 'fake-scanner'
            binary.write_text('#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n'
                              'Path(sys.argv[sys.argv.index("--report-path")+1]).write_text(json.dumps(['
                              '{"RuleID":"fixture-rule","File":"fixture.txt","StartLine":4,'
                              '"Secret":"sensitive value","Match":"unredacted line","Commit":"abc"}]))\n'
                              'sys.exit(1)\n')
            binary.chmod(0o755)
            report = root / 'safe.json'
            self.assertFalse(scan.scan(binary, root / 'config', root, ['dir', str(root)], report))
            result = json.loads(report.read_text())
            self.assertEqual(result, [{'RuleID': 'fixture-rule', 'File': 'fixture.txt', 'StartLine': 4, 'Commit': 'abc'}])
            self.assertNotIn('sensitive', report.read_text())

    def test_scanner_failure_is_not_a_clean_scan(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with mock.patch.object(scan.subprocess, 'run', return_value=mock.Mock(returncode=2)):
                with self.assertRaises(scan.ScanError):
                    scan.scan(root / 'scanner', root / 'config', root, ['dir', '.'], root / 'report')


if __name__ == '__main__':
    unittest.main()
