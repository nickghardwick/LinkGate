from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.release.publish_beta.appcast import AppcastFeed, AppcastItem, serialize_appcast
from scripts.release.publish_beta.config import load_config
from scripts.release.publish_beta.models import AssetFact, PublicationRecord
from scripts.release.publish_beta.preflight import CommandResult, HttpResponse
from scripts.release.publish_beta.release_notes import render_release_notes
from scripts.release.publish_beta.retrospective import verify_published_beta


class RetrospectiveTests(unittest.TestCase):
    def test_read_only_acceptance_verifies_public_content_and_writes_follow_up_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist").mkdir()
            (root / "release-notes").mkdir()
            dmg = b"retrospective DMG"
            dmg_name = "LinkGate-0.1.4.dmg"
            checksum_name = f"{dmg_name}.sha256"
            manifest_name = "LinkGate-0.1.4.release.json"
            notes_source = b"# Beta\n\n- Browser chooser improvements\n"
            (root / "release-notes/0.1.4.md").write_bytes(notes_source)
            manifest = {
                "product": "LinkGate", "marketing_version": "0.1.4", "build": "6",
                "bundle_id": "com.nickghardwick.LinkGate", "source_commit": "a" * 40,
                "architectures": ["arm64", "x86_64"], "deployment_target": "14.0",
                "signing_identity": "Developer ID Application: LinkGate (Z8A8ZWCZ45)",
                "notarized": True, "stapled": True, "xcode_version": "Xcode",
                "macos_version": "26.0", "artifact_name": dmg_name,
                "sha256": hashlib.sha256(dmg).hexdigest(),
            }
            (root / f"dist/{dmg_name}").write_bytes(dmg)
            (root / f"dist/{checksum_name}").write_text(
                f"{manifest['sha256']}  {dmg_name}\n", encoding="utf-8"
            )
            manifest_bytes = json.dumps(manifest).encode()
            (root / f"dist/{manifest_name}").write_bytes(manifest_bytes)

            config_value = {
                "schema_version": 1, "repository": "example/linkgate", "product": "LinkGate",
                "bundle_id": "com.nickghardwick.LinkGate", "team_id": "Z8A8ZWCZ45",
                "appcast_path": "/updates/appcast.xml",
                "release_notes_source_pattern": "release-notes/{version}.md",
                "release_notes_url_pattern": "https://{owner}.github.io/{repo}/updates/releases/{version}.html",
                "appcast_url_pattern": "https://{owner}.github.io/{repo}/updates/appcast.xml",
                "github_release": {"tag_pattern": "v{version}", "title_pattern": "LinkGate {version}", "prerelease": True},
                "sparkle": {
                    "version": "2.9.6", "keychain_account": "LinkGate",
                    "public_key": "A" * 43 + "=",
                    "distribution": {
                        "archive_name": "Sparkle-2.9.6.tar.xz",
                        "archive_url": "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz",
                        "archive_sha256": "a" * 64, "sign_update_path": "bin/sign_update",
                        "sign_update_sha256": "b" * 64,
                    },
                },
                "verification": {"attempts": 1, "interval_seconds": 0},
                "minimum_macos_version": "14.0",
                "pages": {"branch": "gh-pages", "commit_author_name": "LinkGate", "commit_author_email": "linkgate@example.com"},
            }
            config_path = root / "publish-config.json"
            config_path.write_text(json.dumps(config_value), encoding="utf-8")
            config = load_config(config_path)
            tool = root / "sparkle/bin/sign_update"
            tool.parent.mkdir(parents=True)
            tool.write_bytes(b"verified sign_update")
            config_value["sparkle"]["distribution"]["sign_update_sha256"] = hashlib.sha256(tool.read_bytes()).hexdigest()
            config_path.write_text(json.dumps(config_value), encoding="utf-8")
            config = load_config(config_path)

            notes_html = render_release_notes(notes_source, version="0.1.4").html_bytes
            item = AppcastItem(
                title="LinkGate 0.1.4", product_url="https://github.com/example/linkgate",
                marketing_version="0.1.4", build_version="6", minimum_system_version="14.0",
                release_notes_url=config.release_notes_url("0.1.4"),
                enclosure_url="https://github.com/example/linkgate/releases/download/v0.1.4/LinkGate-0.1.4.dmg",
                enclosure_length=len(dmg), ed_signature="A" * 86 + "==",
                publication_recorded_at=__import__("datetime").datetime(2026, 9, 13, tzinfo=__import__("datetime").timezone.utc),
            )
            appcast = serialize_appcast(AppcastFeed("LinkGate Beta", "https://github.com/example/linkgate", "Updates", (item,)))
            assets = (
                AssetFact(dmg_name, len(dmg), hashlib.sha256(dmg).hexdigest()),
                AssetFact(checksum_name, (root / f"dist/{checksum_name}").stat().st_size, hashlib.sha256((root / f"dist/{checksum_name}").read_bytes()).hexdigest()),
                AssetFact(manifest_name, len(manifest_bytes), hashlib.sha256(manifest_bytes).hexdigest()),
            )
            record = PublicationRecord(
                "LinkGate", "0.1.4", "6", "a" * 40, "v0.1.4", "example/linkgate", "LinkGate 0.1.4", True,
                assets, assets[-1].sha256, config.appcast_url(), "2026-09-13T00:00:00Z",
            )
            publish_bytes = record.to_json_bytes()
            public_assets = {
                dmg_name: dmg,
                checksum_name: (root / f"dist/{checksum_name}").read_bytes(),
                manifest_name: manifest_bytes,
                "LinkGate-0.1.4.publish.json": publish_bytes,
            }

            class Runner:
                def run(self, args, cwd=None):
                    if args[0] == "/fake/gh" and "release" in args and "view" in args:
                        return CommandResult(0, json.dumps({
                            "tagName": "v0.1.4", "name": "LinkGate 0.1.4", "isDraft": False,
                            "isPrerelease": True, "url": "https://github.com/example/linkgate/releases/tag/v0.1.4",
                            "publishedAt": "2026-09-13T00:01:00Z",
                            "assets": [{"name": name} for name in public_assets],
                        }), "")
                    if args[0] == "/fake/gh" and args[-1].endswith("git/ref/tags/v0.1.4"):
                        return CommandResult(0, json.dumps({"object": {"type": "commit", "sha": "a" * 40}}), "")
                    if args[0] == "/fake/gh" and args[-1].endswith("git/ref/heads/gh-pages"):
                        return CommandResult(0, json.dumps({"object": {"sha": "b" * 40}}), "")
                    if args[0] == "/fake/gh" and args[-1].endswith("commits/" + "b" * 40):
                        return CommandResult(0, json.dumps({
                            "commit": {"message": "Publish LinkGate 0.1.4 update feed\n"},
                            "parents": [{"sha": "c" * 40}],
                            "files": [{"filename": "updates/appcast.xml"}, {"filename": "updates/releases/0.1.4.html"}],
                        }), "")
                    return CommandResult(0, "", "")

            class Http:
                def get(self, url, timeout):
                    if url.endswith("appcast.xml"):
                        return HttpResponse(200, appcast)
                    if url.endswith("0.1.4.html"):
                        return HttpResponse(200, notes_html)
                    return HttpResponse(200, public_assets[Path(url).name])

            class Tools:
                def find(self, name):
                    return {"gh": "/fake/gh", "sign_update": str(tool), "openssl": "/fake/openssl"}.get(name)

            result = verify_published_beta(root, config_path, "0.1.4", runner=Runner(), http=Http(), tools=Tools())
            self.assertEqual(result["outcome"], "RETROSPECTIVE_ACCEPTED")
            self.assertEqual(result["official_sparkle_verification"], "PASS")
            self.assertEqual(result["original_outcome"], "PUBLISHED")
            self.assertNotIn("original_incomplete_reason", result)
            self.assertNotIn("root_cause", result)
            self.assertNotIn("tooling_fix_commit", result)
            self.assertTrue((root / ".scratch/publication-evidence/0.1.4/retrospective-acceptance.json").is_file())


if __name__ == "__main__":
    unittest.main()
