from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.release.publish_beta.errors import FailureClass
from scripts.release.publish_beta.mutation import (
    GitTagMutation,
    GitHubMutation,
    MutationDependencies,
    MutationFailure,
    MutationState,
    PublicationLock,
    stage_draft,
)
from scripts.release.publish_beta.preflight import CommandResult, PreflightReport, SubprocessRunner


COMMIT = "a" * 40
DMG_BYTES = b"immutable Step 6 DMG fixture\n"
DMG_HASH = hashlib.sha256(DMG_BYTES).hexdigest()
PUBLIC_KEY = "A" * 43 + "="


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
            "version": "2.9.6",
            "public_key": PUBLIC_KEY,
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


class FakeTools:
    def find(self, name: str) -> str | None:
        return "/fake/gh" if name == "gh" else None


class FakeRunner:
    def __init__(self, *, fail_stage: str | None = None, change_tag_on_failure: bool = False, fail_delete: bool = False, wrong_commit_on_create: bool = False):
        self.calls: list[tuple[tuple[str, ...], Path | None]] = []
        self.local_tag = False
        self.local_commit = COMMIT
        self.remote_tag = False
        self.remote_commit = COMMIT
        self.release = False
        self.release_public = False
        self.release_assets: dict[str, bytes] = {}
        self.fail_stage = fail_stage
        self.change_tag_on_failure = change_tag_on_failure
        self.fail_delete = fail_delete
        self.wrong_commit_on_create = wrong_commit_on_create
        self.skip_upload_name: str | None = None
        self.extra_asset: str | None = None
        self.upload_count = 0

    def run(self, args, cwd=None):
        call = tuple(str(arg) for arg in args)
        self.calls.append((call, cwd))
        if call[:3] == ("git", "tag", "--annotate"):
            if self.local_tag:
                return CommandResult(1, "", "tag exists")
            self.local_tag = True
            if self.wrong_commit_on_create:
                self.local_commit = "b" * 40
            return CommandResult(0, "", "")
        if call[:2] == ("git", "rev-parse") and len(call) == 4 and call[3].endswith("^{}"):
            if self.local_tag:
                return CommandResult(0, self.local_commit + "\n", "")
            return CommandResult(1, "", "missing tag")
        if call[:2] == ("git", "push"):
            if call[-1].startswith(":refs/tags/"):
                self.remote_tag = False
                return CommandResult(0, "", "")
            if self.fail_stage == "push":
                return CommandResult(1, "", "push failed")
            self.remote_tag = True
            return CommandResult(0, "", "")
        if call[:3] == ("git", "tag", "--delete"):
            self.local_tag = False
            return CommandResult(0, "", "")
        if len(call) > 1 and call[1] == "api":
            endpoint = call[-1]
            if "/git/ref/tags/" in endpoint:
                if not self.remote_tag:
                    return CommandResult(1, "", "Not Found")
                return CommandResult(0, json.dumps({"object": {"type": "commit", "sha": self.remote_commit}}), "")
            return CommandResult(1, "", "Not Found")
        if len(call) > 2 and call[1:3] == ("release", "create"):
            if self.fail_stage == "create-release":
                return CommandResult(1, "", "release create failed")
            self.release = True
            return CommandResult(0, "https://github.com/example/linkgate/releases/tag/v0.1.4\n", "")
        if len(call) > 2 and call[1:3] == ("release", "view"):
            if not self.release:
                return CommandResult(1, "", "release not found")
            assets = [{"name": name, "size": len(data)} for name, data in self.release_assets.items()]
            if self.extra_asset:
                assets.append({"name": self.extra_asset, "size": 1})
            return CommandResult(0, json.dumps({
                "tagName": "v0.1.4",
                "name": "LinkGate 0.1.4",
                "isDraft": not self.release_public,
                "isPrerelease": True,
                "assets": assets,
                "url": "https://github.com/example/linkgate/releases/tag/v0.1.4",
                "publishedAt": "2026-09-12T12:31:00Z" if self.release_public else None,
            }), "")
        if len(call) > 2 and call[1:3] == ("release", "edit"):
            self.release_public = True
            return CommandResult(0, "", "")
        if len(call) > 2 and call[1:3] == ("release", "upload"):
            if "--clobber" in call:
                return CommandResult(1, "", "clobber forbidden")
            self.upload_count += 1
            if self.fail_stage == f"upload-{self.upload_count}":
                if self.change_tag_on_failure:
                    self.local_commit = "b" * 40
                    self.remote_commit = "b" * 40
                return CommandResult(1, "", "upload failed")
            for value in call[3:]:
                if value.startswith("--"):
                    continue
                path = Path(value)
                if path.is_file():
                    if path.name == self.skip_upload_name:
                        continue
                    self.release_assets[path.name] = path.read_bytes()
            return CommandResult(0, "", "")
        if len(call) > 2 and call[1:3] == ("release", "download"):
            directory = Path(call[call.index("--dir") + 1])
            pattern = call[call.index("--pattern") + 1]
            if pattern not in self.release_assets:
                return CommandResult(1, "", "asset not found")
            data = self.release_assets[pattern]
            if getattr(self, "corrupt_asset", None) == pattern:
                data = b"corrupt remote bytes\n"
            (directory / pattern).write_bytes(data)
            return CommandResult(0, "", "")
        if len(call) > 2 and call[1:3] == ("release", "delete"):
            if self.fail_delete:
                return CommandResult(1, "", "delete failed")
            self.release = False
            self.release_assets.clear()
            return CommandResult(0, "", "")
        return CommandResult(0, "", "")


