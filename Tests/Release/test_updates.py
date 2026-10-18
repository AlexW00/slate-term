import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_updates", ROOT / "scripts/release-updates.py")
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)


class UpdateReleaseTests(unittest.TestCase):
    def info(self):
        return {"SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
                "SUFeedURL": "https://github.com/example/slate/releases/latest/download/appcast.xml",
                "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                "SUSignedFeedFailureExpirationInterval": 0}

    def test_configuration_requires_nonexpiring_signature_validation(self):
        updates.validate_configuration(self.info(), "example/slate")
        for key, value in (("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
                           ("SUSignedFeedFailureExpirationInterval", 60),
                           ("SUSignedFeedFailureExpirationInterval", False), ("SUPublicEDKey", ""),
                           ("SUFeedURL", "https://example.com/appcast.xml")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                updates.validate_configuration({**self.info(), key: value})
        with self.assertRaisesRegex(ValueError, "repository"):
            updates.validate_configuration(self.info(), "different/project")

    def test_key_errors_never_echo_secret(self):
        for value in ("private-secret-not-base64", "YWJj"):
            with self.assertRaises(ValueError) as error:
                updates.decode_key(value, (32, 96))
            self.assertNotIn(value, str(error.exception))

    def test_tools_receive_secret_only_on_stdin_and_hide_error_output(self):
        result = subprocess.CompletedProcess([], 1, "private material", "private material")
        with patch.object(updates.subprocess, "run", return_value=result) as run, patch.dict(os.environ, {
                "SLATE_SPARKLE_PRIVATE_KEY": "private material", "OP_TOKEN": "other private material"}):
            with self.assertRaises(ValueError) as error:
                updates.run_tool(Path("/tools"), "generate_appcast", ["/archives"], "private material", Path("/tmp"))
        self.assertNotIn("private material", str(error.exception))
        args, kwargs = run.call_args
        self.assertEqual(args[0][1:3], ["--ed-key-file", "-"])
        self.assertNotIn("private material", " ".join(args[0]))
        self.assertEqual(kwargs["input"], "private material\n")
        self.assertNotIn("SLATE_SPARKLE_PRIVATE_KEY", kwargs["env"])
        self.assertNotIn("OP_TOKEN", kwargs["env"])

    def fixture(self, directory):
        archive = directory / "Slate-Terminal-1.2.3-42-arm64.zip"
        notes = directory / "Slate-Terminal-1.2.3-42-arm64.md"
        archive.write_bytes(b"signed archive fixture")
        notes.write_text("Reviewed notes")
        root = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        for name, value in (("version", "42"), ("shortVersionString", "1.2.3"), ("minimumSystemVersion", "27.0")):
            ET.SubElement(item, updates.NS + name).text = value
        prefix = "https://github.com/example/slate/releases/download/v1.2.3/"
        signature = base64.b64encode(bytes(64)).decode()
        ET.SubElement(item, "enclosure", {"url": prefix + archive.name, "length": str(archive.stat().st_size), updates.NS + "edSignature": signature})
        note = ET.SubElement(item, updates.NS + "releaseNotesLink", {updates.NS + "edSignature": signature, updates.NS + "length": str(notes.stat().st_size)})
        note.text = prefix + notes.name
        return root, archive, notes

    def test_appcast_binds_version_archive_size_and_immutable_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root, archive, notes = self.fixture(directory)
            feed = directory / "appcast.xml"
            def check():
                feed.write_bytes(ET.tostring(root))
                return updates.inspect_appcast(feed, archive, notes, "example/slate", "1.2.3", "42")
            self.assertEqual(len(check()), 2)
            enclosure = root.find("./channel/item/enclosure")
            original = dict(enclosure.attrib)
            for key, value in (("url", "https://github.com/example/slate/releases/latest/download/other.zip"),
                               ("length", "1"), (updates.NS + "edSignature", "")):
                enclosure.attrib = {**original, key: value}
                with self.subTest(key=key), self.assertRaises(ValueError):
                    check()
            enclosure.attrib = original
            root.find("./channel/item/" + updates.NS + "version").text = "43"
            with self.assertRaisesRegex(ValueError, "version"):
                check()

    def test_signed_notes_must_fit_the_native_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root, archive, notes = self.fixture(directory)
            notes.write_bytes(b"x" * (256 * 1024 + 1))
            root.find("./channel/item/" + updates.NS + "releaseNotesLink").set(updates.NS + "length", str(notes.stat().st_size))
            feed = directory / "appcast.xml"
            feed.write_bytes(ET.tostring(root))
            with self.assertRaisesRegex(ValueError, "native update size limit"):
                updates.inspect_appcast(feed, archive, notes, "example/slate", "1.2.3", "42")

    def test_signed_notes_cannot_be_changed_after_generation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root, archive, notes = self.fixture(directory)
            feed = directory / "appcast.xml"
            feed.write_bytes(ET.tostring(root))
            notes.write_text("Changed release notes")
            with self.assertRaisesRegex(ValueError, "notes size"):
                updates.inspect_appcast(feed, archive, notes, "example/slate", "1.2.3", "42")

    def test_tool_receipt_rejects_changed_distribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary = directory / "tool"
            binary.write_bytes(b"fixture")
            receipt = {"archive_sha256": updates.TOOLS_SHA256, "files": {"tool": updates.hashlib.sha256(binary.read_bytes()).hexdigest()}}
            (directory / "slate-tool-receipt.json").write_text(json.dumps(receipt))
            updates.verify_tools(directory)
            binary.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "changed"):
                updates.verify_tools(directory)

    def test_workflow_stays_tag_only_and_only_creates_drafts(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("tags: ['v*']", workflow)
        for forbidden in ("workflow_dispatch:", "pull_request:", "types: [published]", "gh release edit"):
            self.assertNotIn(forbidden, workflow)
        self.assertIn("--draft --verify-tag", workflow)
        self.assertIn("assets/appcast.xml", workflow)
        self.assertIn("secrets.SLATE_SPARKLE_PRIVATE_KEY", workflow)


if __name__ == "__main__":
    unittest.main()
