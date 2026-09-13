import hashlib
import json
import tempfile
import unittest
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from scripts.release.publish_beta.appcast import AppcastFeed, AppcastItem, serialize_appcast
from scripts.release.publish_beta.errors import FailureClass, PublicationError
from scripts.release.publish_beta.preflight import (
    CommandResult,
    HttpResponse,
    PreflightDependencies,
    PreflightCategory,
    ToolResult,
    run_preflight,
)
from scripts.release.publish_beta.step6 import discover_artifacts, load_manifest, validate_artifacts
from scripts.release.publish_beta.config import load_config
from scripts.release.publish_beta.sparkle import verify_sign_update


DMG_BYTES = b"deterministic Step 6 DMG fixture\n"
DMG_HASH = hashlib.sha256(DMG_BYTES).hexdigest()
COMMIT = "a" * 40
PUBLIC_KEY = "A" * 43 + "="


def config_value(repository="example/linkgate", public_key=PUBLIC_KEY):
    return {
        "schema_version": 1,
        "repository": repository,
        "product": "LinkGate",
        "bundle_id": "com.nickghardwick.LinkGate",
        "team_id": "Z8A8ZWCZ45",
        "appcast_path": "/updates/appcast.xml",
        "release_notes_source_pattern": "release-notes/{version}.md",
        "release_notes_url_pattern": "https://{owner}.github.io/{repo}/updates/releases/{version}.html",
        "appcast_url_pattern": "https://{owner}.github.io/{repo}/updates/appcast.xml",
        "github_release": {"tag_pattern": "v{version}", "title_pattern": "LinkGate {version}", "prerelease": True},
        "sparkle": {
            "version": "2.9.6",
            "public_key": public_key,
            "distribution": {
                "archive_name": "Sparkle-2.9.6.tar.xz",
                "archive_url": "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz",
                "archive_sha256": "a" * 64,
                "sign_update_path": "bin/sign_update",
                "sign_update_sha256": "b" * 64,
            },
        },
        "verification": {"attempts": 2, "interval_seconds": 0},
        "minimum_macos_version": "14.0",
        "pages": {"branch": "gh-pages", "commit_author_name": "LinkGate", "commit_author_email": "linkgate@users.noreply.github.com"},
    }


def manifest_value(version="0.1.4", build="6", source_commit=COMMIT, sha256=DMG_HASH):
    return {
        "product": "LinkGate",
        "marketing_version": version,
        "build": build,
        "bundle_id": "com.nickghardwick.LinkGate",
        "source_commit": source_commit,
        "architectures": ["arm64", "x86_64"],
        "deployment_target": "14.0",
        "signing_identity": "Developer ID Application: LinkGate (Z8A8ZWCZ45)",
        "notarized": True,
        "stapled": True,
        "xcode_version": "Xcode 26.6",
        "macos_version": "26.5",
        "artifact_name": f"LinkGate-{version}.dmg",
        "sha256": sha256,
    }


def appcast_item(version="0.1.3", build="5"):
    return AppcastItem(
        title=f"LinkGate {version}",
        product_url="https://example.com/linkgate",
        marketing_version=version,
        build_version=build,
        minimum_system_version="14.0",
        release_notes_url=f"https://example.github.io/linkgate/updates/releases/{version}.html",
        enclosure_url=f"https://github.com/example/linkgate/releases/download/v{version}/LinkGate-{version}.dmg",
        enclosure_length=10,
        ed_signature="fixture-signature",
        publication_recorded_at=datetime(2026, 9, 12, 12, 30, tzinfo=timezone.utc),
    )


class FakeRunner:
    def __init__(self, responses=None):
        self.responses = responses or {}
        self.calls = []

    def run(self, args, cwd=None):
        call = tuple(str(arg) for arg in args)
        self.calls.append((call, cwd))
        response = self.responses.get(call)
        if callable(response):
            return response(call, cwd)
        return response or CommandResult(0, "", "")


class FakeTools:
    def __init__(self, values):
        self.values = values

    def find(self, name):
        value = self.values.get(name)
        return value.path if value else None

    def inspect(self, name, path):
        return self.values[name]


@dataclass(frozen=True)
class FixtureTool:
    path: str
    version: str = "tool 1.0"
    version_ok: bool = True


