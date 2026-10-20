"""A local build receipt must identify dirty inputs and reject drift after compilation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/release-source-inventory.py'
spec = importlib.util.spec_from_file_location('release_source_inventory', SCRIPT)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class SourceInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='slate-source-inventory-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        (self.root / '.gitignore').write_text('artifacts/\n.build/\n')
        (self.root / 'tracked.swift').write_text('initial source\n')
        self.git('add', '.gitignore', 'tracked.swift')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)

    def receipt(self):
        files = inventory.inventory(self.root)
        return {'source_files': files, 'source_files_sha256': inventory.inventory_digest(files)}

    def test_includes_uncommitted_bootstrap_and_metadata_but_not_build_outputs(self):
        (self.root / 'Bootstrap').mkdir()
        (self.root / 'Bootstrap/main.m').write_text('bootstrap source')
        (self.root / 'RuntimeInfo.plist').write_text('runtime metadata')
        (self.root / 'artifacts').mkdir()
        (self.root / 'artifacts/build.log').write_text('generated log')
        snapshot = self.receipt()
        self.assertIn('Bootstrap/main.m', snapshot['source_files'])
        self.assertIn('RuntimeInfo.plist', snapshot['source_files'])
        self.assertNotIn('artifacts/build.log', snapshot['source_files'])
        (self.root / 'artifacts/build.log').write_text('later generated log')
        inventory.verify_receipt(self.root, snapshot)

    def test_detects_same_size_source_change_even_when_timestamp_is_restored(self):
        snapshot = self.receipt()
        source = self.root / 'tracked.swift'
        metadata = source.stat()
        source.write_text('changed source\n')
        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, 'tracked.swift'):
            inventory.verify_receipt(self.root, snapshot)

    def test_detects_new_untracked_file_and_mode_changes(self):
        snapshot = self.receipt()
        source = self.root / 'new.swift'
        source.write_text('new source')
        with self.assertRaisesRegex(ValueError, 'new.swift'):
            inventory.verify_receipt(self.root, snapshot)
        source.unlink()
        source = self.root / 'tracked.swift'
        source.chmod(source.stat().st_mode | 0o100)
        with self.assertRaisesRegex(ValueError, 'tracked.swift'):
            inventory.verify_receipt(self.root, snapshot)

    def test_tracks_deleted_files_and_rejects_restoration_after_snapshot(self):
        source = self.root / 'tracked.swift'
        source.unlink()
        snapshot = self.receipt()
        self.assertEqual(snapshot['source_files']['tracked.swift'], {'kind': 'missing'})
        source.write_text('restored source')
        with self.assertRaisesRegex(ValueError, 'tracked.swift'):
            inventory.verify_receipt(self.root, snapshot)

    def test_symlinks_hash_the_link_not_external_contents(self):
        outside = self.root.parent / 'outside'
        outside.write_text('external data')
        (self.root / 'linked').symlink_to('../outside')
        snapshot = self.receipt()
        entry = snapshot['source_files']['linked']
        self.assertEqual(entry['kind'], 'symlink')
        self.assertEqual(entry['sha256'], hashlib.sha256(b'../outside').hexdigest())
        outside.write_text('different external data')
        inventory.verify_receipt(self.root, snapshot)

    def test_directory_symlinks_do_not_read_external_tracked_paths(self):
        nested = self.root / 'nested'
        nested.mkdir()
        (nested / 'file').write_text('source')
        self.git('add', 'nested/file')
        (nested / 'file').unlink()
        nested.rmdir()
        outside = self.root.parent / 'outside'
        outside.mkdir()
        (outside / 'file').write_text('external data')
        nested.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'directory symlink'):
            inventory.inventory(self.root)

    def test_receipt_rejects_missing_or_inconsistent_inventory(self):
        with self.assertRaisesRegex(ValueError, 'no source file inventory'):
            inventory.verify_receipt(self.root, {})
        snapshot = self.receipt()
        snapshot['source_files_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'digest does not match'):
            inventory.verify_receipt(self.root, snapshot)

    def test_digest_is_independent_of_dictionary_insertion_order(self):
        files = self.receipt()['source_files']
        self.assertEqual(inventory.inventory_digest(files), inventory.inventory_digest(dict(reversed(list(files.items())))))


if __name__ == '__main__':
    unittest.main()
