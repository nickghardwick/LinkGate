#!/usr/bin/env python3

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.release.publish_beta.appcast import (
    SPARKLE_NAMESPACE,
    AppcastFeed,
    AppcastItem,
    parse_appcast,
    serialize_appcast,
)
from scripts.release.publish_beta.config import load_config
from scripts.release.publish_beta.errors import FailureClass, PublicationError
from scripts.release.publish_beta.models import (
    AssetFact,
    PublicationRecord,
    ReleaseIdentity,
    parse_marketing_version,
)
from scripts.release.publish_beta.release_notes import (
    DEFAULT_HTML_TEMPLATE,
    render_release_notes,
    release_notes_source_path,
)


PUBLIC_KEY = "A" * 43 + "="


def valid_config() -> dict:
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
        "github_release": {
            "tag_pattern": "v{version}",
            "title_pattern": "LinkGate {version}",
            "prerelease": True,
        },
        "sparkle": {
            "version": "2.9.6",
            "keychain_account": "LinkGate",
            "public_key": PUBLIC_KEY,
            "distribution": {
                "archive_name": "Sparkle-2.9.6.tar.xz",
                "archive_url": "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz",
                "archive_sha256": "a" * 64,
                "sign_update_path": "bin/sign_update",
                "sign_update_sha256": "b" * 64,
            },
        },
        "verification": {"attempts": 18, "interval_seconds": 10},
        "minimum_macos_version": "14.0",
        "pages": {"branch": "gh-pages", "commit_author_name": "LinkGate", "commit_author_email": "linkgate@users.noreply.github.com"},
    }


def valid_item(version: str = "0.1.3", build: str = "5") -> AppcastItem:
    return AppcastItem(
        title=f"LinkGate {version}",
        product_url="https://example.com/linkgate",
        marketing_version=version,
        build_version=build,
        minimum_system_version="14.0",
        release_notes_url=f"https://example.github.io/linkgate/updates/releases/{version}.html",
        enclosure_url=f"https://github.com/example/linkgate/releases/download/v{version}/LinkGate-{version}.dmg",
        enclosure_length=1234,
        ed_signature="signature-for-tests",
        publication_recorded_at=datetime(2026, 9, 12, 12, 30, tzinfo=timezone.utc),
    )


class ConfigTests(unittest.TestCase):
    def write_config(self, value: dict) -> Path:
        directory = Path(self.tmpdir.name)
        path = directory / "publish-config.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def test_loads_valid_config_and_expands_versioned_paths(self) -> None:
        config = load_config(self.write_config(valid_config()))

        self.assertEqual(config.repository, "example/linkgate")
        self.assertEqual(config.sparkle_version, "2.9.6")
        self.assertEqual(config.sparkle_keychain_account, "LinkGate")
        self.assertEqual(config.release_notes_url("0.1.3"), "https://example.github.io/linkgate/updates/releases/0.1.3.html")
        self.assertEqual(config.appcast_url(), "https://example.github.io/linkgate/updates/appcast.xml")

    def test_rejects_unconfigured_repository_and_public_key(self) -> None:
        value = valid_config()
        value["repository"] = "OWNER/REPO"
        value["sparkle"]["public_key"] = "REPLACE_AFTER_ONE_TIME_KEY_SETUP"

        with self.assertRaises(PublicationError) as raised:
            load_config(self.write_config(value))

        self.assertEqual(raised.exception.failure_class, FailureClass.CONFIGURATION)

    def test_rejects_wrong_sparkle_version(self) -> None:
        value = valid_config()
        value["sparkle"]["version"] = "2.8.1"

        with self.assertRaises(PublicationError):
            load_config(self.write_config(value))

    def test_rejects_unresolved_sparkle_keychain_account(self) -> None:
        value = valid_config()
        value["sparkle"]["keychain_account"] = "REPLACE_AFTER_ONE_TIME_ACCOUNT_SETUP"

        with self.assertRaises(PublicationError):
            load_config(self.write_config(value))

    def test_rejects_unpinned_sparkle_distribution_provenance(self) -> None:
        value = valid_config()
        value["sparkle"]["distribution"]["archive_url"] = "https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz"

        with self.assertRaises(PublicationError):
            load_config(self.write_config(value))

    def test_committed_config_contains_configured_public_repository_and_key(self) -> None:
        config_path = Path(__file__).resolve().parents[1] / "publish-config.json"

        config = load_config(config_path)

        self.assertEqual(config.repository, "nickghardwick/LinkGate")
        self.assertEqual(config.sparkle_keychain_account, "LinkGate")
        self.assertEqual(config.sparkle_public_key, "En8Ohgkw8WSkc/10bYvg692dCDZUeb+w30bCOqR+qkU=")

    def test_release_notes_source_path_is_version_specific(self) -> None:
        config = load_config(self.write_config(valid_config()))

        self.assertEqual(
            release_notes_source_path(Path("/repo"), config, "0.1.4"),
            Path("/repo/release-notes/0.1.4.md"),
        )
        self.assertEqual(config.release_tag("0.1.4"), "v0.1.4")
        self.assertEqual(config.release_title("0.1.4"), "LinkGate 0.1.4")


