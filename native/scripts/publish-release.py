#!/usr/bin/env python3
"""Prepare a signed, local Hero OOS release directory; never uploads or uses SSH.

Use official Sparkle 2.10.0 tools with an explicitly chosen signing file or
Keychain account. File keys stay outside the release directory and are sent to the
signer over standard input, never command arguments, generated files or logs.
Upload archives first, then the three indexes atomically on the HTTPS server.
Only the ten newest previously indexed, immutable build archives are retained.
"""
import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

ROOT_URL = "https://cloud.example.invalid/updates/v3/"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ARCHIVE_NAME = re.compile(r"Hero-OOS-build-([1-9][0-9]*)-(arm64|x86_64|universal)\.zip\Z")
MAX_BYTES = 256 * 1024 * 1024

# The verifier receives only public information: expected public key, a random
# challenge, and its signature. It never receives a private key or touches Keychain.
VERIFY_PROOF_SWIFT = r'''
import Foundation
import CryptoKit
let data = FileHandle.standardInput.readDataToEndOfFile()
do {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let publicText = object["publicKey"], let publicData = Data(base64Encoded: publicText),
          let signatureText = object["signature"], let signature = Data(base64Encoded: signatureText),
          let challengeText = object["challenge"], let challenge = Data(base64Encoded: challengeText) else { exit(2) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    guard key.isValidSignature(signature, for: challenge) else { exit(2) }
} catch { exit(2) }
'''


def command(arguments, *, input=None, confidential=False):
    try:
        return subprocess.check_output([str(part) for part in arguments], text=True, input=input,
                                       stderr=subprocess.PIPE if confidential else None).strip()
    except subprocess.CalledProcessError:
        if confidential:
            # Sparkle's malformed-key error path can echo the input. Neither
            # stdout nor stderr from a private-key operation may reach a log.
            raise ValueError("Signing tool failed; private-key diagnostics suppressed") from None
        raise


def verify_key_proof(public_key, signature, challenge, cache):
    payload = json.dumps({"publicKey": public_key, "signature": signature,
                          "challenge": base64.b64encode(challenge).decode()})
    try:
        command(["/usr/bin/swift", "-module-cache-path", cache, "-e", VERIFY_PROOF_SWIFT],
                input=payload, confidential=True)
    except ValueError:
        raise ValueError("Signing file does not match the app's embedded public key, or proof verification failed") from None


class SigningIdentity:
    """One immutable in-memory signing input for the entire publication."""
    def __init__(self, signer, key_lookup, public_key, directory, *, account=None, key_file=None, app=None):
        self.signer = signer
        if key_file is None and account is None:
            raise ValueError("Choose --ed-key-file or --key-account explicitly")
        self.options = ["--account", account] if account is not None else []
        self._input = None
        try:
            if key_file is not None:
                if account is not None:
                    raise ValueError("--ed-key-file and --key-account are mutually exclusive")
                key_file = key_file.expanduser().absolute()
                # Keep secrets out of both indexed releases and their stage dirs.
                if not key_file.exists() and not key_file.is_symlink():
                    raise ValueError("Signing file is missing; restore the original signing file. No Keychain fallback or key generation was attempted")
                canonical = key_file.resolve(strict=True)
                if canonical == directory or directory in canonical.parents or (app is not None and app in canonical.parents):
                    raise ValueError("Private key must be outside the app bundle and release directory")
                if key_file.is_symlink():
                    raise ValueError("Private key may not be a symlink")
                if not stat.S_ISREG(key_file.lstat().st_mode):
                    raise ValueError("Private key must be a regular file")
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
                descriptor = os.open(key_file, flags)
                try:
                    metadata = os.fstat(descriptor)
                    if not stat.S_ISREG(metadata.st_mode):
                        raise ValueError("Private key must be a regular file")
                    if metadata.st_uid != os.getuid():
                        raise ValueError("Private key must be owned by the current local user")
                    if metadata.st_nlink != 1:
                        raise ValueError("Private key may not have hard-linked copies")
                    if stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
                        raise ValueError("Private key permissions must restrict access to its owner (0400 or 0600)")
                    if not 0 < metadata.st_size <= 1_024:
                        raise ValueError("Private key format is invalid")
                    with os.fdopen(descriptor, "rb", closefd=False) as source:
                        encoded = source.read(1_025).strip()
                    if not encoded or len(encoded) > 1_024:
                        raise ValueError("Private key format is invalid")
                    try:
                        raw = base64.b64decode(encoded, validate=True)
                    except ValueError:
                        raise ValueError("Private key format is invalid") from None
                    if len(raw) not in (32, 96):
                        raise ValueError("Private key must use Sparkle's 32-byte seed or 96-byte legacy format")
                finally:
                    os.close(descriptor)
                self._input = encoded.decode("ascii") + "\n"
                self.options = ["--ed-key-file", "-"]
                # Prove the actual signing key matches Info.plist without asking
                # generate_keys to read the old Keychain, even in lookup mode.
                with tempfile.TemporaryDirectory(prefix="hero-oos-signing-proof-") as temp:
                    challenge = os.urandom(64)
                    fixture = Path(temp) / "proof.bin"
                    fixture.write_bytes(challenge)
                    signature = self.run(["-p", fixture])
                    verify_key_proof(public_key, signature, challenge, Path(temp) / "modules")
            elif command([key_lookup, *self.options, "-p"]) != public_key:
                raise ValueError("Signing Keychain account does not match the app's embedded public key")
        except BaseException:
            self._input = None
            raise

    def run(self, arguments):
        if self._input is None:
            return command([self.signer, *self.options, *arguments])
        return command([self.signer, *self.options, *arguments], input=self._input, confidential=True)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self._input = None