class FakeHTTP:
    def __init__(self, response):
        self.response = response
        self.urls = []

    def get(self, url, timeout):
        self.urls.append((url, timeout))
        return self.response


def write_repo(tmpdir, *, version="0.1.4", build="6", source_commit=COMMIT, notes=True, dirty=False):
    root = Path(tmpdir) / "repo"
    (root / "dist").mkdir(parents=True, exist_ok=True)
    (root / "release-notes").mkdir(exist_ok=True)
    manifest = manifest_value(version, build, source_commit)
    (root / "dist" / manifest["artifact_name"]).write_bytes(DMG_BYTES)
    (root / "dist" / f"{manifest['artifact_name']}.sha256").write_text(
        f"{DMG_HASH}  {manifest['artifact_name']}\n", encoding="utf-8"
    )
    (root / "dist" / f"LinkGate-{version}.release.json").write_text(json.dumps(manifest), encoding="utf-8")
    if notes:
        (root / "release-notes" / f"{version}.md").write_text("# Changes\n\n- Fresh beta\n", encoding="utf-8")
    return root


class Step6Tests(unittest.TestCase):
    def test_valid_manifest_and_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            manifest = load_manifest(root / "dist/LinkGate-0.1.4.release.json")
            artifacts = discover_artifacts(root, manifest)
            facts = validate_artifacts(artifacts)
            self.assertEqual(facts.sha256, DMG_HASH)

    def test_artifact_failures_are_classified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            manifest_path = root / "dist/LinkGate-0.1.4.release.json"
            manifest_path.unlink()
            with self.assertRaises(PublicationError) as raised:
                load_manifest(manifest_path)
            self.assertEqual(raised.exception.failure_class, FailureClass.PROVENANCE)

            root = write_repo(directory)
            manifest_path = root / "dist/LinkGate-0.1.4.release.json"
            value = json.loads(manifest_path.read_text(encoding="utf-8"))
            value["sha256"] = "b" * 64
            manifest_path.write_text(json.dumps(value), encoding="utf-8")
            manifest = load_manifest(root / "dist/LinkGate-0.1.4.release.json")
            with self.assertRaises(PublicationError) as raised:
                validate_artifacts(discover_artifacts(root, manifest))
            self.assertEqual(raised.exception.failure_class, FailureClass.ARTIFACT)

            (root / "dist/LinkGate-0.1.4.dmg").unlink()
            with self.assertRaises(PublicationError):
                discover_artifacts(root, manifest)

            root = write_repo(directory)
            (root / "dist/LinkGate-0.1.4.dmg.sha256").unlink()
            with self.assertRaises(PublicationError):
                discover_artifacts(root, load_manifest(root / "dist/LinkGate-0.1.4.release.json"))

    def test_version_filename_and_checksum_mismatches_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            checksum = root / "dist/LinkGate-0.1.4.dmg.sha256"
            checksum.write_text(f"{DMG_HASH}  LinkGate-0.1.3.dmg\n", encoding="utf-8")
            manifest = load_manifest(root / "dist/LinkGate-0.1.4.release.json")
            with self.assertRaises(PublicationError):
                validate_artifacts(discover_artifacts(root, manifest))