def write_repo(directory: str) -> tuple[Path, Path]:
    root = Path(directory) / "repo"
    (root / "dist").mkdir(parents=True)
    (root / "release-notes").mkdir()
    manifest = {
        "product": "LinkGate",
        "marketing_version": "0.1.4",
        "build": "6",
        "bundle_id": "com.nickghardwick.LinkGate",
        "source_commit": COMMIT,
        "architectures": ["arm64", "x86_64"],
        "deployment_target": "14.0",
        "signing_identity": "Developer ID Application: LinkGate (Z8A8ZWCZ45)",
        "notarized": True,
        "stapled": True,
        "xcode_version": "Xcode 26.6",
        "macos_version": "26.5",
        "artifact_name": "LinkGate-0.1.4.dmg",
        "sha256": DMG_HASH,
    }
    (root / "dist/LinkGate-0.1.4.dmg").write_bytes(DMG_BYTES)
    (root / "dist/LinkGate-0.1.4.dmg.sha256").write_text(
        f"{DMG_HASH}  LinkGate-0.1.4.dmg\n", encoding="utf-8"
    )
    manifest_path = root / "dist/LinkGate-0.1.4.release.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    (root / "release-notes/0.1.4.md").write_text("# Changes\n\n- Fresh beta\n", encoding="utf-8")
    config_path = root / "publish-config.json"
    config_path.write_text(json.dumps(config_value()), encoding="utf-8")
    return root, config_path


def ready_preflight(*args, **kwargs) -> PreflightReport:
    return PreflightReport()


