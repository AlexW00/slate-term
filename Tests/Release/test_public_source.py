"""Exercise a standalone history rewrite using temporary fake repositories."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_public_source", ROOT / "scripts/prepare-public-source.py")
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)
OLD = "/Users/example/.worktrees/local/project/private-task"
NEW = "~/.worktrees/<owner>/<repo>/private-task"
EMAIL = "12345+example@users.noreply.github.com"
FAKE_SCANNER = '''import json, pathlib, subprocess
root = pathlib.Path.cwd()
head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
folder = root / "artifacts/security"
folder.mkdir(parents=True, exist_ok=True)
(folder / "summary.json").write_text(json.dumps({"passed": True, "history_scanned": True, "revision": head, "ref": "--all"}))
'''


def git(root, *args):
    result = subprocess.run(["git", "-c", "core.hooksPath=" + os.devnull, "-C", str(root), *args],
                            env=exporter.environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise AssertionError("Fixture git command failed")
    return result.stdout


class PublicSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool_directory = tempfile.TemporaryDirectory(prefix="slate-filter-test-")
        cls.tool = Path(cls.tool_directory.name) / "git-filter-repo"
        existing = os.environ.get("SLATE_TEST_FILTER_REPO")
        cls.tool.write_bytes(exporter.load_filter_tool(Path(existing) if existing else None))

    @classmethod
    def tearDownClass(cls):
        cls.tool_directory.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="slate export tests ")
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "source with spaces"
        self.source.mkdir()
        git(self.source, "init", "--initial-branch=main")
        git(self.source, "config", "user.name", "Example Author")
        git(self.source, "config", "user.email", EMAIL)
        self.write(".gitignore", ".build/\nartifacts/\n*.p12\n")
        self.write("scripts/security-scan.py", FAKE_SCANNER)
        self.write("history.txt", "Historical reference: " + OLD + "\n")
        self.write("App.xcodeproj/xcuserdata/example.xcuserdatad/settings", "private IDE state\n")
        self.commit("Initial commit with " + OLD)
        self.write("history.txt", "Latest version\n")
        self.commit("Update source")
        self.output = self.directory / "public export"

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, path, contents):
        target = self.source / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def commit(self, message):
        git(self.source, "add", "--all")
        git(self.source, "-c", "commit.gpgsign=false", "commit", "-m", message)

    def prepare(self, **kwargs):
        return exporter.prepare(self.source, self.output, replacements=[(OLD, NEW)], filter_tool=self.tool, **kwargs)

    def test_history_filter_removes_private_paths_and_preserves_source(self):
        before = exporter.snapshot(self.source)
        # These refs must never enter the exported repository.
        tree = git(self.source, "rev-parse", "HEAD^{tree}").decode().strip()
        private_commit = git(self.source, "commit-tree", tree, "-m", "UNIQUE_PRIVATE_BRANCH_COMMIT").decode().strip()
        git(self.source, "branch", "private-side-branch", private_commit)
        git(self.source, "tag", "private-tag", private_commit)
        git(self.source, "update-ref", "refs/stash", private_commit)
        original_refs = git(self.source, "show-ref")
        self.prepare()
        self.assertEqual(before, exporter.snapshot(self.source))
        self.assertEqual(original_refs, git(self.source, "show-ref"))
        self.assertEqual(git(self.output, "for-each-ref", "--format=%(refname)"), b"refs/heads/main\n")
        self.assertEqual(git(self.output, "remote"), b"")
        self.assertEqual(git(self.output, "log", "--format=%ae").decode().splitlines(), [EMAIL, EMAIL])
        self.assertFalse((self.output / "App.xcodeproj/xcuserdata").exists())
        for oid, kind in exporter.SCANNER.object_inventory(self.output, None):
            payload = git(self.output, "cat-file", kind, oid)
            self.assertNotIn(OLD.encode(), payload)
            self.assertNotIn(b"UNIQUE_PRIVATE_BRANCH_COMMIT", payload)
        self.assertIn(NEW.encode(), git(self.output, "show", "HEAD~1:history.txt"))
        self.assertIn(NEW.encode(), git(self.output, "log", "--format=%B"))
        self.assertFalse((self.output / ".git/objects/info/alternates").exists())
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        receipt = json.loads((self.output / ".git/public-source-export.json").read_text())
        self.assertTrue(receipt["secret_scan_passed"])
        self.assertEqual(receipt["source_head"], before["head"])

    def test_explicit_working_tree_snapshot_includes_edits_without_committing_source(self):
        self.write("history.txt", "Uncommitted edit\n")
        self.write("new file.txt", "New source\n")
        self.write(".build/ignored", "private ignored build output\n")
        self.write("ignored.p12", "ignored fake certificate\n")
        private = self.directory / "outside-private-file"
        private.write_text("UNIQUE_DO_NOT_READ_PRIVATE_TARGET")
        (self.source / "link").symlink_to(private)
        before = exporter.snapshot(self.source)
        with self.assertRaisesRegex(exporter.ExportError, "include-working-tree"):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.prepare(include_working_tree=True)
        self.assertEqual(exporter.snapshot(self.source), before)
        self.assertEqual((self.output / "history.txt").read_text(), "Uncommitted edit\n")
        self.assertEqual((self.output / "new file.txt").read_text(), "New source\n")
        self.assertTrue((self.output / "link").is_symlink())
        self.assertEqual(os.readlink(self.output / "link"), str(private))
        self.assertFalse((self.output / ".build").exists())
        self.assertFalse((self.output / "ignored.p12").exists())
        self.assertEqual(git(self.output, "log", "-1", "--format=%s").strip(), b"Prepare source for public release")
        for oid, kind in exporter.SCANNER.object_inventory(self.output, None):
            self.assertNotIn(b"UNIQUE_DO_NOT_READ_PRIVATE_TARGET", git(self.output, "cat-file", kind, oid))

    def test_existing_source_common_directory_and_linked_worktree_destinations_rejected(self):
        linked = self.directory / "linked worktree"
        git(self.source, "worktree", "add", "-b", "another", str(linked))
        for path in (self.source, self.source / "nested", self.source / ".git/private-export", linked / "nested"):
            with self.subTest(path=path):
                with self.assertRaises(exporter.ExportError):
                    exporter.validate_output(self.source, path)
        empty = self.directory / "existing empty"
        empty.mkdir()
        with self.assertRaisesRegex(exporter.ExportError, "already exists"):
            exporter.validate_output(self.source, empty)

    def test_export_from_linked_worktree_selects_that_head(self):
        linked = self.directory / "selected linked worktree"
        git(self.source, "worktree", "add", "-b", "selected", str(linked))
        (linked / "selected.txt").write_text("Selected worktree branch\n")
        git(linked, "add", "selected.txt")
        git(linked, "-c", "commit.gpgsign=false", "commit", "-m", "Selected branch commit")
        original_main = git(self.source, "rev-parse", "HEAD")
        exporter.prepare(linked, self.output, replacements=[(OLD, NEW)], filter_tool=self.tool)
        self.assertEqual((self.output / "selected.txt").read_text(), "Selected worktree branch\n")
        self.assertEqual(git(self.source, "rev-parse", "HEAD"), original_main)
        self.assertEqual(git(self.output, "for-each-ref", "--format=%(refname)"), b"refs/heads/main\n")

    def test_tracked_sensitive_filename_rejected_even_when_ignored(self):
        self.write("signing.p12", "fake certificate")
        git(self.source, "add", "-f", "signing.p12")
        with self.assertRaisesRegex(exporter.ExportError, "private credentials"):
            self.prepare(include_working_tree=True)
        self.assertFalse(self.output.exists())

    def test_historical_sensitive_filename_blocks_export_even_if_deleted(self):
        self.write("secret.key", "fake old key")
        self.commit("Historical private file")
        (self.source / "secret.key").unlink()
        self.commit("Remove private file")
        with self.assertRaisesRegex(exporter.ExportError, "private filename remains"):
            self.prepare()
        self.assertTrue(self.output.is_dir())
        self.assertFalse((self.output / ".git/public-source-export.json").exists())

    def test_failed_secret_scan_leaves_private_export_without_ready_receipt(self):
        self.write("scripts/security-scan.py", "import sys; print('UNIQUE_FAKE_SECRET'); sys.exit(1)\n")
        self.commit("Failing scanner fixture")
        with self.assertRaises(exporter.ExportError) as error:
            self.prepare()
        self.assertNotIn("UNIQUE_FAKE_SECRET", str(error.exception))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        self.assertFalse((self.output / ".git/public-source-export.json").exists())

    def test_concurrent_source_change_invalidates_export(self):
        original_verify = exporter.verify_history
        def mutate_source(output, replacements):
            original_verify(output, replacements)
            self.write("history.txt", "Changed concurrently\n")
        with mock.patch.object(exporter, "verify_history", side_effect=mutate_source):
            with self.assertRaisesRegex(exporter.ExportError, "source changed"):
                self.prepare()
        self.assertFalse((self.output / ".git/public-source-export.json").exists())
        self.assertEqual((self.source / "history.txt").read_text(), "Changed concurrently\n")

    def test_tracked_parent_symlink_cannot_copy_external_file(self):
        self.write("folder/file.txt", "tracked\n")
        self.commit("Nested source")
        (self.source / "folder/file.txt").unlink()
        (self.source / "folder").rmdir()
        external = self.directory / "external"
        external.mkdir()
        (external / "file.txt").write_text("private")
        (self.source / "folder").symlink_to(external, target_is_directory=True)
        with self.assertRaises(exporter.ExportError):
            exporter.snapshot(self.source)

    def test_untrusted_filter_script_is_never_executed(self):
        invalid = self.directory / "modified-filter"
        invalid.write_text("raise RuntimeError('must not execute')\n")
        with self.assertRaisesRegex(exporter.ExportError, "checksum mismatch"):
            exporter.load_filter_tool(invalid)


if __name__ == "__main__":
    unittest.main()
