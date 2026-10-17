"""Inventory completeness and relocatable runtime-only bundle regressions."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
import verification_gates as inventory
import vm_test_bundle as bundle


class InventoryTests(unittest.TestCase):
    def test_full_inventory_includes_every_script_and_three_app_iterations(self):
        inventory.validate(REPO)
        selected = inventory.select([], complete=True)
        self.assertEqual(len(selected), 85)
        self.assertIn('plugin-packages', [gate.name for gate in selected])
        self.assertTrue({'shell-hooks', 'shells'} <= {gate.name for gate in selected})
        self.assertEqual([gate.name for gate in selected], list(inventory.ORDER))
        self.assertEqual([gate.name for gate in selected if gate.command[-1] == 'scripts/verify-app.py'],
                         ['app-1', 'app-2', 'app-3'])
        self.assertEqual(sum(gate.native is not None for gate in selected), 19)
        self.assertEqual(sum(gate.location == 'host' for gate in selected), 6)
        self.assertTrue(all(gate.location == 'vm' for gate in selected if gate.native))

    def test_selection_alias_does_not_collapse_distinct_app_iterations(self):
        self.assertEqual([gate.name for gate in inventory.select(['app', 'app-2', 'app-3', 'app-1'])],
                         ['app-1', 'app-2', 'app-3'])
        with self.assertRaisesRegex(ValueError, 'either --all'):
            inventory.select(['terminal'], complete=True)

    def test_new_unregistered_script_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            for gate in inventory.GATES:
                for argument in gate.command:
                    if argument.startswith('scripts/'):
                        (root / argument).touch()
            (root / 'scripts/verify-unregistered-native.sh').touch()
            with self.assertRaisesRegex(ValueError, 'Unregistered verification scripts'):
                inventory.validate(root)

    def test_full_wrapper_uses_the_same_runner(self):
        source = (REPO / 'scripts/verify-all.sh').read_text()
        self.assertIn('exec python3 scripts/verify-vm.py --all "$@"', source)
        self.assertNotIn('python3 scripts/verification-manifest.py finish', source)

    def test_service_fixtures_require_the_resolved_runtime_interpreter(self):
        for name in ['service-commands', 'service-generation']:
            source = (REPO / ('scripts/verify-' + name + '.sh')).read_text()
            self.assertIn('export SLATE_TEST_PYTHON="$(command -v python3)"', source)
        for name in ['ServiceCommands/ServiceCommands.swift', 'ServiceGeneration/ServiceGeneration.swift',
                     'ServiceGeneration/ServiceManager.swift']:
            source = (REPO / 'Tests' / name).read_text()
            self.assertNotIn('"/usr/bin/python3"', source)
            self.assertIn('"executable": python', source.replace('exits ? "/usr/bin/true" : python', 'python'))

    def test_bundle_excludes_modules_compiler_caches_and_debug_symbols(self):
        gate = inventory.BY_NAME['event-hub']
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / gate.native_directory
            directory.mkdir(parents=True)
            (directory / gate.native.executable).write_bytes(b'executable')
            (directory / 'libSlateTermCore.dylib').write_bytes(b'library')
            (directory / 'SlateTermCore.swiftmodule').write_bytes(b'compile-only module')
            (directory / 'module-cache').mkdir()
            (directory / 'module-cache/cache').write_bytes(b'compiler cache')
            (directory / 'fixture.dSYM').mkdir()
            (directory / 'fixture.dSYM/symbols').write_bytes(b'debug data')
            staged = root / 'staged'
            staged.mkdir()
            with mock.patch.object(bundle, 'verify_native_links'):
                hashes, host = bundle.stage_products(root, staged, [gate])
            expected = {gate.product, gate.native_directory + '/libSlateTermCore.dylib'}
            self.assertEqual(set(hashes), expected)
            self.assertEqual(set(host), expected)
            self.assertEqual(hashes, host)
            self.assertFalse((staged / gate.native_directory / 'module-cache').exists())

    def test_native_compiler_supplies_transitive_archive_module_and_object(self):
        # Stub only the compiler: this host check must never execute a native fixture.
        with tempfile.TemporaryDirectory(prefix='native flags ') as temporary:
            directory = Path(temporary)
            compiler = directory / 'swiftc'
            compiler.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            compiler.chmod(0o700)
            environment = dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH'])
            cases = [([], False, False), (['-lSlateTermSettings'], True, False),
                     ([str(directory / 'SlateTermSettings.o')], True, True)]
            for arguments, needs_module, needs_object in cases:
                result = subprocess.run(['/bin/bash', '-c',
                    'set -eu; source scripts/native-gate.sh; slate_native_swiftc "$@"',
                    'native-flags', *arguments, '-o', str(directory / 'fixture')],
                    cwd=REPO, env=environment, text=True, capture_output=True, check=True)
                flags = result.stdout.splitlines()
                self.assertEqual('-larchive' in flags, needs_module)
                self.assertEqual(str(REPO / 'Sources/SlateArchive/include') in flags, needs_module)
                self.assertEqual(str(directory / 'SlateArchive.o') in flags, needs_object)

    def test_native_dependency_validation_requires_gate_local_dylibs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'fixture').touch()
            (directory / 'libCore.dylib').touch()
            valid = '\t@rpath/libCore.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
            with mock.patch.object(bundle.subprocess, 'check_output', return_value=valid):
                bundle.verify_native_links(directory, 'fixture')
            for dependency, error in [('/private/tmp/host-only.dylib', 'Nonportable'),
                                      ('@rpath/missing.dylib', 'Missing gate-local')]:
                with mock.patch.object(bundle.subprocess, 'check_output',
                                       return_value='\t' + dependency + ' (compatibility version 0.0.0)\n'):
                    with self.assertRaisesRegex(RuntimeError, error):
                        bundle.verify_native_links(directory, 'fixture')


if __name__ == '__main__':
    unittest.main()