class PreflightTests(unittest.TestCase):
    def write_config(self, root, value=None):
        path = root / "publish-config.json"
        path.write_text(json.dumps(value or config_value()), encoding="utf-8")
        return path

    def base_dependencies(self, xcode_settings=None):
        settings = xcode_settings or {
            "PRODUCT_NAME": "LinkGate",
            "MARKETING_VERSION": "0.1.4",
            "CURRENT_PROJECT_VERSION": "6",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.nickghardwick.LinkGate",
            "ARCHS": "arm64 x86_64",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "CODE_SIGN_IDENTITY": "Developer ID Application",
            "DEVELOPMENT_TEAM": "Z8A8ZWCZ45",
        }
        runner = FakeRunner()
        xcode_call = (
            "xcodebuild", "-project", "LinkGate.xcodeproj", "-scheme", "LinkGate",
            "-configuration", "Release", "-showBuildSettings", "-json"
        )
        runner.responses[xcode_call] = CommandResult(
            0,
            json.dumps([{"action": "build", "target": "LinkGate", "buildSettings": settings}]),
            "",
        )
        tools = FakeTools({name: FixtureTool(f"/fake/{name}") for name in (
            "git", "gh", "python", "xcodebuild", "xcrun", "codesign", "stapler", "spctl", "hdiutil", "sign_update"
        )})
        return PreflightDependencies(runner=runner, tools=tools, http=FakeHTTP(HttpResponse(404, b"")))

    def test_stale_source_commit_and_missing_notes_block(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory, source_commit=COMMIT, notes=False)
            config_path = self.write_config(root)
            deps = self.base_dependencies()
            deps.runner.responses[("git", "rev-parse", "--show-toplevel")] = CommandResult(0, str(root), "")
            deps.runner.responses[("git", "rev-parse", "--abbrev-ref", "HEAD")] = CommandResult(0, "main\n", "")
            deps.runner.responses[("git", "status", "--porcelain", "--untracked-files=all")] = CommandResult(0, "", "")
            deps.runner.responses[("git", "diff", "--quiet")] = CommandResult(0, "", "")
            deps.runner.responses[("git", "diff", "--cached", "--quiet")] = CommandResult(0, "", "")
            deps.runner.responses[("git", "rev-parse", "HEAD")] = CommandResult(0, "b" * 40 + "\n", "")
            deps.runner.responses[("git", "tag", "--list", "v0.1.4")] = CommandResult(0, "", "")
            report = run_preflight(root, config_path, deps)
            messages = "\n".join(f.message for f in report.findings if f.blocking)
            self.assertIn("HEAD does not match Step 6 source commit", messages)
            self.assertIn("release-note source is missing", messages)

    def test_candidate_is_rejected_when_existing_feed_is_not_older(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            config_path = self.write_config(root)
            deps = self.base_dependencies()
            deps.http = FakeHTTP(HttpResponse(200, serialize_appcast(
                AppcastFeed("Beta", "https://example.com", "Updates", (appcast_item("0.1.4", "6"),))
            )))
            report = run_preflight(root, config_path, deps)
            self.assertTrue(any(f.category is PreflightCategory.APPCAST and f.blocking for f in report.findings))

    def test_forbidden_mutation_commands_are_never_invoked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            deps = self.base_dependencies()
            run_preflight(root, self.write_config(root, config_value("OWNER/REPO", "REPLACE_AFTER_ONE_TIME_KEY_SETUP")), deps)
            called = " ".join(" ".join(call) for call, _ in deps.runner.calls)
            for forbidden in ("git tag -a", "git push", "gh release create", "gh release upload", "gh release delete", "sign_update"):
                self.assertNotIn(forbidden, called)

    def test_report_uses_stable_not_ready_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            report = run_preflight(root, self.write_config(root, config_value("OWNER/REPO", "REPLACE_AFTER_ONE_TIME_KEY_SETUP")), self.base_dependencies())
            self.assertEqual(report.exit_code, 2)
            self.assertIn("BLOCKED", report.render())

    def test_github_read_only_checks_distinguish_absent_and_existing_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            deps = self.base_dependencies()
            gh = "/fake/gh"
            deps.runner.responses[(gh, "auth", "status", "--hostname", "github.com")] = CommandResult(0, "Logged in", "")
            deps.runner.responses[(gh, "repo", "view", "example/linkgate", "--json", "nameWithOwner,viewerPermission")] = CommandResult(0, '{"nameWithOwner":"example/linkgate","viewerPermission":"WRITE"}', "")
            deps.runner.responses[(gh, "api", "--method", "GET", "repos/example/linkgate/git/ref/tags/v0.1.4")] = CommandResult(1, "", "Not Found")
            deps.runner.responses[(gh, "release", "view", "v0.1.4", "--repo", "example/linkgate", "--json", "tagName,name,isDraft,isPrerelease")] = CommandResult(1, "", "release not found")
            report = run_preflight(root, self.write_config(root), deps)
            self.assertTrue(any(f.category is PreflightCategory.GITHUB and not f.blocking for f in report.findings))

            deps.runner.responses[(gh, "api", "--method", "GET", "repos/example/linkgate/git/ref/tags/v0.1.4")] = CommandResult(0, "{}", "")
            deps.runner.responses[(gh, "release", "view", "v0.1.4", "--repo", "example/linkgate", "--json", "tagName,name,isDraft,isPrerelease")] = CommandResult(0, "{}", "")
            report = run_preflight(root, self.write_config(root), deps)
            blockers = "\n".join(f.message for f in report.findings if f.blocking)
            self.assertIn("remote release tag already exists", blockers)
            self.assertIn("GitHub Release already exists", blockers)

    def test_missing_tool_and_unverified_sparkle_provenance_are_blockers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            deps = self.base_dependencies()
            deps.tools.values.pop("gh")
            deps.tools.values["sign_update"] = FixtureTool("/fake/bin/sign_update")
            report = run_preflight(root, self.write_config(root), deps)
            blockers = "\n".join(f.message for f in report.findings if f.blocking)
            self.assertIn("required tool is unavailable: gh", blockers)
            self.assertIn("could not read Sparkle sign_update", blockers)

    def test_sparkle_provenance_accepts_exact_binary_and_rejects_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "bin" / "sign_update"
            tool.parent.mkdir()
            tool.write_bytes(b"official Sparkle 2.9.6 sign_update fixture")
            value = config_value()
            value["sparkle"]["distribution"]["sign_update_sha256"] = hashlib.sha256(tool.read_bytes()).hexdigest()
            path = root / "publish-config.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            config = load_config(path)
            verify_sign_update(config, str(tool))
            tool.write_bytes(b"unrecognized replacement")
            with self.assertRaises(PublicationError) as raised:
                verify_sign_update(config, str(tool))
            self.assertIn("does not match the pinned", str(raised.exception))

    def test_sparkle_provenance_does_not_probe_an_unstable_version_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            deps = self.base_dependencies()
            run_preflight(root, self.write_config(root), deps)
            sign_update_calls = [call for call, _ in deps.runner.calls if "sign_update" in call]
            self.assertEqual(sign_update_calls, [])

    def test_appcast_bootstrap_and_malformed_states_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            deps = self.base_dependencies()
            report = run_preflight(root, self.write_config(root), deps)
            self.assertTrue(any(f.category is PreflightCategory.APPCAST and not f.blocking and "bootstrap" in f.message for f in report.findings))

            deps.http = FakeHTTP(HttpResponse(200, b"not XML"))
            report = run_preflight(root, self.write_config(root), deps)
            self.assertTrue(any(f.category is PreflightCategory.APPCAST and f.blocking and "invalid" in f.message for f in report.findings))

    def test_xcode_and_repository_state_mismatches_are_blockers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = write_repo(directory)
            settings = {
                "PRODUCT_NAME": "LinkGate",
                "MARKETING_VERSION": "0.1.3",
                "CURRENT_PROJECT_VERSION": "5",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.nickghardwick.LinkGate",
                "ARCHS": "arm64 x86_64",
                "MACOSX_DEPLOYMENT_TARGET": "14.0",
                "CODE_SIGN_IDENTITY": "Developer ID Application",
            }
            deps = self.base_dependencies(settings)
            deps.runner.responses[("git", "rev-parse", "--show-toplevel")] = CommandResult(0, str(root), "")
            deps.runner.responses[("git", "rev-parse", "--abbrev-ref", "HEAD")] = CommandResult(0, "release\n", "")
            deps.runner.responses[("git", "status", "--porcelain", "--untracked-files=all")] = CommandResult(0, " M file\n", "")
            deps.runner.responses[("git", "diff", "--quiet")] = CommandResult(1, "", "")
            deps.runner.responses[("git", "diff", "--cached", "--quiet")] = CommandResult(0, "", "")
            deps.runner.responses[("git", "rev-parse", "HEAD")] = CommandResult(0, COMMIT + "\n", "")
            deps.runner.responses[("git", "tag", "--list", "v0.1.4")] = CommandResult(0, "v0.1.4\n", "")
            report = run_preflight(root, self.write_config(root), deps)
            blockers = "\n".join(f.message for f in report.findings if f.blocking)
            self.assertIn("current branch is not main", blockers)
            self.assertIn("working tree or index is not clean", blockers)
            self.assertIn("local tag already exists", blockers)
            self.assertIn("Xcode metadata disagrees", blockers)


if __name__ == "__main__":
    unittest.main()
