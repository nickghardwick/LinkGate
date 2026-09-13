from __future__ import annotations

import base64
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.release.publish_beta.appcast import AppcastFeed, AppcastItem, parse_appcast, serialize_appcast
from scripts.release.publish_beta.config import load_config
from scripts.release.publish_beta.content import merge_appcast, prepare_publication_content
from scripts.release.publish_beta.errors import PublicationError
from scripts.release.publish_beta.models import AssetFact, PublicationRecord
from scripts.release.publish_beta.pages import LocalPagesGit, stage_pages
from scripts.release.publish_beta.preflight import CommandResult, SubprocessRunner
from scripts.release.publish_beta.sparkle import (
    SignUpdateAdapter,
    SparkleSignature,
    SparkleSignatureVerifier,
    parse_sign_update_output,
)
from scripts.release.publish_beta.step6 import Step6Artifacts, Step6Manifest


PUBLIC_KEY = "A" * 43 + "="
COMMIT = "a" * 40
SPARKLE_INTEROP_ARTIFACT = b"LinkGate Sparkle 2.9.6 interoperability fixture\n"
SPARKLE_INTEROP_PUBLIC_KEY = "ilzG6yMvd8qfr6pk2O9wV5GT/BjOFfQ5e5+2bJNpoK4="
SPARKLE_INTEROP_SIGNATURE = "FMrvQWb5U+/x/Pb9X9kji6h3b1NJwtfyGB0vljF7XQi/j7M/3Bmmfzf8cOE+lHdjhU7oS3z67qA2MylLL7x6Dg=="


def config_value() -> dict:
    return {
        "schema_version": 1,
        "repository": "example/linkgate",
        "product": "LinkGate",
        "bundle_id": "com.nickghardwick.LinkGate",
        "team_id": "Z8A8ZWCZ45",
        "appcast_path": "/updates/appcast.xml",
        "release_notes_source_pattern": "release-notes/{version}.md",
        "release_notes_url_pattern": "https://{owner}.github.io/{repo}/updates/releases/{version}.html",
        "appcast_url_pattern": "https://{owner}.github.io/{repo}/updates/appcast.xml",
        "github_release": {"tag_pattern": "v{version}", "title_pattern": "LinkGate {version}", "prerelease": True},
        "sparkle": {
            "version": "2.9.6", "public_key": PUBLIC_KEY,
            "distribution": {"archive_name": "Sparkle-2.9.6.tar.xz", "archive_url": "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz", "archive_sha256": "a" * 64, "sign_update_path": "bin/sign_update", "sign_update_sha256": "b" * 64},
        },
        "verification": {"attempts": 2, "interval_seconds": 0},
        "minimum_macos_version": "14.0",
        "pages": {"branch": "gh-pages", "commit_author_name": "LinkGate", "commit_author_email": "linkgate@users.noreply.github.com"},
    }


def item(version: str, build: str) -> AppcastItem:
    return AppcastItem(
        title=f"LinkGate {version}", product_url="https://github.com/example/linkgate",
        marketing_version=version, build_version=build, minimum_system_version="14.0",
        release_notes_url=f"https://example.github.io/linkgate/updates/releases/{version}.html",
        enclosure_url=f"https://github.com/example/linkgate/releases/download/v{version}/LinkGate-{version}.dmg",
        enclosure_length=12, ed_signature="A" * 88 + "==",
        publication_recorded_at=datetime(2026, 9, 12, 12, 30, tzinfo=timezone.utc),
    )


class FakeSigner:
    def __init__(self, signature: SparkleSignature) -> None:
        self.signature = signature
        self.paths: list[Path] = []

    def sign(self, path: Path) -> SparkleSignature:
        self.paths.append(path)
        return self.signature


class FakeVerifier:
    def __init__(self) -> None:
        self.calls: list[tuple[Path, SparkleSignature, str]] = []

    def verify(self, archive: Path, signature: SparkleSignature, public_key: str) -> None:
        self.calls.append((archive, signature, public_key))


