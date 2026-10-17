import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_source", ROOT / "scripts/release-source.py")
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="slate-source-test-")
        self.root = Path(self.temporary.name) / "project"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "user.name", "Source fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.root / "source.swift").write_text("let fixture = true\n")
        (self.root / "licenses").mkdir()
        (self.root / "licenses/manifest.json").write_text(json.dumps({"ghostty_revision": "1" * 40}))
        self.git("add", ".")
        self.git("commit", "-qm", "Source fixture")
        self.app = Path(self.temporary.name) / "Fixture.app"
        (self.app / "Contents").mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"}, stream)
        self.receipt = {
            "source_commit": self.git("rev-parse", "HEAD").strip(), "source_dirty": False,
            "version": "1.2.3", "build_number": "42", "ghostty_revision": "1" * 40,
            "app_tree_sha256": source.app_tree_sha256(self.app),
        }
        self.receipt_path = Path(self.temporary.name) / "build-source.json"
        self.write_receipt()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True)

    def write_receipt(self):
        self.receipt_path.write_text(json.dumps(self.receipt))

    def verify(self):
        return source.verify_build(self.root, self.receipt_path, self.app, "1.2.3", "42")

    def test_build_receipt_binds_clean_commit_version_and_app(self):
        self.assertEqual(self.verify(), self.receipt)
        (self.app / "Contents/modified").write_text("changed")
        with self.assertRaisesRegex(ValueError, "Application changed"):
            self.verify()

    def test_dirty_build_cannot_be_published_after_cleanup(self):
        self.receipt["source_dirty"] = True
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, "clean release build"):
            self.verify()

    def test_dirty_current_tree_cannot_be_archived(self):
        (self.root / "source.swift").write_text("modified")
        with self.assertRaisesRegex(ValueError, "Commit release changes"):
            self.verify()

    def test_commit_mismatch_is_rejected(self):
        self.receipt["source_commit"] = "0" * 40
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, "Current commit"):
            self.verify()

    def test_source_export_contains_only_tracked_files(self):
        (self.root / "private-local.txt").write_text("fixture outside tracked source")
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as tar:
            archive = source.SourceArchive(tar, "fixture")
            archive.git_tree(self.root)
        stream.seek(0)
        with tarfile.open(fileobj=stream) as tar:
            names = tar.getnames()
        self.assertIn("fixture/source.swift", names)
        self.assertNotIn("fixture/private-local.txt", names)
        self.assertFalse(any("/.git/" in name for name in names))

    def test_archive_rejects_private_and_compiled_inputs(self):
        for name in ("../escape", "/absolute", ".git/config", ".env", "private.p12", "cache/output.o"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                source.safe_name(name)

    def test_source_symlinks_cannot_escape_component(self):
        source.safe_link("include/header.h", "../src/header.h")
        for target in ("/outside", "../../outside"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                source.safe_link("include/header.h", target)

    def test_app_permissions_and_symlink_targets_affect_receipt(self):
        path = self.app / "Contents/helper"
        path.write_text("fixture")
        path.chmod(0o644)
        first = source.app_tree_sha256(self.app)
        path.chmod(0o755)
        self.assertNotEqual(first, source.app_tree_sha256(self.app))
        path.unlink()
        path.symlink_to("first")
        first = source.app_tree_sha256(self.app)
        path.unlink()
        path.symlink_to("second")
        self.assertNotEqual(first, source.app_tree_sha256(self.app))

    def test_source_archive_is_bound_to_app_and_verified_without_extraction(self):
        path = Path(self.temporary.name) / "source.tar.gz"
        with tarfile.open(path, mode="w:gz") as tar:
            archive = source.SourceArchive(tar, "Slate-Terminal-1.2.3-42-source")
            archive.add("source.swift", b"source")
            manifest = dict(self.receipt, files=dict(archive.files))
            archive.add("SOURCE-MANIFEST.json", json.dumps(manifest).encode())
        source.verify_source_archive(path, self.receipt)
        changed = dict(self.receipt, app_tree_sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "does not match build receipt"):
            source.verify_source_archive(path, changed)
        self.assertFalse((Path(self.temporary.name) / "Slate-Terminal-1.2.3-42-source").exists())

    def test_modified_source_archive_member_is_rejected(self):
        path = Path(self.temporary.name) / "source.tar.gz"
        with tarfile.open(path, mode="w:gz") as tar:
            archive = source.SourceArchive(tar, "Slate-Terminal-1.2.3-42-source")
            archive.add("source.swift", b"modified")
            manifest = dict(self.receipt, files={"source.swift": {"sha256": "0" * 64, "mode": 0o644}})
            archive.add("SOURCE-MANIFEST.json", json.dumps(manifest).encode())
        with self.assertRaisesRegex(ValueError, "do not match its manifest"):
            source.verify_source_archive(path, self.receipt)

    def test_zig_manifest_requires_content_hash(self):
        manifest = Path(self.temporary.name) / "build.zig.zon"
        manifest.write_text('.{ .dependencies = .{ .bad = .{ .url = "https://example.invalid/archive" }, }, }')
        with self.assertRaisesRegex(ValueError, "Unpinned"):
            source.dependencies(manifest)


if __name__ == "__main__":
    unittest.main()
