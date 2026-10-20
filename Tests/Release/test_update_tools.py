"""CLI integration with public RFC 8032 test vectors; no release credentials or GUI."""
import argparse
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import sys
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_updates_tools", ROOT / "scripts/release-updates.py")
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)
TOOLS = os.environ.get("SLATE_TEST_SPARKLE_TOOLS")
# RFC 8032 section 7.1 test 1. Public test data, never use for a real release.
SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")


@unittest.skipUnless(TOOLS and os.uname().sysname == "Darwin", "Set SLATE_TEST_SPARKLE_TOOLS to the pinned macOS distribution")
class SparkleToolIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="slate-sparkle-cli-test-")
        self.directory = Path(self.temporary.name)
        self.app = self.directory / "Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", self.app / "Contents/MacOS/Fixture")
        (self.app / "Contents/MacOS/Fixture").chmod(0o755)
        self.info = {"CFBundleIdentifier": "invalid.example.slate-update-fixture", "CFBundleExecutable": "Fixture",
                     "CFBundleName": "Slate update fixture", "CFBundlePackageType": "APPL",
                     "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42", "LSMinimumSystemVersion": "27.0",
                     "SUPublicEDKey": base64.b64encode(PUBLIC).decode(),
                     "SUFeedURL": "https://github.com/example/slate/releases/latest/download/appcast.xml",
                     "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                     "SUSignedFeedFailureExpirationInterval": 0}
        self.assets = self.directory / "assets"
        self.assets.mkdir()
        self.notes = self.directory / "reviewed.md"
        self.notes.write_text("## Test release\n\nPublic fixture notes.\n")
        self.secret = base64.b64encode(SEED).decode()
        self.arguments = argparse.Namespace(app=self.app, assets=self.assets, notes=self.notes,
                                            tools=Path(TOOLS).resolve(), repository="example/slate")
        self.archive = self.assets / "Slate-Terminal-1.2.3-42-arm64.zip"

    def tearDown(self):
        self.temporary.cleanup()

    def package(self):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True, capture_output=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(self.app), str(self.archive)], check=True, capture_output=True)

    def test_official_tools_sign_and_verify_feed_archive_notes_and_reject_tampering(self):
        self.package()
        with patch.dict(os.environ, {"SLATE_SPARKLE_PRIVATE_KEY": self.secret}):
            updates.prepare(self.arguments)
        feed = self.assets / "appcast.xml"
        notes = self.assets / "Slate-Terminal-1.2.3-42-arm64.md"
        self.assertEqual(notes.read_bytes(), self.notes.read_bytes())
        signatures = updates.inspect_appcast(feed, self.archive, notes, "example/slate", "1.2.3", "42")
        for path, signature in ((feed, None), (self.archive, signatures[0]), (notes, signatures[1])):
            original = path.read_bytes()
            path.write_bytes(original.replace(b"1.2.3", b"9.9.9") if signature is None else original + b"tampered")
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                updates.run_tool(self.arguments.tools, "sign_update", ["--verify", str(path)] + ([signature] if signature else []), self.secret, self.directory)
            path.write_bytes(original)

    def test_mismatched_embedded_public_key_produces_no_publishable_assets(self):
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.package()
        with patch.dict(os.environ, {"SLATE_SPARKLE_PRIVATE_KEY": self.secret}), self.assertRaises(ValueError):
            updates.prepare(self.arguments)
        self.assertFalse((self.assets / "appcast.xml").exists())
        self.assertFalse((self.assets / "Slate-Terminal-1.2.3-42-arm64.md").exists())

    def test_nested_sparkle_signing_preserves_downloader_entitlements_and_framework_links(self):
        runtime = self.app / "Contents/Frameworks/SlateRuntime.framework"
        version = runtime / "Versions/A"
        (version / "Resources").mkdir(parents=True)
        (runtime / "Versions/Current").symlink_to("A")
        for name in ("Resources", "Frameworks", "Helpers", "SlateRuntime"):
            (runtime / name).symlink_to("Versions/Current/" + name)
        for name in ("ghostty", "terminfo", "skills"):
            (version / "Resources" / name).mkdir()
        (version / "Resources/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.slateterm.runtime", "CFBundleExecutable": "SlateRuntime",
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "42", "SlateRuntimeABI": "1",
        }))
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-dynamiclib", "-x", "c", "-",
                        "-o", str(version / "SlateRuntime")], input=b"int fixture(void) { return 0; }\n",
                       check=True, capture_output=True)
        framework = version / "Frameworks/Sparkle.framework"
        shutil.copytree(Path(TOOLS) / "Sparkle.framework", framework, symlinks=True)
        executable = self.app / "Contents/MacOS/Fixture"
        executable.unlink()
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-x", "c", "-", "-o", str(executable)], input=b"int main(void) { return 0; }\n", check=True, capture_output=True)
        executable.chmod(0o755)
        helpers = version / "Helpers"
        helpers.mkdir()
        for name in ("slate-term", "slate-layout-launcher"):
            shutil.copy2(executable, helpers / name)
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)
        downloader = framework / "Versions/B/XPCServices/Downloader.xpc"
        entitlements = self.directory / "downloader.plist"
        expected = {"com.apple.security.network.client": True}
        entitlements.write_bytes(plistlib.dumps(expected))
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", str(entitlements), str(downloader)], check=True, capture_output=True)
        # Exercise the production runtime signer without release credentials or Keychain access.
        result = subprocess.run([sys.executable, str(ROOT / "scripts/package-runtime.py"),
                                 "sign", "--app", str(self.app), "--identity", "-"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], check=True, capture_output=True)
        actual = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(downloader)], stderr=subprocess.DEVNULL)
        self.assertEqual(plistlib.loads(actual), expected)
        self.assertTrue((framework / "Versions/Current").is_symlink())
        self.assertTrue((framework / "Updater.app").is_symlink())
        for path in (self.app, framework, downloader, framework / "Versions/B/Updater.app", framework / "Versions/B/Autoupdate"):
            details = subprocess.run(["codesign", "-dv", str(path)], capture_output=True, text=True, check=True)
            self.assertIn("runtime", details.stderr)

        # A truncated framework must fail before packaging, even for unsigned smoke builds.
        (framework / 'Versions/B/Autoupdate').unlink()
        missing = subprocess.run([sys.executable, str(ROOT / "scripts/package-runtime.py"),
                                  "verify", "--app", str(self.app), "--architecture", "arm64"],
                                 text=True, capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Runtime link escapes its bundle or is broken:", missing.stderr)
        self.assertIn("Autoupdate", missing.stderr)

    def test_missing_secret_never_invokes_keychain_fallback(self):
        self.package()
        with patch.dict(os.environ, {"SLATE_SPARKLE_PRIVATE_KEY": ""}), patch.object(updates, "run_tool") as run:
            with self.assertRaisesRegex(ValueError, "explicitly"):
                updates.prepare(self.arguments)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