class ContentTests(unittest.TestCase):
    def test_signer_and_verifier_receive_exact_immutable_dmg(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "LinkGate-0.1.4.dmg"
            dmg.write_bytes(b"canonical dmg")
            notes = root / "0.1.4.md"
            notes.write_text("# Changes\n\n- Better links\n", encoding="utf-8")
            dmg_hash = hashlib.sha256(dmg.read_bytes()).hexdigest()
            manifest = Step6Manifest("LinkGate", "0.1.4", "6", "com.nickghardwick.LinkGate", COMMIT, ("arm64", "x86_64"), "14.0", "Developer ID Application: LinkGate (Z8A8ZWCZ45)", True, True, "Xcode", "macOS", dmg.name, dmg_hash, len(dmg.read_bytes()))
            artifacts = Step6Artifacts(manifest, root / "manifest.json", dmg, root / "checksum")
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config_value()), encoding="utf-8")
            config = load_config(config_path)
            record = PublicationRecord("LinkGate", "0.1.4", "6", COMMIT, "v0.1.4", "example/linkgate", "LinkGate 0.1.4", True, (AssetFact(dmg.name, len(dmg.read_bytes()), dmg_hash),), "c" * 64, config.appcast_url(), "2026-09-12T12:30:00Z")
            signer = FakeSigner(SparkleSignature("A" * 88 + "==", len(dmg.read_bytes())))
            verifier = FakeVerifier()
            before = dmg.read_bytes()
            content = prepare_publication_content(config, record, artifacts, notes, signer, verifier, None)

            self.assertEqual(signer.paths, [dmg])
            self.assertEqual(verifier.calls[0][2], PUBLIC_KEY)
            self.assertEqual(dmg.read_bytes(), before)
            self.assertIn(b"LinkGate 0.1.4", content.release_notes_html)
            feed = parse_appcast(content.appcast_xml)
            self.assertEqual(feed.items[0].build_version, "6")
            self.assertEqual(feed.items[0].enclosure_url, "https://github.com/example/linkgate/releases/download/v0.1.4/LinkGate-0.1.4.dmg")
            self.assertEqual(feed.items[0].enclosure_length, len(before))
            self.assertEqual(feed.items[0].pub_date, "Sat, 12 Sep 2026 12:30:00 GMT")

    def test_merge_preserves_history_and_rejects_backward_candidate(self) -> None:
        config_path = Path(tempfile.mkdtemp()) / "config.json"
        config_path.write_text(json.dumps(config_value()), encoding="utf-8")
        config = load_config(config_path)
        existing = serialize_appcast(AppcastFeed("Beta", "https://github.com/example/linkgate", "Updates", (item("0.1.3", "5"),)))
        merged = parse_appcast(merge_appcast(config, existing, item("0.1.4", "6")))
        self.assertEqual([entry.build_version for entry in merged.items], ["6", "5"])
        with self.assertRaises(PublicationError):
            merge_appcast(config, existing, item("0.1.2", "4"))


