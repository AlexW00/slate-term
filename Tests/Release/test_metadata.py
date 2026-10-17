"""Release tags must identify clean, reviewed default-branch source."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/release-metadata.py'
spec = importlib.util.spec_from_file_location('release_metadata', SCRIPT)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.temp.name)
        self.addCleanup(self.cleanup)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        for name in ('LICENSE', 'COPYING.md', 'THIRD_PARTY_NOTICES.md'):
            Path(name).write_text('fixture')
        self.git('add', '.')
        self.git('commit', '-m', 'Initial')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.git('tag', 'v1.2.3')

    def cleanup(self):
        os.chdir(self.previous)
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL).decode().strip()

    def test_accepts_clean_default_branch_tag(self):
        self.assertEqual(metadata.validate('v1.2.3', 'main'),
                         {'tag': 'v1.2.3', 'version': '1.2.3', 'commit': self.git('rev-parse', 'HEAD')})

    def test_rejects_untrusted_tag_syntax(self):
        for tag in ('v01.2.3', '1.2.3', 'v1.2.3-rc1', 'v1.2.3\ninjected=x', '$(id)', '--help'):
            with self.subTest(tag=tag), self.assertRaises(metadata.ReleaseError):
                metadata.validate(tag, 'main')

    def test_rejects_dirty_source(self):
        Path('LICENSE').write_text('changed')
        with self.assertRaisesRegex(metadata.ReleaseError, 'clean'):
            metadata.validate('v1.2.3', 'main')

    def test_rejects_tag_outside_default_branch(self):
        Path('change').touch()
        self.git('add', '.')
        self.git('commit', '-m', 'Unreviewed')
        self.git('tag', 'v1.2.4')
        with self.assertRaisesRegex(metadata.ReleaseError, 'default branch'):
            metadata.validate('v1.2.4', 'main')

    def test_rejects_checkout_that_does_not_match_tag(self):
        self.git('commit', '--allow-empty', '-m', 'Later')
        with self.assertRaisesRegex(metadata.ReleaseError, 'match'):
            metadata.validate('v1.2.3', 'main')


if __name__ == '__main__':
    unittest.main()
