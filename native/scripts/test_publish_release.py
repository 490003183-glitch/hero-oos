"""Isolated publisher filesystem and file-key signing tests.
Never reads Keychain, production keys, real app data or release directories.
"""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-release.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
real_command = publisher.command
OFFICIAL_TOOLS = Path(os.environ.get("HERO_OOS_SPARKLE_TEST_TOOLS", Path(__file__).resolve().parent.parent / ".build/sparkle-tools/bin"))
# Public RFC 8032 Ed25519 test vector; never a production signing identity.
TEST_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
TEST_PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
OTHER_TEST_SEED = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")


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
        self.calls = []

    def info(self, build):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.hero-oos.native", "CFBundleVersion": str(build),
            "CFBundleShortVersionString": f"1.7.{build}", "SUPublicEDKey": self.key,
            "SUFeedURL": publisher.ROOT_URL + "appcast.xml", "LSMinimumSystemVersion": "15.0"}))

    def fake_command(self, args, **kwargs):
        args = [str(item) for item in args]
        # Record argv only. Private key data is allowed only on stdin and is
        # deliberately never retained by the test's command audit.
        self.calls.append(args)
        name = Path(args[0]).name
        if name == "swift" or (name == "sign_update" and "--ed-key-file" in args):
            return real_command(args, **kwargs)
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

    def file_key(self, *, seed=TEST_SEED):
        self.key = base64.b64encode(TEST_PUBLIC).decode()
        path = self.root / "private-signing-key"
        path.write_bytes(base64.b64encode(seed) + b"\n")
        path.chmod(0o600)
        self.args.key_account = None
        self.args.ed_key_file = path
        self.args.sparkle_bin = OFFICIAL_TOOLS
        return path

    @unittest.skipUnless((OFFICIAL_TOOLS / "sign_update").is_file(), "Official Sparkle tool unavailable")
    def testFileKeyPublishesWithOfficialSignaturesWithoutAnyKeychainCall(self):
        key = self.file_key()
        self.publish(1)
        self.publish(2)  # Also exercise verification of an existing signed index.
        self.assertFalse(any(Path(call[0]).name == "generate_keys" for call in self.calls))
        sign_calls = [call for call in self.calls if Path(call[0]).name == "sign_update"]
        self.assertGreaterEqual(len(sign_calls), 14)
        for call in sign_calls:
            self.assertEqual(call[1:3], ["--ed-key-file", "-"])
            self.assertNotIn("--account", call)
            self.assertNotIn(base64.b64encode(TEST_SEED).decode(), " ".join(call))
        catalog = json.loads((self.args.release_dir / "versions.json").read_bytes())
        self.assertEqual([entry["build"] for entry in catalog["versions"]], [2, 1])
        for path in self.args.release_dir.iterdir():
            self.assertFalse(path.is_symlink())
            if path.is_file():
                self.assertNotEqual(path.read_bytes(), key.read_bytes())
                self.assertNotIn(base64.b64encode(TEST_SEED), path.read_bytes())
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless((OFFICIAL_TOOLS / "sign_update").is_file(), "Official Sparkle tool unavailable")
    def testWrongFileKeyFailsProofBeforeReleaseOrIndexIsChanged(self):
        key = self.file_key()
        self.publish(1)
        before = {path.name: path.read_bytes() for path in self.args.release_dir.iterdir() if path.is_file()}
        key.write_bytes(base64.b64encode(OTHER_TEST_SEED) + b"\n")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.publish(2)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.args.release_dir.iterdir() if path.is_file()})
        self.assertFalse(any(Path(call[0]).name == "generate_keys" for call in self.calls))

    def testWidePermissionsSymlinkAndForeignOwnerAreRejectedBeforeSignerRuns(self):
        key = self.file_key(); self.info(1)
        self.args.sparkle_bin = self.bin
        key.chmod(0o644)
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "permissions"):
            publisher.publish(self.args)
        key.chmod(0o600)
        link = self.root / "key-link"; link.symlink_to(key)
        self.args.ed_key_file = link
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "symlink"):
            publisher.publish(self.args)
        self.args.ed_key_file = key
        with patch.object(publisher, "command", self.fake_command), patch.object(publisher.os, "getuid", return_value=os.getuid() + 1), self.assertRaisesRegex(ValueError, "owned"):
            publisher.publish(self.args)
        self.assertEqual(self.calls, [])
        self.assertFalse(list(self.args.release_dir.iterdir()))

    def testKeyInsideReleaseDirectoryAndMalformedInputAreRejectedWithoutDisclosure(self):
        key = self.file_key(); self.info(1)
        self.args.sparkle_bin = self.bin
        self.args.release_dir.mkdir()
        copied = self.args.release_dir / "unsafe-key"
        key.rename(copied); self.args.ed_key_file = copied
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "outside"):
            publisher.publish(self.args)
        copied.rename(key); self.args.ed_key_file = key
        key.write_bytes(b"test-only-invalid-private-key-data!")
        with patch.object(publisher, "command", self.fake_command), self.assertRaises(ValueError) as caught:
            publisher.publish(self.args)
        self.assertNotIn("test-only-invalid-private-key-data", str(caught.exception))
        self.assertEqual(self.calls, [])

    def testNonRegularOversizedAppBundledAndHardLinkedKeysFailBeforeSigning(self):
        key = self.file_key(); self.info(1)
        self.args.sparkle_bin = self.bin
        fifo = self.root / "key-pipe"; os.mkfifo(fifo, 0o600)
        self.args.ed_key_file = fifo
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "regular"):
            publisher.publish(self.args)
        self.args.ed_key_file = key
        key.write_bytes(base64.b64encode(TEST_SEED) + b" " * 1_025)
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "format"):
            publisher.publish(self.args)
        key.write_bytes(base64.b64encode(TEST_SEED) + b"\n")
        bundled = self.app / "Contents/private-signing-key"
        key.rename(bundled); self.args.ed_key_file = bundled
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "outside"):
            publisher.publish(self.args)
        bundled.rename(key); self.args.ed_key_file = key
        os.link(key, self.root / "hard-linked-key")
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "hard-linked"):
            publisher.publish(self.args)
        self.assertEqual(self.calls, [])
        self.assertFalse(list(self.args.release_dir.iterdir()))

    def testSigningIdentityMustBeExplicit(self):
        parser = publisher.argument_parser()
        required = ["--app", str(self.app), "--release-dir", str(self.args.release_dir), "--sparkle-bin", str(self.bin), "--schema", "1", "--update-root", "https://updates.example.com/"]
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(required)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(required + ["--ed-key-file", str(self.root / "key"), "--key-account", "test-only"])
        self.args.key_account = None
        self.args.ed_key_file = None
        self.info(1)
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "Choose --ed-key-file"):
            publisher.publish(self.args)

    def testLegacyFeedCannotBePublishedIntoNewTrustChannel(self):
        self.info(1)
        path = self.app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["SUFeedURL"] = "https://other.example.invalid/updates/appcast.xml"
        path.write_bytes(plistlib.dumps(info))
        with patch.object(publisher, "command", self.fake_command), self.assertRaisesRegex(ValueError, "production HTTPS feed"):
            publisher.publish(self.args)
        self.assertEqual(self.calls, [])

    def testConfidentialSubprocessFailuresNeverExposeToolOutput(self):
        failure = subprocess.CalledProcessError(1, ["sign_update"], output="test-only-key-material", stderr="test-only-key-material")
        with patch.object(publisher.subprocess, "check_output", side_effect=failure):
            with self.assertRaises(ValueError) as caught:
                publisher.command(["sign_update", "--ed-key-file", "-"], input="test-only-key-material", confidential=True)
        self.assertNotIn("test-only-key-material", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
