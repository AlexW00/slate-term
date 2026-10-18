import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_licenses", ROOT / "scripts/collect-release-licenses.py")
licenses = importlib.util.module_from_spec(spec)
spec.loader.exec_module(licenses)


class LicenseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="slate-license-test-")
        self.root = Path(self.temporary.name)
        shutil.copytree(ROOT / "licenses", self.root / "licenses")
        for name in ("LICENSE", "COPYING.md", "THIRD_PARTY_NOTICES.md", "Package.resolved",
                     "scripts/build-ghostty.sh",
                     "slate-term.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.root_patch = patch.object(licenses, "ROOT", self.root)
        self.inventory_patch = patch.object(licenses, "LICENSES", self.root / "licenses")
        self.root_patch.start()
        self.inventory_patch.start()

    def tearDown(self):
        self.inventory_patch.stop()
        self.root_patch.stop()
        self.temporary.cleanup()

    def test_installs_complete_inventory_and_detects_tampering(self):
        files, _ = licenses.validate_inventory()
        app = self.root / "Test.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_text("fixture")
        destination = licenses.bundle_destination(app)
        licenses.install_bundle(destination, files)
        self.assertIn(b"GPL-3.0-or-later", (destination / "COPYING.md").read_bytes())
        licenses.verify_bundle(destination, files)
        (destination / "ghostty/LICENSE").write_text("modified")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            licenses.verify_bundle(destination, files)

    def test_missing_notice_is_rejected_even_with_manifest(self):
        files, _ = licenses.validate_inventory()
        destination = self.root / "bundle"
        licenses.install_bundle(destination, files)
        (destination / "TOMLDecoder/LICENSE.md").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            licenses.verify_bundle(destination, files)

    def test_xcode_only_sparkle_pin_requires_review(self):
        path = self.root / "slate-term.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        value = json.loads(path.read_text())
        sparkle = next(pin for pin in value["pins"] if pin["identity"] == "sparkle")
        sparkle["state"]["revision"] = "0" * 40
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "dependencies changed"):
            licenses.validate_inventory()

    def test_changed_dependency_pin_requires_review(self):
        path = self.root / "Package.resolved"
        value = json.loads(path.read_text())
        value["pins"][0]["state"]["revision"] = "0" * 40
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "dependencies changed"):
            licenses.validate_inventory()

    def test_modified_license_is_rejected(self):
        (self.root / "licenses/ghostty/LICENSE").write_text("modified")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            licenses.validate_inventory()

    def test_manifest_path_traversal_is_rejected(self):
        path = self.root / "licenses/manifest.json"
        value = json.loads(path.read_text())
        value["components"]["ghostty"][0]["file"] = "../LICENSE"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            licenses.validate_inventory()

    def test_app_destination_cannot_follow_outside_symlink(self):
        app = self.root / "Test.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_text("fixture")
        (app / "Contents/Resources").symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "stay inside"):
            licenses.bundle_destination(app)

    def test_duplicate_install_is_deterministic(self):
        files, _ = licenses.validate_inventory()
        destination = self.root / "bundle"
        licenses.install_bundle(destination, files)
        first = {str(p.relative_to(destination)): p.read_bytes() for p in destination.rglob("*") if p.is_file()}
        licenses.install_bundle(destination, files)
        second = {str(p.relative_to(destination)): p.read_bytes() for p in destination.rglob("*") if p.is_file()}
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