class SparkleOutputTests(unittest.TestCase):
    def test_parses_official_archive_output_and_rejects_wrong_length(self) -> None:
        signature = "A" * 86 + "=="
        parsed = parse_sign_update_output(f'sparkle:edSignature="{signature}" length="12"\n', 12)
        self.assertEqual(parsed.length, 12)
        with self.assertRaises(PublicationError):
            parse_sign_update_output(f'sparkle:edSignature="{signature}" length="11"\n', 12)

    def test_signer_uses_archive_path_without_private_key_or_version_probe(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append(tuple(args))
                return CommandResult(0, 'sparkle:edSignature="' + ("A" * 86 + "==") + '" length="12"\n', "")

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"0123456789ab")
            runner = Runner()
            result = SignUpdateAdapter(runner, "/sparkle/bin/sign_update").sign(archive)
            self.assertEqual(result.length, 12)
            self.assertEqual(runner.calls, [("/sparkle/bin/sign_update", "--account", "ed25519", str(archive))])
            self.assertNotIn("--version", runner.calls[0])
            self.assertNotIn("--ed-key-file", runner.calls[0])

    def test_verifier_runs_sparkle_and_configured_public_key_checks(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append(tuple(args))
                return CommandResult(0, "", "")

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"0123456789ab")
            runner = Runner()
            signature = SparkleSignature("A" * 86 + "==", 12)
            SparkleSignatureVerifier(runner, "/sparkle/bin/sign_update", "/usr/bin/openssl").verify(archive, signature, PUBLIC_KEY)
            self.assertEqual(len(runner.calls), 2)
            self.assertIn("--verify", runner.calls[0])
            self.assertEqual(runner.calls[0][0], "/sparkle/bin/sign_update")
            self.assertEqual(runner.calls[1][0], "/usr/bin/openssl")
            self.assertNotIn("--ed-key-file", runner.calls[0])

    def test_malformed_signer_output_is_rejected(self) -> None:
        with self.assertRaises(PublicationError):
            parse_sign_update_output("not an XML fragment\n", 12)

    def test_signer_rejects_an_archive_changed_by_the_tool(self) -> None:
        class Runner:
            def run(self, args, cwd=None):
                Path(args[-1]).write_bytes(b"changed")
                return CommandResult(0, 'sparkle:edSignature="' + ("A" * 86 + "==") + '" length="12"\n', "")

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"0123456789ab")
            with self.assertRaises(PublicationError):
                SignUpdateAdapter(Runner(), "/sparkle/bin/sign_update").sign(archive)

    def test_verifier_failure_is_reported_without_private_key_arguments(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append(tuple(args))
                return CommandResult(1, "", "verification failed")

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"0123456789ab")
            runner = Runner()
            with self.assertRaises(PublicationError):
                SparkleSignatureVerifier(runner, "/sparkle/bin/sign_update", "/usr/bin/openssl").verify(archive, SparkleSignature("A" * 86 + "==", 12), PUBLIC_KEY)
            self.assertEqual(len(runner.calls), 1)
            self.assertNotIn("--ed-key-file", runner.calls[0])

    def test_configured_public_key_failure_is_reported_after_sparkle_check(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append(tuple(args))
                return CommandResult(0 if len(self.calls) == 1 else 1, "", "public key mismatch")

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"0123456789ab")
            with self.assertRaises(PublicationError):
                SparkleSignatureVerifier(Runner(), "/sparkle/bin/sign_update", "/usr/bin/openssl").verify(archive, SparkleSignature("A" * 86 + "==", 12), PUBLIC_KEY)

    def test_official_sparkle_fixture_verifies_through_real_openssl_conversion(self) -> None:
        class SparklePassThroughRunner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append(tuple(args))
                if args[0] == "/fake/sparkle/bin/sign_update":
                    return CommandResult(0, "", "")
                return SubprocessRunner().run(args, cwd)

        openssl = shutil.which("openssl")
        self.assertIsNotNone(openssl)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "sparkle-verification-fixture.bin"
            archive.write_bytes(SPARKLE_INTEROP_ARTIFACT)
            verifier = SparkleSignatureVerifier(
                SparklePassThroughRunner(),
                "/fake/sparkle/bin/sign_update",
                openssl,
            )
            signature = SparkleSignature(SPARKLE_INTEROP_SIGNATURE, len(SPARKLE_INTEROP_ARTIFACT))
            verifier.verify(archive, signature, SPARKLE_INTEROP_PUBLIC_KEY)

            tampered_archive = root / "tampered.bin"
            tampered = bytearray(SPARKLE_INTEROP_ARTIFACT)
            tampered[0] ^= 1
            tampered_archive.write_bytes(tampered)
            with self.assertRaises(PublicationError):
                verifier.verify(tampered_archive, signature, SPARKLE_INTEROP_PUBLIC_KEY)

            tampered_signature = bytearray(base64.b64decode(SPARKLE_INTEROP_SIGNATURE))
            tampered_signature[0] ^= 1
            with self.assertRaises(PublicationError):
                verifier.verify(
                    archive,
                    SparkleSignature(base64.b64encode(tampered_signature).decode(), len(SPARKLE_INTEROP_ARTIFACT)),
                    SPARKLE_INTEROP_PUBLIC_KEY,
                )

            wrong_key = bytearray(base64.b64decode(SPARKLE_INTEROP_PUBLIC_KEY))
            wrong_key[0] ^= 1
            with self.assertRaises(PublicationError):
                verifier.verify(
                    archive,
                    signature,
                    base64.b64encode(wrong_key).decode(),
                )

    def test_public_key_is_rejected_before_any_verifier_command(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append(tuple(args))
                return CommandResult(0, "", "")

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"0123456789ab")
            runner = Runner()
            verifier = SparkleSignatureVerifier(runner, "/sparkle/bin/sign_update", "/usr/bin/openssl")
            signature = SparkleSignature("A" * 86 + "==", 12)
            for public_key in ("not-base64", base64.b64encode(b"short").decode()):
                with self.assertRaises(PublicationError):
                    verifier.verify(archive, signature, public_key)
            self.assertEqual(runner.calls, [])