class ModelTests(unittest.TestCase):
    def test_marketing_version_requires_three_numeric_components(self) -> None:
        self.assertEqual(parse_marketing_version("0.1.3"), (0, 1, 3))

        with self.assertRaises(PublicationError):
            parse_marketing_version("0.1")

    def test_release_identity_exposes_numeric_build(self) -> None:
        identity = ReleaseIdentity("LinkGate", "0.1.4", "6", "com.example.LinkGate", "14.0")

        self.assertEqual(identity.build_number, 6)

    def test_publication_record_serializes_without_recursive_or_secret_fields(self) -> None:
        record = PublicationRecord(
            product="LinkGate",
            marketing_version="0.1.4",
            build="6",
            source_commit="a" * 40,
            release_tag="v0.1.4",
            github_repository="example/linkgate",
            github_title="LinkGate 0.1.4",
            prerelease=True,
            assets=(AssetFact("LinkGate-0.1.4.dmg", 12, "b" * 64),),
            release_manifest_sha256="c" * 64,
            appcast_url="https://example.github.io/linkgate/updates/appcast.xml",
            publication_recorded_at="2026-09-12T12:30:00Z",
        )

        encoded = record.to_json_bytes()
        decoded = json.loads(encoded)
        self.assertEqual(decoded["build"], "6")
        self.assertNotIn("private_key", decoded)
        self.assertNotIn("self_sha256", decoded)
        self.assertNotIn("github_asset_id", decoded)


class ReleaseNoteTests(unittest.TestCase):
    def test_common_markdown_renders_deterministically(self) -> None:
        source = b"# Changes\n\n- **Fast** updates\n- [Project](https://example.com)\n\n`code`\n"

        first = render_release_notes(source, version="0.1.4")
        second = render_release_notes(source, version="0.1.4")

        self.assertEqual(first.html_bytes, second.html_bytes)
        self.assertIn(b"<h1>Changes</h1>", first.html_bytes)
        self.assertIn(b"<strong>Fast</strong>", first.html_bytes)
        self.assertIn(b"<code>code</code>", first.html_bytes)

    def test_raw_html_is_rendered_inert(self) -> None:
        rendered = render_release_notes(b"<script>alert('x')</script>\n", version="0.1.4")

        self.assertNotIn(b"<script>", rendered.html_bytes)
        self.assertIn(b"&lt;script&gt;", rendered.html_bytes)

    def test_template_has_no_external_runtime_dependencies(self) -> None:
        rendered = render_release_notes(b"plain text", version="0.1.4")

        self.assertEqual(rendered.template, DEFAULT_HTML_TEMPLATE)
        self.assertNotIn(b"<script", rendered.html_bytes.lower())
        self.assertNotIn(b"<link", rendered.html_bytes.lower())
        self.assertNotIn(b"http://", rendered.html_bytes)
        self.assertNotIn(b"https://", rendered.html_bytes)


class AppcastTests(unittest.TestCase):
    def test_serializes_and_parses_structured_sparkle_xml(self) -> None:
        feed = AppcastFeed(
            channel_title="LinkGate Beta",
            channel_link="https://example.com/linkgate",
            channel_description="LinkGate beta updates",
            items=(valid_item(),),
        )

        encoded = serialize_appcast(feed)
        parsed = parse_appcast(encoded)

        self.assertEqual(encoded, serialize_appcast(parsed))
        self.assertIn(f'xmlns:sparkle="{SPARKLE_NAMESPACE}"'.encode(), encoded)
        self.assertIn(b"<sparkle:version>5</sparkle:version>", encoded)
        self.assertIn(b'sparkle:edSignature="signature-for-tests"', encoded)

    def test_rejects_duplicate_versions_and_non_monotonic_builds(self) -> None:
        duplicate = AppcastFeed("Beta", "https://example.com", "Updates", (valid_item(), valid_item()))
        with self.assertRaises(PublicationError):
            serialize_appcast(duplicate)

        non_monotonic = AppcastFeed("Beta", "https://example.com", "Updates", (valid_item("0.1.3", "5"), valid_item("0.1.2", "6")))
        with self.assertRaises(PublicationError):
            serialize_appcast(non_monotonic)

    def test_rejects_missing_sparkle_signature(self) -> None:
        encoded = serialize_appcast(AppcastFeed("Beta", "https://example.com", "Updates", (valid_item(),)))
        encoded = encoded.replace(b'sparkle:edSignature="signature-for-tests"', b'')

        with self.assertRaises(PublicationError):
            parse_appcast(encoded)

    def test_rejects_appcast_without_sparkle_namespace(self) -> None:
        encoded = serialize_appcast(AppcastFeed("Beta", "https://example.com", "Updates", (valid_item(),)))
        encoded = encoded.replace(f' xmlns:sparkle="{SPARKLE_NAMESPACE}"'.encode(), b"")

        with self.assertRaises(PublicationError):
            parse_appcast(encoded)

    def test_rejects_non_https_update_urls(self) -> None:
        item = valid_item()
        with self.assertRaises(PublicationError):
            AppcastItem(
                **{**item.__dict__, "enclosure_url": "http://example.com/update.dmg"}
            )


if __name__ == "__main__":
    unittest.main()
