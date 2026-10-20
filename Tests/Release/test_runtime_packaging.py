"""Guard private runtime packaging and the production/development signing boundary."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/package-runtime.py'
spec = importlib.util.spec_from_file_location('package_runtime', SCRIPT)
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class RuntimePackagingTests(unittest.TestCase):
    def test_helpers_remove_absolute_build_rpaths_and_preserve_system_and_private_paths(self):
        paths = ['/usr/lib/swift', '/System/Library/Frameworks',
                 '/Users/developer/Build Products/Debug/PackageFrameworks',
                 '@executable_path/../Frameworks', '@loader_path/Frameworks']
        commands = '\n'.join(f'Load command {index}\n          cmd LC_RPATH\n'
                             f'      cmdsize 80\n         path {path} (offset 12)'
                             for index, path in enumerate(paths))
        binary = Path('/tmp/SlateRuntime.framework/Helpers/slate-term')
        with mock.patch.object(packaging, 'run', return_value=commands) as run:
            packaging.remove_build_rpaths(binary)
        self.assertEqual(run.call_args_list, [
            mock.call('otool', '-l', binary),
            mock.call('install_name_tool', '-delete_rpath', paths[2], binary),
        ])

    def test_dependency_inventory_uses_complete_framework_names(self):
        commands = '''/tmp/Runtime:
    @rpath/SlateRuntime.framework/Versions/A/SlateRuntime (compatibility version 1.0.0)
    @rpath/SlateTermCore.framework/Versions/A/SlateTermCore (compatibility version 1.0.0)
    /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 1.0.0)
    /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)
'''
        self.assertEqual(packaging.framework_dependencies(commands),
                         {'SlateRuntime.framework', 'SlateTermCore.framework'})

    def test_framework_version_links_remain_inside_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'SlateRuntime.framework'
            (root / 'Versions/A/Resources').mkdir(parents=True)
            (root / 'Versions/Current').symlink_to('A')
            (root / 'Resources').symlink_to('Versions/Current/Resources')
            packaging.check_internal_links(root)

    def test_external_and_dangling_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'runtime'
            root.mkdir()
            outside = Path(temporary) / 'outside'
            outside.write_text('fixture')
            link = root / 'dependency'
            link.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'escapes'):
                packaging.check_internal_links(root)
            link.unlink()
            link.symlink_to('missing')
            with self.assertRaisesRegex(ValueError, 'broken'):
                packaging.check_internal_links(root)

    def test_runtime_root_cannot_be_a_link_to_an_external_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            outside = Path(temporary) / 'outside'
            outside.mkdir()
            runtime = Path(temporary) / 'SlateRuntime.framework'
            runtime.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'root must not'):
                packaging.check_internal_links(runtime)

    def test_macho_inventory_does_not_follow_framework_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'Binary'
            binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
            (root / 'Alias').symlink_to('Binary')
            (root / 'Resource').write_text('fixture')
            self.assertEqual(packaging.macho_files(root), [binary])

    def test_development_bootstrap_cannot_receive_publisher_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Slate.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'SlateRuntimeDevelopment': True}))
            with mock.patch.object(packaging, 'run') as run, \
                 mock.patch.object(packaging, 'validate'), \
                 mock.patch.object(packaging, 'sign_runtime') as sign:
                with self.assertRaisesRegex(ValueError, 'development bootstrap'):
                    packaging.sign_app(app, 'Publisher')
                sign.assert_not_called()
                run.assert_not_called()

    def test_library_validation_exception_is_only_for_ad_hoc_development_helpers(self):
        for development, identity in [('YES', '-'), (True, '-'), ('NO', '-'),
                                      ('NO', 'Publisher'), ('YES', 'Publisher')]:
            with self.subTest(development=development, identity=identity), \
                 tempfile.TemporaryDirectory() as temporary:
                runtime = Path(temporary) / 'SlateRuntime.framework'
                (runtime / 'Resources').mkdir(parents=True)
                (runtime / 'Resources/Info.plist').write_bytes(plistlib.dumps({
                    'SlateRuntimeDevelopment': development,
                }))
                helpers = [runtime / 'Versions/A/Helpers' / name for name in packaging.TOOLS]
                binaries = helpers + [runtime / 'Versions/A/SlateRuntime',
                                      runtime / 'Versions/A/Frameworks/Dependency.framework/Versions/A/Dependency']
                for binary in binaries:
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
                entitled_paths = []

                def inspect_signing(*args):
                    if '--entitlements' in args:
                        file = Path(args[args.index('--entitlements') + 1])
                        self.assertEqual(plistlib.loads(file.read_bytes()), {
                            'com.apple.security.cs.disable-library-validation': True,
                        })
                        entitled_paths.append(args[-1])
                    return ''

                with mock.patch.object(packaging, 'run', side_effect=inspect_signing):
                    packaging.sign_runtime(runtime, identity)
                expected = helpers if development in (True, 'YES') and identity == '-' else []
                self.assertCountEqual(entitled_paths, expected)

    def test_only_sparkle_downloader_preserves_entitlements_in_both_signing_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary) / 'SlateRuntime.framework'
            (runtime / 'Resources').mkdir(parents=True)
            (runtime / 'Resources/Info.plist').write_bytes(plistlib.dumps({}))
            sparkle = runtime / 'Versions/A/Frameworks/Sparkle.framework/Versions/B'
            downloader = sparkle / 'XPCServices/Downloader.xpc'
            download_binary = downloader / 'Contents/MacOS/Downloader'
            binaries = [download_binary, sparkle / 'Sparkle',
                        sparkle / 'XPCServices/Installer.xpc/Contents/MacOS/Installer',
                        runtime / 'Versions/A/Helpers/slate-term',
                        runtime / 'Versions/A/XPCServices/Downloader.xpc/Contents/MacOS/Downloader']
            for binary in binaries:
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
            with mock.patch.object(packaging, 'run') as run:
                packaging.sign_runtime(runtime, '-')
            preserved = []
            for call in run.call_args_list:
                args = call.args
                if '--sign' not in args:
                    continue
                options = [arg for arg in args if isinstance(arg, str)
                           and arg.startswith('--preserve-metadata')]
                if args[-1] in (downloader, download_binary):
                    self.assertEqual(options, ['--preserve-metadata=entitlements'])
                    preserved.append(args[-1])
                else:
                    self.assertEqual(options, [])
                self.assertNotIn('--entitlements', args)
            self.assertCountEqual(preserved, [download_binary, downloader])

    def runtime_validation_fixture(self, temporary):
        app = Path(temporary) / 'Slate.app'
        runtime = packaging.runtime_path(app)
        resources = runtime / 'Resources'
        resources.mkdir(parents=True)
        (resources / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': packaging.RUNTIME_IDENTIFIER, 'SlateRuntimeABI': '1',
        }))
        for name in ('ghostty', 'terminfo', 'skills'):
            (resources / name).mkdir()
        sparkle = runtime / 'Versions/A/Frameworks/Sparkle.framework'
        (sparkle / 'Resources').mkdir(parents=True)
        (sparkle / 'Resources/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '2.10.0',
        }))
        binaries = [runtime / 'Versions/A/Helpers' / name for name in packaging.TOOLS]
        binaries += [runtime / 'Versions/A/SlateRuntime', app / 'Contents/MacOS/Slate',
                     sparkle / 'Versions/B/Sparkle']
        binaries += [sparkle / relative for relative in packaging.SPARKLE_HELPERS]
        for binary in binaries:
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
            binary.chmod(0o755)
        return app, sparkle

    def test_arm64_validation_allows_universal_code_only_inside_sparkle(self):
        cases = [
            ('arm64', 'arm64', True),
            ('x86_64 arm64', 'arm64', True),
            ('arm64 x86_64', 'arm64', True),
            ('x86_64', 'arm64', False),
            ('arm64 x86_64 arm64e', 'arm64', False),
            ('arm64', 'arm64 x86_64', False),
            ('arm64', 'x86_64', False),
        ]
        for sparkle_archs, app_archs, accepted in cases:
            with self.subTest(sparkle=sparkle_archs, app=app_archs), \
                 tempfile.TemporaryDirectory() as temporary:
                app, sparkle = self.runtime_validation_fixture(temporary)

                def inspect(*args):
                    if args[0] == 'lipo':
                        return sparkle_archs if args[-1].is_relative_to(sparkle) else app_archs
                    return ''

                with mock.patch.object(packaging, 'run', side_effect=inspect) as run:
                    if accepted:
                        packaging.validate(app, 'arm64')
                        self.assertEqual(run.call_args, mock.call(
                            'codesign', '--verify', '--deep', '--strict', packaging.runtime_path(app)))
                    else:
                        with self.assertRaisesRegex(ValueError, 'Expected arm64'):
                            packaging.validate(app, 'arm64')

    def test_sparkle_requires_every_executable_helper(self):
        for relative in packaging.SPARKLE_HELPERS:
            for defect in ('missing', 'not executable', 'directory'):
                with self.subTest(helper=relative, defect=defect), \
                     tempfile.TemporaryDirectory() as temporary:
                    app, sparkle = self.runtime_validation_fixture(temporary)
                    helper = sparkle / relative
                    if defect == 'not executable':
                        helper.chmod(0o644)
                    else:
                        helper.unlink()
                        if defect == 'directory':
                            helper.mkdir()
                    with mock.patch.object(packaging, 'run') as run:
                        with self.assertRaisesRegex(ValueError, 'Missing executable Sparkle component'):
                            packaging.validate(app)
                        run.assert_not_called()

    def test_sparkle_version_must_match_release_pin(self):
        for version in ('2.9.0', None):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                app, sparkle = self.runtime_validation_fixture(temporary)
                info = {'CFBundleShortVersionString': version} if version else {}
                (sparkle / 'Resources/Info.plist').write_bytes(plistlib.dumps(info))
                with mock.patch.object(packaging, 'run') as run:
                    with self.assertRaisesRegex(ValueError, 'Sparkle version.*release pin'):
                        packaging.validate(app)
                    run.assert_not_called()

    def test_runtime_identity_check_fails_before_signature_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Slate.app'
            runtime = packaging.runtime_path(app)
            (runtime / 'Resources').mkdir(parents=True)
            (runtime / 'Resources/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'untrusted.identifier', 'SlateRuntimeABI': '1',
            }))
            with mock.patch.object(packaging, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'identity'):
                    packaging.validate(app)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