class PagesTests(unittest.TestCase):
    def write_config(self, root: Path):
        path = root / "config.json"
        path.write_text(json.dumps(config_value()), encoding="utf-8")
        return load_config(path)

    def test_bootstrap_is_zero_parent_and_has_exact_two_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.write_config(root)
            appcast = serialize_appcast(AppcastFeed("Beta", "https://github.com/example/linkgate", "Updates", (item("0.1.4", "6"),)))
            workspace = stage_pages(config, appcast, b"<html />\n", "0.1.4", "6", "2026-09-12T12:30:00Z", None, LocalPagesGit(SubprocessRunner(), str(root / "unused")))
            try:
                parents = subprocess.run(["git", "rev-list", "--parents", "-n", "1", "HEAD"], cwd=workspace.workspace, text=True, capture_output=True, check=True).stdout.split()
                self.assertEqual(len(parents), 1)
                self.assertEqual(sorted(str(path.relative_to(workspace.workspace)) for path in workspace.workspace.rglob("*") if path.is_file() and ".git" not in path.parts), ["updates/appcast.xml", "updates/releases/0.1.4.html"])
            finally:
                shutil.rmtree(workspace.workspace)

    def test_existing_pages_requires_expected_tip_and_preserves_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote"
            remote.mkdir()
            subprocess.run(["git", "init", "--initial-branch", "gh-pages"], cwd=remote, check=True, capture_output=True)
            (remote / "updates/releases").mkdir(parents=True)
            (remote / "updates/appcast.xml").write_bytes(b"old")
            (remote / "updates/releases/0.1.3.html").write_bytes(b"old notes")
            subprocess.run(["git", "add", "."], cwd=remote, check=True, capture_output=True)
            subprocess.run(["git", "-c", "user.name=LinkGate", "-c", "user.email=linkgate@users.noreply.github.com", "commit", "-m", "old"], cwd=remote, check=True, capture_output=True)
            tip = subprocess.run(["git", "rev-parse", "HEAD"], cwd=remote, text=True, capture_output=True, check=True).stdout.strip()
            config = self.write_config(root)
            appcast = serialize_appcast(AppcastFeed("Beta", "https://github.com/example/linkgate", "Updates", (item("0.1.4", "6"),)))
            workspace = stage_pages(config, appcast, b"new notes", "0.1.4", "6", "2026-09-12T12:30:00Z", tip, LocalPagesGit(SubprocessRunner(), str(remote)))
            try:
                changed = subprocess.run(["git", "diff-tree", "--no-commit-id", "--name-status", "-r", "HEAD"], cwd=workspace.workspace, text=True, capture_output=True, check=True).stdout.splitlines()
                self.assertEqual(sorted(changed), ["A\tupdates/releases/0.1.4.html", "M\tupdates/appcast.xml"])
                self.assertEqual(subprocess.run(["git", "show", "HEAD:updates/releases/0.1.3.html"], cwd=workspace.workspace, text=True, capture_output=True, check=True).stdout, "old notes")
            finally:
                shutil.rmtree(workspace.workspace)

    def test_existing_bootstrap_pages_without_appcast_stages_first_feed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote"
            remote.mkdir()
            subprocess.run(["git", "init", "--initial-branch", "gh-pages"], cwd=remote, check=True, capture_output=True)
            subprocess.run(["git", "-c", "user.name=LinkGate", "-c", "user.email=linkgate@users.noreply.github.com", "commit", "--allow-empty", "-m", "Bootstrap GitHub Pages"], cwd=remote, check=True, capture_output=True)
            tip = subprocess.run(["git", "rev-parse", "HEAD"], cwd=remote, text=True, capture_output=True, check=True).stdout.strip()
            config = self.write_config(root)
            appcast = serialize_appcast(AppcastFeed("Beta", "https://github.com/example/linkgate", "Updates", (item("0.1.4", "6"),)))
            workspace = stage_pages(
                config, appcast, b"new notes", "0.1.4", "6", "2026-09-12T12:30:00Z", tip,
                LocalPagesGit(SubprocessRunner(), str(remote)), existing_feed=False,
            )
            try:
                changed = subprocess.run(["git", "diff-tree", "--no-commit-id", "--name-status", "-r", "HEAD"], cwd=workspace.workspace, text=True, capture_output=True, check=True).stdout.splitlines()
                self.assertEqual(sorted(changed), ["A\tupdates/appcast.xml", "A\tupdates/releases/0.1.4.html"])
                self.assertEqual(subprocess.run(["git", "rev-list", "--parents", "-n", "1", "HEAD^"], cwd=workspace.workspace, text=True, capture_output=True, check=True).stdout.strip(), tip)
            finally:
                shutil.rmtree(workspace.workspace)

    def test_bootstrap_infrastructure_file_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote"
            remote.mkdir()
            subprocess.run(["git", "init", "--initial-branch", "gh-pages"], cwd=remote, check=True, capture_output=True)
            (remote / ".nojekyll").write_text("", encoding="utf-8")
            subprocess.run(["git", "add", ".nojekyll"], cwd=remote, check=True, capture_output=True)
            subprocess.run(["git", "-c", "user.name=LinkGate", "-c", "user.email=linkgate@users.noreply.github.com", "commit", "-m", "Bootstrap GitHub Pages"], cwd=remote, check=True, capture_output=True)
            tip = subprocess.run(["git", "rev-parse", "HEAD"], cwd=remote, text=True, capture_output=True, check=True).stdout.strip()
            config = self.write_config(root)
            appcast = serialize_appcast(AppcastFeed("Beta", "https://github.com/example/linkgate", "Updates", (item("0.1.4", "6"),)))
            workspace = stage_pages(
                config, appcast, b"new notes", "0.1.4", "6", "2026-09-12T12:30:00Z", tip,
                LocalPagesGit(SubprocessRunner(), str(remote)), existing_feed=False,
            )
            try:
                self.assertTrue((workspace.workspace / ".nojekyll").is_file())
                self.assertEqual((workspace.workspace / ".nojekyll").read_bytes(), b"")
            finally:
                shutil.rmtree(workspace.workspace)

    def test_existing_release_note_path_is_never_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote"
            remote.mkdir()
            subprocess.run(["git", "init", "--initial-branch", "gh-pages"], cwd=remote, check=True, capture_output=True)
            (remote / "updates/releases").mkdir(parents=True)
            (remote / "updates/appcast.xml").write_bytes(b"old")
            (remote / "updates/releases/0.1.4.html").write_bytes(b"old notes")
            subprocess.run(["git", "add", "."], cwd=remote, check=True, capture_output=True)
            subprocess.run(["git", "-c", "user.name=LinkGate", "-c", "user.email=linkgate@users.noreply.github.com", "commit", "-m", "old"], cwd=remote, check=True, capture_output=True)
            tip = subprocess.run(["git", "rev-parse", "HEAD"], cwd=remote, text=True, capture_output=True, check=True).stdout.strip()
            config = self.write_config(root)
            appcast = serialize_appcast(AppcastFeed("Beta", "https://github.com/example/linkgate", "Updates", (item("0.1.4", "6"),)))
            with self.assertRaises(PublicationError):
                stage_pages(config, appcast, b"new notes", "0.1.4", "6", "2026-09-12T12:30:00Z", tip, LocalPagesGit(SubprocessRunner(), str(remote)))


if __name__ == "__main__":
    unittest.main()
