"""Isolated publisher filesystem tests; signing itself is covered by native crypto tests.
Never reads Keychain, real app data or release directories.
"""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-release.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hero-oos-publisher-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Hero OOS.app"
        (self.app / "Contents").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.key = base64.b64encode(bytes(32)).decode()
        self.args = SimpleNamespace(app=self.app, release_dir=self.root / "releases", sparkle_bin=self.bin,
                                    key_account="test-only", schema=1)

    def info(self, build):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.hero-oos.native", "CFBundleVersion": str(build),
            "CFBundleShortVersionString": f"1.7.{build}", "SUPublicEDKey": self.key,
            "SUFeedURL": publisher.ROOT_URL + "appcast.xml", "LSMinimumSystemVersion": "15.0"}))

    def fake_command(self, args):
        args = [str(item) for item in args]
        name = Path(args[0]).name
        if name == "generate_keys":
            return self.key
        if name == "lipo":
            return "arm64"
        if name == "ditto":
            Path(args[-1]).write_bytes((self.app / "Contents/Info.plist").read_bytes())
        if name == "sign_update" and "-p" in args:
            return "" if args[-1].endswith(".xml") else base64.b64encode(bytes(64)).decode()
        return ""

    def publish(self, build):
        self.info(build)
        with patch.object(publisher, "command", self.fake_command), contextlib.redirect_stdout(io.StringIO()):
            publisher.publish(self.args)

    def testEleventhReleaseRetiresOnlyOldIndexedArchive(self):
        self.args.release_dir.mkdir()
        unrelated = self.args.release_dir / "do-not-delete.zip"
        unrelated.write_bytes(b"user owned")
        for build in range(1, 12):
            self.publish(build)
        catalog = json.loads((self.args.release_dir / "versions.json").read_bytes())
        self.assertEqual([item["build"] for item in catalog["versions"]], list(range(11, 1, -1)))
        self.assertFalse((self.args.release_dir / "Hero-OOS-build-1-arm64.zip").exists())
        self.assertEqual(unrelated.read_bytes(), b"user owned")
        self.assertEqual(len(list(self.args.release_dir.glob("Hero-OOS-build-*.zip"))), 10)

    def testCannotOverwriteOrPublishLowerBuild(self):
        self.publish(2)
        before = (self.args.release_dir / "versions.json").read_bytes()
        with self.assertRaises(ValueError):
            self.publish(2)
        with self.assertRaises(ValueError):
            self.publish(1)
        self.assertEqual((self.args.release_dir / "versions.json").read_bytes(), before)

    def testArchiveTamperingPreventsIndexChangesAndCleanup(self):
        self.publish(1)
        (self.args.release_dir / "Hero-OOS-build-1-arm64.zip").write_bytes(b"tampered")
        before = (self.args.release_dir / "versions.json").read_bytes()
        with self.assertRaises(ValueError):
            self.publish(2)
        self.assertEqual((self.args.release_dir / "versions.json").read_bytes(), before)

    def testSymlinkedArchiveIsNeverFollowedOrDeleted(self):
        self.publish(1)
        archive = self.args.release_dir / "Hero-OOS-build-1-arm64.zip"
        other = self.root / "important.bin"
        archive.rename(other)
        archive.symlink_to(other)
        with self.assertRaises(ValueError):
            self.publish(2)
        self.assertTrue(other.exists())

    def testFeedRequiresArmHardwareAndSignedEnclosure(self):
        self.publish(1)
        feed = ET.fromstring((self.args.release_dir / "appcast.xml").read_bytes())
        item = feed.find("channel/item")
        self.assertEqual(item.find("{%s}hardwareRequirements" % publisher.NAMESPACE).text, "arm64")
        self.assertEqual(item.find("{%s}version" % publisher.NAMESPACE).text, "1")
        self.assertEqual(item.find("enclosure").get("{%s}edSignature" % publisher.NAMESPACE), base64.b64encode(bytes(64)).decode())


if __name__ == "__main__":
    unittest.main()
