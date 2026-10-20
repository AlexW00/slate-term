"""Prebuilt app selection and release provenance without any native execution."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
import verification_gates as gates
import vm_test_bundle as bundle


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load_module('prebuilt_vm_runner', REPO / 'scripts/verify-vm.py')
inventory = load_module('prebuilt_source_inventory', REPO / 'scripts/release-source-inventory.py')


def make_app(root, relative='artifacts/release/Slate Terminal.app', content=b'release executable'):
    if not (root / '.git').exists():
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        (root / '.gitignore').write_text('artifacts/\n.derived/\nstaged/\n')
    app = root / relative
    executable = app / 'Contents/MacOS/SlateTermApp'
    executable.parent.mkdir(parents=True)
    executable.write_bytes(content)
    executable.chmod(0o755)
    with (app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleExecutable': 'SlateTermApp', 'CFBundleIdentifier': 'com.slateterm.test',
                      'CFBundleShortVersionString': '0.4.0', 'CFBundleVersion': '41', 'DTXcodeBuild': 'fixture-xcode'}, stream)
    return app


def release_receipt(app, source_inventory=None):
    value = {'source_commit': 'test-commit', 'source_dirty': True, 'configuration': 'Release',
             'version': '0.4.0', 'build_number': '41', 'ghostty_revision': 'pinned-engine',
             'app_tree_sha256': bundle.app_tree_hash(app)}
    if source_inventory is None:
        root = next(parent for parent in app.parents if (parent / '.git').is_dir())
        source_inventory = inventory.inventory(root)
    value.update(source_files=source_inventory, source_files_sha256=inventory.inventory_digest(source_inventory))
    path = app.parent / 'build-source.json'
    path.write_text(json.dumps(value))
    return path


class PrebuiltAppTests(unittest.TestCase):
    def test_selection_requires_owned_absolute_app_and_rejects_build_certification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            with mock.patch.object(runner, 'ROOT', root):
                args = argparse.Namespace(app=app, all=False)
                self.assertEqual(runner.prebuilt_app_selection(args, gates.select(['app'])), app)
                for selection, complete in [(['build', 'app'], False), ([], True), (['text-checking'], False)]:
                    with self.assertRaises(ValueError):
                        runner.prebuilt_app_selection(argparse.Namespace(app=app, all=complete), gates.select(selection, complete=complete))
                with self.assertRaisesRegex(ValueError, 'absolute'):
                    runner.prebuilt_app_selection(argparse.Namespace(app=Path('local.app'), all=False), gates.select(['app']))
            with tempfile.TemporaryDirectory() as external:
                foreign = make_app(Path(external))
                with self.assertRaisesRegex(ValueError, 'inside the repository'):
                    bundle.selected_app(root, foreign)
                alias = root / 'External.app'
                alias.symlink_to(foreign, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, 'inside the repository'):
                    bundle.selected_app(root, alias)

    def test_explicit_prebuilt_mode_never_defaults_to_listing(self):
        for args in [argparse.Namespace(list=True, tests=[], app=Path('/no/app.app')),
                     argparse.Namespace(list=False, tests=[], app=Path('/no/app.app'))]:
            with mock.patch.object(runner, 'checked') as execute, self.assertRaisesRegex(SystemExit, 'requires selected VM gates'):
                runner.host_main(args)
            execute.assert_not_called()

    def test_staging_uses_selected_release_bytes_at_the_canonical_fixture_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            make_app(root, bundle.APP_GUEST_PATH, content=b'wrong debug executable')
            staged = root / 'staged'
            staged.mkdir()
            hashes, host = bundle.stage_products(root, staged, gates.select(['app']), app=app)
            relative = 'Contents/MacOS/SlateTermApp'
            self.assertEqual((staged / bundle.APP_GUEST_PATH / relative).read_bytes(), b'release executable')
            self.assertEqual(hashes[bundle.APP_GUEST_PATH + '/' + relative], host[str(app.relative_to(root) / relative)])
            self.assertNotIn(bundle.APP_GUEST_PATH + '/' + relative, host)

    def test_upgrade_gate_requires_both_owned_fixtures_before_building(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            upgrade = make_app(root, 'artifacts/v2/Upgrade.app')
            incompatible = make_app(root, 'artifacts/abi/Incompatible.app')
            gate = argparse.Namespace(name='layout-app-upgrades')
            with mock.patch.object(runner, 'ROOT', root):
                args = argparse.Namespace(upgrade_app=upgrade, incompatible_upgrade_app=incompatible)
                self.assertEqual(runner.upgrade_app_selection(args, [gate]),
                                 {'upgrade': upgrade, 'incompatible': incompatible})
                with self.assertRaisesRegex(ValueError, 'require the layout-app-upgrades gate'):
                    runner.upgrade_app_selection(args, [])
                for partial in [argparse.Namespace(), argparse.Namespace(upgrade_app=upgrade),
                                argparse.Namespace(incompatible_upgrade_app=incompatible)]:
                    with self.assertRaisesRegex(ValueError, 'requires --upgrade-app and --incompatible'):
                        runner.upgrade_app_selection(partial, [gate])

    def test_upgrade_fixtures_keep_distinct_provenance_staging_and_guest_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            primary = make_app(root)
            upgrade = make_app(root, 'artifacts/v2/Upgrade.app', b'upgrade executable')
            incompatible = make_app(root, 'artifacts/abi/Incompatible.app', b'incompatible executable')
            for app in [primary, upgrade, incompatible]:
                release_receipt(app)
            apps = {'upgrade': upgrade, 'incompatible': incompatible}
            staged = root / 'staged'
            staged.mkdir()
            with mock.patch.object(runner, 'ROOT', root):
                provenance = runner.upgrade_provenance(apps)
                guest, host = bundle.stage_products(root, staged, gates.select(['app']), app=primary, upgrade_apps=apps)
                environment = runner.guest_gate_environment('layout-app-upgrades', {'upgradeApps': provenance})
                for role, app in apps.items():
                    destination, variable = bundle.UPGRADE_APPS[role]
                    executable = destination + '/Contents/MacOS/SlateTermApp'
                    self.assertEqual(provenance[role]['guestPath'], destination)
                    self.assertEqual(provenance[role]['executable']['guestPath'], executable)
                    self.assertEqual(provenance[role]['sourceHashValidation'], 'matched-build-receipt')
                    self.assertEqual(environment[variable], str(root / executable))
                    self.assertEqual(bundle.app_tree_hash(staged / destination), bundle.app_tree_hash(app))
                    self.assertEqual(guest[executable], host[str(app.relative_to(root) / 'Contents/MacOS/SlateTermApp')])
                    self.assertEqual(guest['.vm-fixtures/' + role + '-build-source.json'],
                                     host[str((app.parent / 'build-source.json').relative_to(root))])
                    with mock.patch.dict(os.environ, {variable: '/untrusted/inherited/path'}):
                        self.assertNotIn(variable, runner.guest_gate_environment('app-1', {}))
                self.assertNotEqual(provenance['upgrade']['treeSHA256'], provenance['incompatible']['treeSHA256'])

    def test_app_symlinks_must_be_portable_and_stay_inside_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            target = app / 'Contents/MacOS/current'
            target.symlink_to('SlateTermApp')
            self.assertEqual(bundle.selected_app(root, app), app)
            target.unlink()
            target.symlink_to(app / 'Contents/MacOS/SlateTermApp')
            with self.assertRaisesRegex(ValueError, 'nonportable symlink'):
                bundle.selected_app(root, app)
            target.unlink()
            outside = root / 'outside'
            outside.write_bytes(b'outside')
            target.symlink_to(os.path.relpath(outside, target.parent))
            with self.assertRaisesRegex(ValueError, 'nonportable symlink'):
                bundle.selected_app(root, app)

    def test_provenance_binds_version_build_executable_tree_and_release_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            receipt = release_receipt(app)
            result = bundle.app_provenance(root, app)
            self.assertEqual(result['configuration'], 'Release')
            self.assertEqual((result['version'], result['build']), ('0.4.0', '41'))
            self.assertEqual(result['hostPath'], str(app))
            self.assertEqual(result['guestPath'], bundle.APP_GUEST_PATH)
            self.assertEqual(result['treeSHA256'], bundle.app_tree_hash(app))
            self.assertEqual(result['executable']['sha256'], hashlib.sha256(b'release executable').hexdigest())
            self.assertEqual(result['buildReceipt']['sha256'], bundle.digest(receipt))
            self.assertEqual(result['buildInfo'], {'DTXcodeBuild': 'fixture-xcode'})
            self.assertEqual(result['sourceHashValidation'], 'matched-build-receipt')
            (app / 'Contents/MacOS/SlateTermApp').write_bytes(b'replaced')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                bundle.app_provenance(root, app)

    def test_build_receipt_cannot_redirect_outside_the_selected_bundle_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            receipt = release_receipt(app)
            external = root / 'other-receipt.json'
            receipt.rename(external)
            receipt.symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'not a symlink'):
                bundle.app_provenance(root, app)

    def test_release_receipt_without_source_inventory_cannot_claim_current_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            path = release_receipt(app)
            value = json.loads(path.read_text())
            value.pop('source_files')
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'no source file inventory'):
                bundle.app_provenance(root, app)

    def test_unrecorded_prebuilt_configuration_is_not_guessed_from_directory_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            self.assertEqual(bundle.app_provenance(root, make_app(root))['configuration'], 'unknown')

    def test_dirty_source_receipt_is_verified_against_current_contents_and_new_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('artifacts/\n')
            source = root / 'app.swift'
            source.write_text('let initial = 1\n')
            app = make_app(root)
            release_receipt(app, inventory.inventory(root))
            self.assertEqual(bundle.app_provenance(root, app)['sourceHashValidation'], 'matched-build-receipt')
            source.write_text('let replacement = 2\n')
            with self.assertRaisesRegex(ValueError, 'Source files changed'):
                bundle.app_provenance(root, app)
            source.write_text('let initial = 1\n')
            (root / 'new.swift').write_text('new input\n')
            with self.assertRaisesRegex(ValueError, 'Source files changed'):
                bundle.app_provenance(root, app)

    def make_signed_app(self, root, app=None, source_inventory=None):
        app = app or make_app(root)
        runtime = app / 'Contents/Frameworks/SlateRuntime.framework'
        runtime.mkdir(parents=True)
        (runtime / 'SlateRuntime').write_bytes(b'runtime')
        receipt_path = release_receipt(app, source_inventory)
        receipt = json.loads(receipt_path.read_text())
        signature = app / 'Contents/_CodeSignature/CodeResources'
        signature.parent.mkdir()
        signature.write_bytes(b'new publisher signature')
        sidecar = {'schema': 1, 'build_receipt_sha256': bundle.digest(receipt_path),
                   'unsigned_app_tree_sha256': receipt['app_tree_sha256'],
                   'signed_app_tree_sha256': bundle.app_tree_hash(app),
                   'signing_identity': 'A' * 40, 'signing_purpose': 'local-vm-test'}
        path = app.parent / 'vm-signing.json'
        path.write_text(json.dumps(sidecar))
        return app, path, sidecar

    def make_source_variant(self, root):
        app = make_app(root)
        source = root / 'app.swift'
        source.write_text('let title = "New Tab"\n')
        source.chmod(0o644)
        receipt = release_receipt(app)
        archive = app.parent / 'baseline-source/app.swift'
        archive.parent.mkdir()
        archive.write_bytes(source.read_bytes())
        archive.chmod(source.stat().st_mode & 0o777)
        source.write_text('let title = "Terminal"\n')
        value = {'schema': 1, 'purpose': 'upgrade-baseline',
                 'current_source_files_sha256': inventory.inventory_digest(inventory.inventory(root)),
                 'reference_source_files_sha256': json.loads(receipt.read_text())['source_files_sha256'],
                 'changes': {'app.swift': 'baseline-source/app.swift'}}
        marker = app.parent / 'fixture-source-variant.json'
        marker.write_text(json.dumps(value))
        return app, source, archive, marker, value

    def test_upgrade_baseline_records_exact_old_source_without_claiming_current_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, source, archive, marker, value = self.make_source_variant(root)
            result = bundle.app_provenance(root, app)
            self.assertEqual(result['sourceHashValidation'], 'matched-explicit-upgrade-baseline')
            self.assertEqual(result['sourceVariant']['changedPaths'], ['app.swift'])
            self.assertEqual(result['sourceVariant']['markerSHA256'], bundle.digest(marker))
            self.assertEqual(result['sourceVariant']['currentSourceFilesSHA256'], value['current_source_files_sha256'])
            self.assertEqual(result['sourceVariant']['referenceSourceFilesSHA256'], value['reference_source_files_sha256'])
            self.assertEqual(result['buildReceipt']['sourceFilesSHA256'], value['reference_source_files_sha256'])
            self.assertNotEqual(value['current_source_files_sha256'], value['reference_source_files_sha256'])
            staged = root / 'staged'
            staged.mkdir()
            (archive.parent / 'unrelated.txt').write_text('do not stage arbitrary archives')
            guest, host = bundle.stage_products(root, staged, gates.select(['app']), app=app)
            self.assertEqual(guest['.vm-app-fixture-source-variant.json'], bundle.digest(marker))
            self.assertEqual(guest['.vm-app-baseline-source/app.swift'], bundle.digest(archive))
            self.assertEqual(host[str(archive.relative_to(root))], bundle.digest(archive))
            self.assertFalse((staged / '.vm-app-baseline-source/unrelated.txt').exists())
            marker.unlink()
            with self.assertRaisesRegex(ValueError, 'Source files changed'):
                bundle.app_provenance(root, app)

    def test_upgrade_baseline_rejects_unrelated_changes_even_with_refreshed_current_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, _, _, marker, value = self.make_source_variant(root)
            (root / 'unrelated.swift').write_text('unrelated addition')
            with self.assertRaisesRegex(ValueError, 'current inventory digest'):
                bundle.app_provenance(root, app)
            value['current_source_files_sha256'] = inventory.inventory_digest(inventory.inventory(root))
            marker.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'exact source inventory delta'):
                bundle.app_provenance(root, app)

    def test_upgrade_baseline_rejects_missing_extra_empty_and_metadata_only_changes(self):
        for mutation in ['missing', 'extra', 'empty', 'unchanged', 'mode', 'deleted']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                app, source, archive, marker, value = self.make_source_variant(root)
                if mutation == 'missing':
                    value['changes'] = {'wrong.swift': 'baseline-source/app.swift'}
                elif mutation == 'extra':
                    value['changes']['.gitignore'] = 'baseline-source/app.swift'
                elif mutation == 'empty':
                    value['changes'] = {}
                elif mutation == 'unchanged':
                    source.write_bytes(archive.read_bytes())
                elif mutation == 'mode':
                    source.write_bytes(archive.read_bytes())
                    source.chmod(0o755)
                elif mutation == 'deleted':
                    source.unlink()
                value['current_source_files_sha256'] = inventory.inventory_digest(inventory.inventory(root))
                marker.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    bundle.app_provenance(root, app)

    def test_upgrade_baseline_rejects_archive_tampering_traversal_symlinks_and_oversize(self):
        for mutation in ['bytes', 'mode', 'traversal', 'absolute', 'file-link', 'directory-link', 'oversize']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                app, _, archive, marker, value = self.make_source_variant(root)
                if mutation == 'bytes':
                    archive.write_text('changed archived source')
                elif mutation == 'mode':
                    archive.chmod(0o755)
                elif mutation == 'traversal':
                    value['changes']['app.swift'] = 'baseline-source/../baseline-source/app.swift'
                elif mutation == 'absolute':
                    value['changes']['app.swift'] = str(archive)
                elif mutation == 'file-link':
                    target = archive.with_name('original.swift')
                    archive.rename(target)
                    archive.symlink_to(target.name)
                elif mutation == 'directory-link':
                    target = archive.parent.with_name('elsewhere')
                    archive.parent.rename(target)
                    archive.parent.symlink_to(target.name, target_is_directory=True)
                elif mutation == 'oversize':
                    with archive.open('wb') as stream:
                        stream.truncate(8 * 1024 * 1024 + 1)
                marker.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    bundle.app_provenance(root, app)

    def test_upgrade_baseline_requires_original_receipt_and_preserves_app_tree_validation(self):
        for mutation in ['reference', 'receipt-selfhash', 'receipt-missing', 'tree', 'marker-symlink']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                app, _, _, marker, value = self.make_source_variant(root)
                receipt_path = app.parent / 'build-source.json'
                if mutation == 'reference':
                    value['reference_source_files_sha256'] = '0' * 64
                    marker.write_text(json.dumps(value))
                elif mutation == 'receipt-selfhash':
                    receipt = json.loads(receipt_path.read_text())
                    receipt['source_files']['app.swift']['sha256'] = '0' * 64
                    receipt_path.write_text(json.dumps(receipt))
                elif mutation == 'receipt-missing':
                    receipt_path.unlink()
                elif mutation == 'tree':
                    (app / 'Contents/MacOS/SlateTermApp').write_bytes(b'tampered executable')
                elif mutation == 'marker-symlink':
                    target = marker.with_name('other-marker.json')
                    marker.rename(target)
                    marker.symlink_to(target.name)
                with self.assertRaises(ValueError):
                    bundle.app_provenance(root, app)

    def test_upgrade_baseline_keeps_signed_app_verification_independent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, _, _, _, _ = self.make_source_variant(root)
            original = json.loads((app.parent / 'build-source.json').read_text())['source_files']
            self.make_signed_app(root, app=app, source_inventory=original)
            with self.verified_codesign() as calls:
                result = bundle.app_provenance(root, app)
            self.assertEqual(result['sourceHashValidation'], 'matched-explicit-upgrade-baseline')
            self.assertEqual(result['signing']['purpose'], 'local-vm-test')
            self.assertEqual(len(calls), 3)
            with self.verified_codesign(fail=True), self.assertRaisesRegex(ValueError, 'signing verification failed'):
                bundle.app_provenance(root, app)

    @contextlib.contextmanager
    def verified_codesign(self, fail=False):
        original = subprocess.run
        calls = []
        def run(command, **kwargs):
            if command[0] != '/usr/bin/codesign':
                return original(command, **kwargs)
            calls.append(command)
            if fail:
                raise subprocess.CalledProcessError(1, command, stderr='publisher requirement rejected')
            return subprocess.CompletedProcess(command, 0, stdout='', stderr='')
        with mock.patch.object(bundle.subprocess, 'run', side_effect=run):
            yield calls

    def test_signed_vm_provenance_preserves_release_source_receipt_and_checks_publisher(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, sidecar, value = self.make_signed_app(root)
            with self.verified_codesign() as calls:
                result = bundle.app_provenance(root, app)
            self.assertEqual(result['configuration'], 'Release')
            self.assertEqual(result['sourceHashValidation'], 'matched-build-receipt')
            self.assertEqual(result['signing']['purpose'], 'local-vm-test')
            self.assertEqual(result['signing']['identity'], value['signing_identity'])
            self.assertEqual(result['signing']['sidecarSHA256'], bundle.digest(sidecar))
            self.assertEqual(calls[0], ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
            self.assertEqual(len(calls), 3)
            self.assertIn('certificate leaf[subject.OU] = "YWRT8FQN6F"', calls[1][-2])
            self.assertIn('certificate leaf = H"' + 'A' * 40 + '"', calls[1][-2])
            self.assertIn('identifier "com.slateterm.runtime"', calls[2][-2])
            staged = root / 'staged'
            staged.mkdir()
            guest, host = bundle.stage_products(root, staged, gates.select(['app']), app=app)
            self.assertEqual(guest['.vm-app-signing.json'], host[str(sidecar.relative_to(root))])

    def test_signed_vm_hash_chain_tampering_never_reaches_signature_verification(self):
        replacements = {'schema': 2, 'build_receipt_sha256': '0' * 64, 'unsigned_app_tree_sha256': '0' * 64,
                        'signed_app_tree_sha256': '0' * 64, 'signing_identity': '-', 'signing_purpose': 'release',
                        'unsigned_app_tree_sha256_type': None}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, path, sidecar = self.make_signed_app(root)
            for key, replacement in replacements.items():
                edited = dict(sidecar)
                edited[key.removesuffix('_type')] = replacement
                path.write_text(json.dumps(edited))
                with self.subTest(key=key), self.verified_codesign() as calls, self.assertRaises(ValueError):
                    bundle.app_provenance(root, app)
                self.assertEqual(calls, [])

    def test_signed_vm_app_requires_its_sidecar_and_original_build_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, path, sidecar = self.make_signed_app(root)
            path.unlink()
            with self.assertRaisesRegex(ValueError, 'does not match'):
                bundle.app_provenance(root, app)
            path.write_text(json.dumps(sidecar))
            (app.parent / 'build-source.json').unlink()
            with self.assertRaisesRegex(ValueError, 'requires its original'):
                bundle.app_provenance(root, app)

    def test_signed_vm_app_rejects_failed_signature_or_changed_source_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, _, _ = self.make_signed_app(root)
            with self.verified_codesign(fail=True), self.assertRaisesRegex(ValueError, 'signing verification failed'):
                bundle.app_provenance(root, app)
            (root / 'changed-source.swift').write_text('source changed after build')
            with self.verified_codesign(), self.assertRaisesRegex(ValueError, 'Source files changed'):
                bundle.app_provenance(root, app)

    def run_prebuilt_host(self, mutate_app=False, source_changes=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = make_app(root)
            release_receipt(app)
            calls = []
            def execute(command, **kwargs):
                calls.append(command)
                output = ''
                if command[-1] == 'printf "%s" "$HOME"':
                    output = '/Users/guest'
                elif command[-1] == 'mktemp -d /tmp/slate-ui.XXXXXXXX':
                    output = '/tmp/slate-ui.UnitTest'
                elif 'cp' in command and '/source/artifacts/.' in command[-2]:
                    (Path(command[-1]) / 'results.json').write_text(json.dumps({'tests': {'app-1': 0}, 'completed': True}))
                    if mutate_app:
                        (app / 'Contents/MacOS/SlateTermApp').write_bytes(b'changed after guest execution')
                return subprocess.CompletedProcess(command, 0, stdout=output)
            args = argparse.Namespace(list=False, tests=['app'], app=app, all=False, vm='test-vm',
                                      vmpal='/fake/vmpal', timeout=10, keep_guest=False)
            process = mock.Mock()
            process.wait.return_value = process.poll.return_value = 0
            real_popen = subprocess.Popen
            guest_launches = []
            def popen(command, **kwargs):
                if command[0] == '/fake/vmpal':
                    guest_launches.append(command)
                    return process
                return real_popen(command, **kwargs)
            hash_reads = []
            def changed_hashes(_):
                hash_reads.append(1)
                return {'input': 'old' if len(hash_reads) == 1 else 'new'}
            hashes = mock.patch.object(runner, 'source_hashes', side_effect=changed_hashes) if source_changes else contextlib.nullcontext()
            with hashes, mock.patch.object(runner, 'ROOT', root), mock.patch.object(runner, 'validate'), \
                    mock.patch.object(runner, 'source_files', return_value=[]), \
                    mock.patch.object(runner, 'checked', side_effect=execute), \
                    mock.patch.object(runner, 'run_gate', return_value=0) as build, \
                    mock.patch.object(runner.platform, 'machine', return_value='arm64'), \
                    mock.patch.object(runner.sys, 'platform', 'darwin'), \
                    mock.patch.object(runner.os, 'access', return_value=True), \
                    mock.patch.object(runner.subprocess, 'Popen', side_effect=popen), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                status = runner.host_main(args)
            receipt = json.loads(next((root / 'artifacts/vm').glob('*/receipt.json')).read_text())
            self.assertFalse(build.called, 'A prebuilt app-only selection must not compile a replacement')
            return status, receipt, bool(guest_launches)

    def test_prebuilt_host_run_records_actual_app_without_claiming_a_build_gate(self):
        status, receipt, launched = self.run_prebuilt_host()
        self.assertEqual(status, 0)
        self.assertTrue(launched)
        self.assertTrue(receipt['completed'])
        self.assertFalse(receipt['fullSuite'])
        self.assertEqual(receipt['hostResults'], {})
        self.assertEqual(receipt['preparations'], [])
        self.assertFalse(receipt['app']['buildGateRun'])
        self.assertEqual(receipt['app']['selection'], 'prebuilt')
        self.assertEqual(receipt['app']['configuration'], 'Release')
        self.assertIn('artifacts/release/Slate Terminal.app/Contents/MacOS/SlateTermApp', receipt['hostBinaryHashes'])
        self.assertIn(bundle.APP_GUEST_PATH + '/Contents/MacOS/SlateTermApp', receipt['binaryHashes'])
        self.assertIn('.vm-app-build-source.json', receipt['binaryHashes'])

    def test_mutating_selected_app_after_execution_invalidates_receipt(self):
        status, receipt, launched = self.run_prebuilt_host(mutate_app=True)
        self.assertTrue(launched)
        self.assertNotEqual(status, 0)
        self.assertTrue(receipt['hostAppChanged'])
        self.assertIn('artifacts/release/Slate Terminal.app/Contents/MacOS/SlateTermApp', receipt['hostBinaryChanged'])

    def test_source_changes_still_prevent_guest_execution_in_prebuilt_mode(self):
        status, receipt, launched = self.run_prebuilt_host(source_changes=True)
        self.assertFalse(launched)
        self.assertNotEqual(status, 0)
        self.assertIn('Source changed', receipt['error'])


if __name__ == '__main__':
    unittest.main()