class MutationTests(unittest.TestCase):
    def dependencies(self, runner: FakeRunner) -> MutationDependencies:
        return MutationDependencies(
            runner=runner,
            tools=FakeTools(),
            preflight=ready_preflight,
            clock=lambda: datetime(2026, 9, 12, 12, 30, tzinfo=timezone.utc),
        )

    def test_blocked_preflight_performs_no_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            blocked = PreflightReport()
            blocked.add_blocker("repository", "blocked")
            deps = self.dependencies(runner)
            deps.preflight = lambda *args, **kwargs: blocked
            result = stage_draft(root, config, deps)
            self.assertEqual(result.state, MutationState.PREFLIGHT_BLOCKED)
            self.assertFalse(any(call[0][0] in {"git", "gh"} for call in runner.calls))

    def test_supplied_preflight_is_not_run_again(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            calls = []
            deps = self.dependencies(runner)
            deps.preflight = lambda *args, **kwargs: calls.append(True) or PreflightReport()
            result = stage_draft(root, config, deps, preflight_report=PreflightReport())
            self.assertEqual(result.state, MutationState.STAGED_DRAFT_READY)
            self.assertEqual(calls, [])

    def test_publication_lock_rejects_concurrent_invocation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".linkgate-publish.lock"
            first = PublicationLock(path)
            second = PublicationLock(path)
            first.acquire()
            try:
                with self.assertRaises(MutationFailure):
                    second.acquire()
            finally:
                first.release()

    def test_real_tag_helper_is_annotated_in_throwaway_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            subprocess.run(["git", "init", "--initial-branch=main"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.name", "Test Publisher"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "publisher@example.invalid"], cwd=root, check=True)
            (root / "file").write_text("fixture\n", encoding="utf-8")
            subprocess.run(["git", "add", "file"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "fixture"], cwd=root, check=True, capture_output=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

            GitTagMutation(SubprocessRunner()).create_local(
                root, "v0.1.4", commit, "LinkGate 0.1.4"
            )
            self.assertEqual(subprocess.check_output(["git", "cat-file", "-t", "v0.1.4"], cwd=root, text=True).strip(), "tag")
            self.assertEqual(subprocess.check_output(["git", "rev-parse", "v0.1.4^{}"], cwd=root, text=True).strip(), commit)

    def test_success_stages_exact_assets_and_verifies_all_four_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            step6_before = {
                path: path.read_bytes()
                for path in (root / "dist").iterdir()
            }
            clock_calls = []
            deps = self.dependencies(runner)
            deps.clock = lambda: (clock_calls.append(True), datetime(2026, 9, 12, 12, 30, tzinfo=timezone.utc))[1]
            result = stage_draft(root, config, deps)
            self.assertEqual(result.state, MutationState.STAGED_DRAFT_READY)
            self.assertTrue(runner.local_tag and runner.remote_tag and runner.release)
            self.assertEqual({path: path.read_bytes() for path in (root / "dist").iterdir()}, step6_before)
            self.assertEqual(
                set(runner.release_assets),
                {"LinkGate-0.1.4.dmg", "LinkGate-0.1.4.dmg.sha256", "LinkGate-0.1.4.release.json", "LinkGate-0.1.4.publish.json"},
            )
            self.assertTrue(all("--clobber" not in call for call, _ in runner.calls))
            self.assertEqual(result.publication_record.publication_recorded_at, "2026-09-12T12:30:00Z")
            self.assertEqual(len(clock_calls), 1)
            publish = json.loads(runner.release_assets["LinkGate-0.1.4.publish.json"])
            self.assertEqual(len(publish["assets"]), 3)
            self.assertNotIn("LinkGate-0.1.4.publish.json", {asset["name"] for asset in publish["assets"]})
            self.assertEqual(publish["release_manifest_sha256"], hashlib.sha256(runner.release_assets["LinkGate-0.1.4.release.json"]).hexdigest())
            self.assertEqual(
                {asset["name"] for asset in publish["assets"]},
                {"LinkGate-0.1.4.dmg", "LinkGate-0.1.4.dmg.sha256", "LinkGate-0.1.4.release.json"},
            )
            self.assertTrue(any(call[:3] == ("git", "tag", "--annotate") for call, _ in runner.calls))
            push_calls = [call for call, _ in runner.calls if call[:2] == ("git", "push")]
            self.assertEqual(push_calls[0][-1], "refs/tags/v0.1.4:refs/tags/v0.1.4")
            create_call = next(call for call, _ in runner.calls if len(call) > 2 and call[1:3] == ("release", "create"))
            self.assertIn("--draft", create_call)
            self.assertIn("--prerelease", create_call)
            self.assertIn("--verify-tag", create_call)

    def test_public_transition_requires_verified_draft_and_keeps_exact_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.STAGED_DRAFT_READY)
            github = GitHubMutation(runner, "/fake/gh")
            names = tuple(asset.name for asset in result.publication_record.assets) + ("LinkGate-0.1.4.publish.json",)
            details = github.transition_to_public("example/linkgate", "v0.1.4", "LinkGate 0.1.4", names)
            self.assertFalse(details["isDraft"])
            self.assertTrue(details["isPrerelease"])
            edit = next(call for call, _ in runner.calls if call[1:3] == ("release", "edit"))
            self.assertIn("--draft=false", edit)
            self.assertIn("--prerelease=true", edit)
            self.assertEqual(github.verify_public("example/linkgate", "v0.1.4", "LinkGate 0.1.4", names)["publishedAt"], "2026-09-12T12:31:00Z")

    def test_final_draft_verification_checks_asset_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.STAGED_DRAFT_READY)
            names = tuple(asset.name for asset in result.publication_record.assets) + ("LinkGate-0.1.4.publish.json",)
            expected = dict(runner.release_assets)
            github = GitHubMutation(runner, "/fake/gh")
            github.verify_draft("example/linkgate", "v0.1.4", "LinkGate 0.1.4", names, expected)
            runner.corrupt_asset = "LinkGate-0.1.4.dmg"
            with self.assertRaises(MutationFailure):
                github.verify_draft("example/linkgate", "v0.1.4", "LinkGate 0.1.4", names, expected)

    def test_wrong_local_tag_target_requires_manual_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(wrong_commit_on_create=True)
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.MANUAL_RECOVERY_REQUIRED)
            self.assertTrue(runner.local_tag)

    def test_draft_creation_failure_rolls_back_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="create-release")
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.ROLLED_BACK)
            self.assertFalse(runner.local_tag or runner.remote_tag or runner.release)

    def test_preexisting_local_tag_is_never_adopted_or_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            runner.local_tag = True
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.MANUAL_RECOVERY_REQUIRED)
            self.assertTrue(runner.local_tag)

    def test_push_failure_rolls_back_local_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="push")
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.ROLLED_BACK)
            self.assertFalse(runner.local_tag or runner.remote_tag or runner.release)

    def test_partial_upload_rolls_back_release_and_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="upload-2")
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.ROLLED_BACK)
            self.assertFalse(runner.local_tag or runner.remote_tag or runner.release)
            self.assertEqual((root / "dist/LinkGate-0.1.4.dmg").read_bytes(), DMG_BYTES)

    def test_remote_hash_mismatch_rolls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner()
            runner.corrupt_asset = "LinkGate-0.1.4.dmg"
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.ROLLED_BACK)
            self.assertFalse(runner.local_tag or runner.remote_tag or runner.release)

    def test_missing_or_unexpected_draft_asset_is_rejected(self):
        for attribute, value in (("skip_upload_name", "LinkGate-0.1.4.dmg"), ("extra_asset", "unexpected.txt")):
            with self.subTest(attribute=attribute):
                with tempfile.TemporaryDirectory() as directory:
                    root, config = write_repo(directory)
                    runner = FakeRunner()
                    setattr(runner, attribute, value)
                    result = stage_draft(root, config, self.dependencies(runner))
                    self.assertEqual(result.state, MutationState.ROLLED_BACK)
                    self.assertFalse(runner.local_tag or runner.remote_tag or runner.release)

    def test_publication_asset_upload_failure_rolls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="upload-4")
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.ROLLED_BACK)
            self.assertFalse(runner.local_tag or runner.remote_tag or runner.release)

    def test_changed_tag_identity_requires_manual_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="upload-1", change_tag_on_failure=True)
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.MANUAL_RECOVERY_REQUIRED)
            self.assertIn("manual recovery", result.message.lower())
            self.assertTrue(runner.local_tag or runner.remote_tag)

    def test_failed_rollback_is_reported_as_manual_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="upload-1", fail_delete=True)
            result = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(result.state, MutationState.MANUAL_RECOVERY_REQUIRED)

    def test_fresh_retry_after_rollback_has_no_resume_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root, config = write_repo(directory)
            runner = FakeRunner(fail_stage="upload-1")
            first = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(first.state, MutationState.ROLLED_BACK)
            runner.fail_stage = None
            second = stage_draft(root, config, self.dependencies(runner))
            self.assertEqual(second.state, MutationState.STAGED_DRAFT_READY)


if __name__ == "__main__":
    unittest.main()