def signing(identity, path):
    signature = identity.run(["-p", path])
    if path.suffix != ".xml":
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Official sign_update returned an invalid signature")
        identity.run(["--verify", path, signature])
    else:
        identity.run(["--verify", path])
    return signature


def managed_archive(directory, entry):
    url = urllib.parse.urlparse(entry["url"])
    filename = urllib.parse.unquote(Path(url.path).name)
    match = ARCHIVE_NAME.fullmatch(filename)
    if (not match or entry["url"] != ROOT_URL + filename or
            int(match.group(1)) != entry["build"] or match.group(2) != entry["architecture"]):
        raise ValueError("Index references an unmanaged archive")
    path = directory / filename
    if path.is_symlink() or not path.is_file() or path.parent.resolve() != directory:
        raise ValueError("Managed archive missing, symlinked or outside release directory")
    if path.stat().st_size != entry["byteLength"] or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise ValueError("Existing archive digest or size does not match its signed index")
    return path


def appcast(entries):
    ET.register_namespace("sparkle", NAMESPACE)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Hero OOS"
    ET.SubElement(channel, "link").text = ROOT_URL
    ET.SubElement(channel, "description").text = "Hero OOS signed releases"
    ET.SubElement(channel, "language").text = "zh-CN"
    for entry in entries:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = "Hero OOS " + entry["version"]
        ET.SubElement(item, "{%s}version" % NAMESPACE).text = str(entry["build"])
        ET.SubElement(item, "{%s}shortVersionString" % NAMESPACE).text = entry["version"]
        ET.SubElement(item, "{%s}minimumSystemVersion" % NAMESPACE).text = entry["minOS"]
        if entry["architecture"] == "arm64":
            ET.SubElement(item, "{%s}hardwareRequirements" % NAMESPACE).text = "arm64"
        attrs = {"url": entry["url"], "length": str(entry["byteLength"]), "type": "application/octet-stream",
                 "{%s}edSignature" % NAMESPACE: entry["edSignature"]}
        ET.SubElement(item, "enclosure", attrs)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def publish(args):
    directory = args.release_dir.expanduser().absolute()
    if directory.is_symlink():
        raise ValueError("Release directory may not be a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    directory = directory.resolve()
    if directory in [Path("/"), Path.home(), Path.cwd().resolve()]:
        raise ValueError("Use a dedicated releases directory, not a broad existing root")
    app = args.app.resolve(strict=True)
    if app.suffix != ".app":
        raise ValueError("--app must point to a built .app bundle")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.hero-oos.native":
        raise ValueError("Not a Hero OOS app bundle")
    version = info["CFBundleShortVersionString"]
    build = int(info["CFBundleVersion"])
    if build <= 0 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise ValueError("Release requires a positive numeric build and stable version")
    if info.get("SUFeedURL") != ROOT_URL + "appcast.xml":
        raise ValueError("App update source is not the production HTTPS feed")
    public_key = info.get("SUPublicEDKey", "")
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("App has no valid EdDSA update public key")
    signer = args.sparkle_bin.resolve(strict=True) / "sign_update"
    key_lookup = args.sparkle_bin.resolve(strict=True) / "generate_keys"
    with SigningIdentity(signer, key_lookup, public_key, directory,
                         account=getattr(args, "key_account", None), key_file=getattr(args, "ed_key_file", None), app=app) as identity:
        _publish_signed(args, directory, app, info, identity)


def _publish_signed(args, directory, app, info, identity):
    version, build = info["CFBundleShortVersionString"], int(info["CFBundleVersion"])
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    architectures = set(command(["/usr/bin/lipo", "-archs", app / "Contents/MacOS/HeroOOS"]).split())
    architecture = "universal" if architectures == {"arm64", "x86_64"} else next(iter(architectures)) if len(architectures) == 1 else ""
    if architecture not in ["arm64", "x86_64", "universal"]:
        raise ValueError("Unsupported executable architecture")
    if args.schema <= 0:
        raise ValueError("--schema must describe a positive app data schema version")

    # A dedicated lock prevents competing local publishers from losing releases.
    lock_path = directory / ".hero-oos-publish.lock"
    if lock_path.is_symlink():
        raise ValueError("Refusing symlinked release lock")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        indexes = [directory / name for name in ("versions.json", "versions.json.sig", "appcast.xml")]
        if any(path.is_symlink() for path in indexes):
            raise ValueError("Refusing symlinked release indexes")
        existing = []
        if indexes[0].exists():
            signature = indexes[1].read_text().strip()
            identity.run(["--verify", indexes[0], signature])
            catalog = json.loads(indexes[0].read_bytes())
            if catalog["formatVersion"] != 1 or len(catalog["versions"]) > 10:
                raise ValueError("Unsupported existing version index")
            existing = catalog["versions"]
            if len({entry["build"] for entry in existing}) != len(existing):
                raise ValueError("Duplicate builds in existing catalog")
            for entry in existing:
                managed_archive(directory, entry)
            if existing and build <= max(entry["build"] for entry in existing):
                raise ValueError("Build numbers are immutable and must increase; never overwrite a published build")
        filename = f"Hero-OOS-build-{build}-{architecture}.zip"
        target = directory / filename
        if target.exists() or target.is_symlink():
            raise ValueError("Archive already exists; use a new build number")
        with tempfile.TemporaryDirectory(prefix=".hero-oos-stage-", dir=directory) as temp:
            stage = Path(temp)
            archive = stage / filename
            command(["/usr/bin/ditto", "-c", "-k", "--noextattr", "--norsrc", "--keepParent", app, archive])
            size = archive.stat().st_size
            if not 0 < size <= MAX_BYTES:
                raise ValueError("Archive exceeds the bounded client download size")
            entry = dict(version=version, build=build, architecture=architecture,
                         minOS=info.get("LSMinimumSystemVersion", "15.0"), schema=args.schema,
                         url=ROOT_URL + filename, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                         edSignature=signing(identity, archive), byteLength=size,
                         publishedAt=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
            ordered = sorted(existing + [entry], key=lambda item: item["build"], reverse=True)
            retained, retired = ordered[:10], ordered[10:]
            manifest = stage / "versions.json"
            manifest.write_text(json.dumps({"formatVersion": 1, "versions": retained}, ensure_ascii=False, indent=2) + "\n")
            (stage / "versions.json.sig").write_text(signing(identity, manifest) + "\n")
            feed = stage / "appcast.xml"
            feed.write_bytes(appcast(retained))
            signing(identity, feed)  # Official Sparkle signs XML in place.
            os.replace(archive, target)
            for name in ("versions.json.sig", "versions.json", "appcast.xml"):
                os.replace(stage / name, directory / name)
            # Indexes no longer reference retired files. Only exact, previously
            # signed-and-indexed archive paths can be removed; never recurse/glob.
            removed = []
            for old in retired:
                old_path = managed_archive(directory, old)
                old_path.unlink()
                removed.append(old_path.name)
            print(json.dumps({"prepared": filename, "retainedBuilds": [item["build"] for item in retained],
                              "removedManagedArchives": removed, "uploaded": False}, ensure_ascii=False))


def argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--release-dir", required=True, type=Path)
    parser.add_argument("--sparkle-bin", required=True, type=Path)
    keys = parser.add_mutually_exclusive_group(required=True)
    keys.add_argument("--key-account", help="Explicit legacy Keychain account; never selected automatically")
    keys.add_argument("--ed-key-file", type=Path, help="Owner-only Sparkle key file; no Keychain fallback")
    parser.add_argument("--update-root", required=True, help="Your HTTPS update directory, ending in /")
    parser.add_argument("--schema", required=True, type=int)
    return parser


if __name__ == "__main__":
    parser = argument_parser()
    arguments = parser.parse_args()
    try:
        configured = urllib.parse.urlparse(arguments.update_root)
        if (configured.scheme != "https" or not configured.hostname or configured.username or
                configured.password or configured.query or configured.fragment or
                configured.port not in (None, 443) or not configured.path.endswith("/") or
                ".." in configured.path.split("/") or configured.hostname.endswith(".invalid")):
            raise ValueError("--update-root must be your HTTPS directory without credentials/query/fragment")
        ROOT_URL = arguments.update_root
        publish(arguments)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release not published: {error}\n")
