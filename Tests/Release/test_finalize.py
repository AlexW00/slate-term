"""Release finalization guards with local fixtures and fake remote responses."""
import argparse
import base64
from contextlib import ExitStack
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_finalize', ROOT / 'scripts/release-finalize.py')
finalize = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(finalize)


def release_fixture(tag='v1.2.0', build='6', draft=True):
    stem = f'Slate-Terminal-{tag[1:]}-{build}'
    names = [stem + suffix for suffix in ('-arm64.zip', '-arm64.dmg', '-arm64.md', '-source.tar.gz')]
    names += ['Slate-Terminal-arm64.dmg', 'appcast.xml', 'SHA256SUMS']
    return {'id': 123, 'tag_name': tag, 'draft': draft, 'prerelease': False, 'body': stem + '-arm64.md',
            'published_at': None if draft else '2026-10-19T14:20:05Z',
            'html_url': 'https://github.com/example/slate/releases/tag/' + tag,
            'assets': [{'id': index, 'name': name, 'size': 1, 'digest': 'sha256:' + 'a' * 64,
                        'updated_at': '2026-10-19T14:00:00Z'} for index, name in enumerate(names)]}


class FinalizeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='slate-finalize-tests-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.args = argparse.Namespace(repository='example/slate', tag='v1.2.0', output=self.directory,
                                       native_evidence=None, native_waiver='Explicit test fixture waiver',
                                       ledger=self.directory / 'CHANGELOG.md')
        self.release = release_fixture()
        self.commit = 'a' * 40
        self.runs = {workflow: {'status': 'completed', 'conclusion': 'success', 'headSha': self.commit,
                               'headBranch': self.args.tag, 'databaseId': index}
                     for index, workflow in enumerate(('ci.yml', 'release.yml'))}
        self.assets = self.directory / 'assets'
        self.assets.mkdir()
        for asset in self.release['assets']:
            if asset['name'] != 'SHA256SUMS':
                (self.assets / asset['name']).write_bytes(asset['name'].encode())
        self.names = {asset['name'] for asset in self.release['assets']}
        self.rewrite_checksums()

    def rewrite_checksums(self):
        content = ''.join(finalize.digest(self.assets / name) + '  ' + name + '\n'
                          for name in sorted(self.names - {'SHA256SUMS'}))
        (self.assets / 'SHA256SUMS').write_text(content)
        for asset in self.release['assets']:
            path = self.assets / asset['name']
            asset.update(digest='sha256:' + finalize.digest(path), size=path.stat().st_size)

    def save_receipt(self):
        receipt = dict(repository=self.args.repository, tag=self.args.tag, commit=self.commit, build='6',
                       releaseID=self.release['id'], assets=finalize.asset_identity(self.release),
                       sha256=finalize.checksums(self.assets, self.names))
        finalize.write_json(self.directory / 'verified.json', receipt)
        return receipt

    def fake_remote(self, baseline):
        """Exercise publication through candidate discovery without invoking gh."""
        def gh(*arguments):
            if arguments[0] == 'run':
                return list(self.runs.values())
            route = arguments[-1]
            if '/commits/' in route:
                return {'sha': self.commit}
            if '/releases/tags/' in route:
                return copy.deepcopy(self.release)
            if '/releases?' in route:
                return [[baseline] if baseline else []]
            raise AssertionError('Unexpected remote read: ' + repr(arguments))

        def run(*arguments, **kwargs):
            if arguments[:2] == ('git', 'rev-parse'):
                return self.commit + '\n'
            raise AssertionError('Unexpected external command: ' + repr(arguments))

        stack = ExitStack()
        stack.enter_context(patch.object(finalize, 'gh', side_effect=gh))
        commands = stack.enter_context(patch.object(finalize, 'run', side_effect=run))
        self.addCleanup(stack.close)
        return commands

    def test_checksum_inventory_and_content_are_both_required(self):
        original = (self.assets / 'SHA256SUMS').read_text()
        self.assertEqual(set(finalize.checksums(self.assets, self.names)), self.names)
        cases = {'missing': original.split('\n', 1)[1], 'duplicate': original + original.splitlines()[0] + '\n',
                 'traversal': 'a' * 64 + '  ../outside\n', 'absolute': 'a' * 64 + '  /tmp/outside\n'}
        for label, content in cases.items():
            with self.subTest(label=label):
                (self.assets / 'SHA256SUMS').write_text(content)
                with self.assertRaises(ValueError):
                    finalize.checksums(self.assets, self.names)
        (self.assets / 'SHA256SUMS').write_text(original)
        (self.assets / 'appcast.xml').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
            finalize.checksums(self.assets, self.names)

    def test_checksum_rejects_symlink_even_with_matching_bytes(self):
        path = self.assets / 'appcast.xml'
        outside = self.directory / 'outside.xml'
        path.rename(outside)
        path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
            finalize.checksums(self.assets, self.names)

    def test_release_inventory_rejects_wrong_version_and_duplicate_assets(self):
        for changed in (release_fixture(tag='v1.3.0'), copy.deepcopy(self.release)):
            if changed['tag_name'] == self.args.tag:
                changed['assets'].append(copy.deepcopy(changed['assets'][0]))
            with self.subTest(assets=changed['assets']), self.assertRaises(ValueError):
                finalize.layout(changed, self.args.tag)

    def test_workflow_success_requires_both_expected_workflows(self):
        for runs in ({}, {'ci.yml': self.runs['ci.yml']}, {**self.runs, 'release.yml': None},
                     {**self.runs, 'release.yml': {'status': 'completed', 'conclusion': 'failure'}}):
            with self.subTest(runs=runs), self.assertRaises(ValueError):
                finalize.require_runs(runs)

    def test_receipt_rejects_remote_asset_replacement(self):
        self.save_receipt()
        for field, value in (('id', 999), ('size', 999), ('digest', 'sha256:' + 'b' * 64),
                             ('updated_at', '2026-10-20T00:00:00Z')):
            changed = copy.deepcopy(self.release)
            changed['assets'][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'Candidate changed'):
                finalize.verified(self.args, changed, self.commit)

    def test_receipt_rejects_rewritten_local_assets_and_checksums(self):
        self.save_receipt()
        (self.assets / 'appcast.xml').write_text('replacement')
        original_release = copy.deepcopy(self.release)
        self.rewrite_checksums()
        with self.assertRaisesRegex(ValueError, 'Verified local assets changed'):
            finalize.verified(self.args, original_release, self.commit)

    def test_receipt_build_cannot_override_archive_build(self):
        receipt = self.save_receipt()
        receipt['build'] = '999'
        finalize.write_json(self.directory / 'verified.json', receipt)
        with self.assertRaises(ValueError):
            finalize.verified(self.args, self.release, self.commit)

    def test_publish_rejects_version_or_build_regression_before_external_edit(self):
        self.save_receipt()
        for tag, build in (('v1.3.0', '5'), ('v1.2.0', '5'), ('v1.1.0', '6'), ('v1.1.0', '7')):
            with self.subTest(tag=tag, build=build):
                commands = self.fake_remote(release_fixture(tag, build, draft=False))
                with self.assertRaisesRegex(ValueError, 'Version and build'):
                    finalize.publish(self.args)
                self.assertFalse(any(call.args[:3] == ('gh', 'release', 'edit') for call in commands.call_args_list))
                self.assertFalse((self.directory / 'publication-intent.json').exists())

    def test_publish_requires_recorded_native_evidence_or_explicit_waiver(self):
        self.save_receipt()
        self.args.native_waiver = None
        self.fake_remote(release_fixture('v1.1.0', '5', draft=False))
        with self.assertRaisesRegex(ValueError, 'native evidence'):
            finalize.publish(self.args)

    def test_repeated_publication_only_resumes_readback(self):
        self.release.update(draft=False, published_at='2026-10-19T14:20:05Z')
        self.save_receipt()
        commands = self.fake_remote(self.release)
        with patch.object(finalize, 'public', return_value={'unauthenticated': True}) as readback:
            self.assertEqual(finalize.publish(self.args), {'unauthenticated': True})
            finalize.publish(self.args)
        self.assertEqual(readback.call_count, 2)
        self.assertFalse(any(call.args[0] == 'gh' for call in commands.call_args_list))

    def test_first_publication_records_intent_before_exact_remote_edit(self):
        receipt = self.save_receipt()
        expected_command = ('gh', 'release', 'edit', self.args.tag, '--repo', self.args.repository,
                            '--draft=false', '--prerelease=false', '--latest')
        events = []

        def edit(*command):
            self.assertEqual(command, expected_command)
            intent = json.loads((self.directory / 'publication-intent.json').read_text())
            self.assertEqual(intent, dict(tag=self.args.tag, commit=self.commit,
                                         nativeEvidence=None, nativeWaiver=self.args.native_waiver))
            events.append('edit')

        def readback(args):
            self.assertEqual(events, ['edit'])
            events.append('readback')
            return {'unauthenticated': True}

        with patch.object(finalize, 'candidate', return_value=(self.release, self.commit, self.runs)), \
                patch.object(finalize, 'verified', return_value=receipt), \
                patch.object(finalize, 'latest', return_value=release_fixture('v1.1.0', '5', draft=False)), \
                patch.object(finalize, 'run', side_effect=edit) as command, \
                patch.object(finalize, 'public', side_effect=readback):
            self.assertEqual(finalize.publish(self.args), {'unauthenticated': True})
        command.assert_called_once_with(*expected_command)
        self.assertEqual(events, ['edit', 'readback'])

    def test_ledger_date_change_is_narrow_and_idempotent(self):
        original = ('# Changelog\r\n\r\n## Unreleased\r\n\r\n### Fixed\r\n\r\n- Concurrent edit.\r\n\r\n'
                    '## 1.2.0 — Pending publication\r\n\r\n- Reviewed release.\r\n\r\n'
                    '## 1.1.0 — 2026-10-18\r\n\r\n- Old release.\r\n')
        expected = original.replace('## 1.2.0 — Pending publication', '## 1.2.0 — 2026-10-19')
        actual = finalize.reconcile_text(original, '1.2.0', '2026-10-19T14:20:05Z')
        self.assertEqual(actual, expected)
        self.assertEqual(finalize.reconcile_text(actual, '1.2.0', '2026-10-19T14:20:05Z'), expected)
        for invalid in ('## Unreleased\n', original + '\n## 1.2.0 — Pending publication\n',
                        original.replace('Pending publication', '2026-10-18')):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                finalize.reconcile_text(invalid, '1.2.0', '2026-10-19T14:20:05Z')

    def test_public_download_retries_transient_failures_without_authentication(self):
        payload = b'verified public bytes'
        expected = hashlib.sha256(payload).hexdigest()
        output = self.directory / 'public.bin'
        responses = [urllib.error.URLError('transient'), io.BytesIO(b'stale CDN bytes'), io.BytesIO(payload)]
        with patch.object(finalize.urllib.request, 'urlopen', side_effect=responses) as fetch, \
                patch.object(finalize.time, 'sleep'):
            finalize.download_public('https://github.com/example/slate/releases/latest/download/test', output, expected,
                                     mutable=True)
        self.assertEqual(output.read_bytes(), payload)
        self.assertEqual(fetch.call_count, 3)
        for call in fetch.call_args_list:
            request = call.args[0]
            self.assertEqual({key.lower() for key, _ in request.header_items()}, {'user-agent'})
        self.assertFalse(output.with_suffix('.bin.part').exists())

    def test_public_download_failure_keeps_verified_file_and_cleans_partial(self):
        output = self.directory / 'public.bin'
        output.write_bytes(b'previous verified bytes')
        with patch.object(finalize.urllib.request, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(b'wrong')), \
                patch.object(finalize.time, 'sleep'), self.assertRaises(ValueError):
            finalize.download_public('https://example.invalid/asset', output, 'a' * 64)
        self.assertEqual(output.read_bytes(), b'previous verified bytes')
        self.assertFalse(output.with_suffix('.bin.part').exists())

    def test_public_resume_reuses_immutable_cache_but_rechecks_latest_routes(self):
        self.release.update(draft=False, published_at='2026-10-19T14:20:05Z')
        receipt = self.save_receipt()
        directory = self.directory / 'public'
        directory.mkdir()
        for name in receipt['sha256']:
            (directory / name).write_bytes((self.assets / name).read_bytes())
        with patch.object(finalize, 'candidate', return_value=(self.release, self.commit, self.runs)), \
                patch.object(finalize.urllib.request, 'urlopen',
                             side_effect=lambda request, **kwargs: io.BytesIO((self.assets / request.full_url.rsplit('/', 1)[1]).read_bytes())) as fetch:
            result = finalize.public(self.args)
        self.assertTrue(result['unauthenticated'])
        self.assertEqual({call.args[0].full_url.rsplit('/', 1)[1] for call in fetch.call_args_list},
                         {'appcast.xml', 'Slate-Terminal-arm64.dmg'})
        self.assertTrue(all('/latest/download/' in call.args[0].full_url for call in fetch.call_args_list))

    def test_reconcile_preserves_actual_file_bytes_and_does_not_rewrite_twice(self):
        self.release.update(draft=False, published_at='2026-10-19T14:20:05Z')
        receipt = self.save_receipt()
        finalize.write_json(self.directory / 'public.json',
                            dict(releaseID=self.release['id'], commit=self.commit, sha256=receipt['sha256']))
        original = ('# Changelog\r\n\r\n## Unreleased\r\n\r\n- Unrelated pending edit.\r\n\r\n'
                    '## 1.2.0 — Pending publication\r\n\r\n- Released behavior.\r\n\r\n'
                    '## 1.1.0 — 2026-10-18\r\n\r\n- Previous release.\r\n').encode()
        self.args.ledger.write_bytes(original)
        with patch.object(finalize, 'candidate', return_value=(self.release, self.commit, self.runs)):
            self.assertTrue(finalize.reconcile(self.args)['changed'])
            expected = original.replace('1.2.0 — Pending publication'.encode(), '1.2.0 — 2026-10-19'.encode())
            self.assertEqual(self.args.ledger.read_bytes(), expected)
            with patch.object(Path, 'write_bytes', side_effect=AssertionError('Idempotent reconciliation must not write')):
                self.assertFalse(finalize.reconcile(self.args)['changed'])
            self.assertEqual(self.args.ledger.read_bytes(), expected)

    def test_dmg_mismatch_and_hash_error_both_detach_the_owned_mount(self):
        def mount_fixture(*command, **kwargs):
            if command[:2] == ('hdiutil', 'attach'):
                mount = Path(command[command.index('-mountpoint') + 1])
                (mount / 'Slate Terminal.app').mkdir()
            elif command[:2] != ('hdiutil', 'detach'):
                raise AssertionError('Unexpected command: ' + repr(command))

        for hash_result in ('wrong app hash', OSError('fixture unreadable')):
            with self.subTest(hash_result=hash_result), patch.object(finalize, 'run', side_effect=mount_fixture) as run:
                options = {'side_effect': hash_result} if isinstance(hash_result, Exception) else {'return_value': hash_result}
                with patch.object(finalize.source, 'app_tree_sha256', **options), self.assertRaises((ValueError, OSError)):
                    finalize.verify_dmg_app(self.directory / 'fixture.dmg', 'expected app hash')
                self.assertEqual(len(run.call_args_list), 2)
                attach, detach = [call.args for call in run.call_args_list]
                self.assertIn('-readonly', attach)
                self.assertEqual(detach, ('hdiutil', 'detach', attach[attach.index('-mountpoint') + 1]))

    def test_dependency_inventory_requires_tagged_pins_and_each_source_group(self):
        inventory = dict(ghostty_revision='b' * 40, zig_version='0.16.0',
                         xcode_swift_pins={'sparkle': 'c' * 40},
                         components={'library': [{'source': {'zig_content_hash': 'pinned-zig-package'}}]})
        paths = ['vendor/ghostty/build.zig', 'vendor/ghostty/src/main.zig', 'vendor/ghostty/pkg/library.c',
                 'vendor/swift/sparkle/source.swift', 'vendor/zig-runtime-source/LICENSE',
                 'vendor/zig-runtime-source/lib/compiler_rt.zig', 'vendor/zig-runtime-source/lib/ubsan_rt.zig',
                 'vendor/ghostty/zig-pkg/pinned-zig-package/source.c']
        paths += ['vendor/zig-runtime-source/lib/' + name + '/source.c'
                  for name in ('std', 'compiler_rt', 'libcxx', 'libcxxabi', 'libunwind')]
        manifest = dict(ghostty_revision=inventory['ghostty_revision'], zig_version=inventory['zig_version'],
                        swift_packages=[{'identity': 'sparkle', 'revision': inventory['xcode_swift_pins']['sparkle']}],
                        zig_packages=['pinned-zig-package'],
                        files={name: {'sha256': 'd' * 64, 'mode': 0o644} for name in paths})
        variants = []
        for prefix in ('vendor/', 'vendor/ghostty/', 'vendor/ghostty/pkg/', 'vendor/swift/',
                       'vendor/zig-runtime-source/', 'vendor/zig-runtime-source/lib/libcxx/',
                       'vendor/ghostty/zig-pkg/'):
            changed = copy.deepcopy(manifest)
            changed['files'] = {name: value for name, value in changed['files'].items() if not name.startswith(prefix)}
            variants.append(('missing ' + prefix, changed))
        for field, value in (('ghostty_revision', 'e' * 40), ('zig_version', '0.17.0'),
                             ('swift_packages', [{'identity': 'sparkle', 'revision': 'e' * 40}]),
                             ('zig_packages', []), ('zig_packages', ['unrelated-package'])):
            changed = copy.deepcopy(manifest)
            changed[field] = value
            variants.append(('mismatched ' + field, changed))
        with patch.object(finalize, 'run', return_value=json.dumps(inventory)) as run:
            finalize.verify_dependency_inventory(manifest, self.commit)
            run.assert_called_once_with('git', 'show', self.commit + ':licenses/manifest.json')
            for label, changed in variants:
                with self.subTest(label=label), self.assertRaises(ValueError):
                    finalize.verify_dependency_inventory(changed, self.commit)


class ProjectSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='slate-finalize-source-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / 'project'
        self.root.mkdir()
        self.git('init', '-q', '--template=')
        self.entries = {'source.swift': (b'let release = true\n', 0o644, None),
                        'helper.sh': (b'#!/bin/sh\nexit 0\n', 0o755, None),
                        'source-link': (b'', 0o777, 'source.swift')}
        for name, (data, mode, target) in self.entries.items():
            path = self.root / name
            if target:
                path.symlink_to(target)
            else:
                path.write_bytes(data)
                path.chmod(mode)
        self.git('add', '.')
        self.git('commit', '-qm', 'Public release fixture')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        self.entries.update({'REBUILD.md': (b'Rebuild this release.\n', 0o644, None),
                             'prepare-rebuild.py': (b'# Fixture rebuild preparation\n', 0o755, None),
                             'vendor/library/source.c': (b'int dependency = 1;\n', 0o644, None)})
        patcher = patch.object(finalize, 'ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def git(self, *arguments):
        return subprocess.check_output(['git', '-C', str(self.root), '-c', 'user.name=Release fixture',
                                        '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
                                        '-c', 'core.hooksPath=/dev/null', *arguments], text=True)

    def packaged_manifest(self, entries):
        receipt = dict(source_commit=self.commit, version='1.2.0', build_number='6',
                       app_tree_sha256='a' * 64, ghostty_revision='b' * 40)
        path = self.directory / 'source.tar.gz'
        with tarfile.open(path, 'w:gz') as stream:
            archive = finalize.source.SourceArchive(stream, 'Slate-Terminal-1.2.0-6-source')
            for name, (data, mode, target) in entries.items():
                archive.add(name, data, mode, target)
            manifest = dict(receipt, files=dict(archive.files))
            archive.add('SOURCE-MANIFEST.json', json.dumps(manifest).encode())
        # Each fixture is internally consistent; the Git comparison supplies the independent check.
        return finalize.source.verify_source_archive(path, receipt)

    def test_matching_tagged_files_generated_files_and_vendor_are_accepted(self):
        manifest = self.packaged_manifest(self.entries)
        (self.root / 'source.swift').write_text('uncommitted later edit')
        finalize.verify_project_source(manifest, self.commit)

    def test_consistent_archive_cannot_substitute_unrelated_missing_modified_or_mode_changed_source(self):
        unrelated = {name: value for name, value in self.entries.items()
                     if name in ('REBUILD.md', 'prepare-rebuild.py') or name.startswith('vendor/')}
        unrelated['unrelated.swift'] = (b'let unrelated = true\n', 0o644, None)
        missing = {name: value for name, value in self.entries.items() if name != 'source.swift'}
        variants = {'unrelated': unrelated, 'missing': missing,
                    'modified': {**self.entries, 'source.swift': (b'let release = false\n', 0o644, None)},
                    'mode changed': {**self.entries, 'helper.sh': (self.entries['helper.sh'][0], 0o644, None)},
                    'symlink changed': {**self.entries, 'source-link': (b'', 0o777, 'helper.sh')}}
        for label, entries in variants.items():
            with self.subTest(label=label):
                manifest = self.packaged_manifest(entries)
                with self.assertRaisesRegex(ValueError, 'differs from tagged Git tree'):
                    finalize.verify_project_source(manifest, self.commit)

    def test_missing_generated_files_and_extra_project_files_are_rejected(self):
        variants = [{name: value for name, value in self.entries.items() if name != 'REBUILD.md'},
                    {name: value for name, value in self.entries.items() if name != 'prepare-rebuild.py'},
                    {**self.entries, 'untracked.swift': (b'let extra = true\n', 0o644, None)}]
        for entries in variants:
            with self.subTest(names=sorted(entries)):
                manifest = self.packaged_manifest(entries)
                with self.assertRaisesRegex(ValueError, 'Unexpected project source inventory'):
                    finalize.verify_project_source(manifest, self.commit)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swift'), 'Requires macOS Swift and CryptoKit')
class SignatureHelperTests(unittest.TestCase):
    def test_rfc8032_empty_message_signature_and_tampered_message(self):
        # RFC 8032 section 7.1, test 1. Public verification vector; no signing key is used.
        public = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        signature = bytes.fromhex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f'
                                  'b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        with tempfile.TemporaryDirectory(prefix='slate-signature-fixture-') as temporary:
            directory = Path(temporary)
            payload = directory / 'message'
            request = dict(publicKey=base64.b64encode(public).decode(),
                           files=[dict(path=str(payload), signature=base64.b64encode(signature).decode())])
            for contents, success in ((b'', True), (b'tampered', False)):
                payload.write_bytes(contents)
                result = subprocess.run(['swift', '-module-cache-path', str(directory / 'swift-cache'),
                                         str(ROOT / 'scripts/verify-release-signatures.swift')],
                                        input=json.dumps(request), capture_output=True, text=True, timeout=180)
                with self.subTest(contents=contents):
                    if success:
                        self.assertEqual(result.returncode, 0, result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('Release signature verification failed', result.stderr)


if __name__ == '__main__':
    unittest.main()
