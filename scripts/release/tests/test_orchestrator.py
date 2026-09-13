from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import replace
import hashlib
import json
from unittest.mock import patch

from scripts.release.publish_beta.appcast import AppcastFeed, serialize_appcast
from scripts.release.publish_beta.config import load_config
from scripts.release.publish_beta.errors import FailureClass, PublicationError
from scripts.release.publish_beta.models import AssetFact, PublicationRecord
from scripts.release.publish_beta.mutation import MutationResult, MutationState
from scripts.release.publish_beta.orchestrator import (
    EXIT_CODES,
    OrchestrationDependencies,
    DefaultPagesPusher,
    DefaultPublicVerifier,
    DefaultContentStager,
    LocalEvidenceWriter,
    PagesSourceState,
    PublicationOutcome,
    PublicAcceptance,
    PublishedRelease,
    orchestrate,
)
from scripts.release.publish_beta.pages import PagesStageResult
from scripts.release.publish_beta.preflight import PreflightCategory, PreflightFinding, PreflightReport


COMMIT = "a" * 40
DMG = AssetFact("LinkGate-0.1.4.dmg", 10, "a" * 64)
CHECKSUM = AssetFact("LinkGate-0.1.4.dmg.sha256", 74, "b" * 64)
MANIFEST = AssetFact("LinkGate-0.1.4.release.json", 100, "c" * 64)


def record() -> PublicationRecord:
    return PublicationRecord(
        product="LinkGate",
        marketing_version="0.1.4",
        build="6",
        source_commit=COMMIT,
        release_tag="v0.1.4",
        github_repository="example/linkgate",
        github_title="LinkGate 0.1.4",
        prerelease=True,
        assets=(DMG, CHECKSUM, MANIFEST),
        release_manifest_sha256=MANIFEST.sha256,
        appcast_url="https://example.github.io/linkgate/updates/appcast.xml",
        publication_recorded_at="2026-09-12T12:30:00Z",
    )


def staged() -> MutationResult:
    return MutationResult(MutationState.STAGED_DRAFT_READY, "draft ready", record())


def pages() -> PagesStageResult:
    workspace = Path(tempfile.mkdtemp())
    return PagesStageResult(
        state="PAGES_STAGE_READY",
        commit_sha="b" * 40,
        expected_previous_tip=None,
        bootstrap=True,
        appcast_sha256="d" * 64,
        release_notes_sha256="e" * 64,
        marketing_version="0.1.4",
        build_version="6",
        publication_recorded_at=record().publication_recorded_at,
        workspace=workspace,
    )


class FakeLock:
    def __init__(self, events: list[str]) -> None:
        self.events = events

    def acquire(self) -> None:
        self.events.append("lock.acquire")

    def release(self) -> None:
        self.events.append("lock.release")


class FakeDraft:
    def __init__(self, events: list[str], result: MutationResult | None = None) -> None:
        self.events = events
        self.result = result or staged()
        self.rollback_result: list[str] = []
        self.preflight_report = None

    def stage(self, repo_root, config_path, lock, preflight_report) -> MutationResult:
        self.events.append("draft.stage")
        self.preflight_report = preflight_report
        return self.result

    def rollback(self, staged_result: MutationResult) -> list[str]:
        self.events.append("draft.rollback")
        return self.rollback_result


class FakePagesSource:
    def __init__(self, events: list[str]) -> None:
        self.events = events

    def read(self, record_value: PublicationRecord) -> PagesSourceState:
        self.events.append("pages.read")
        return PagesSourceState(None, None)


class FakeContent:
    def __init__(self, events: list[str], error: Exception | None = None) -> None:
        self.events = events
        self.error = error

    def stage(self, repo_root, config_path, staged_result, source_state) -> PagesStageResult:
        self.events.append("content.stage")
        if self.error:
            raise self.error
        return pages()


class FakeRelease:
    def __init__(self, events: list[str], transition_error: Exception | None = None, public_after_error=False) -> None:
        self.events = events
        self.transition_error = transition_error
        self.public_after_error = public_after_error

    def verify_draft(self, record_value: PublicationRecord) -> None:
        self.events.append("release.verify-draft")

    def transition(self, record_value: PublicationRecord) -> PublishedRelease:
        self.events.append("release.transition")
        if self.transition_error:
            raise self.transition_error
        return PublishedRelease("https://github.com/example/linkgate/releases/tag/v0.1.4", "2026-09-12T12:31:00Z")

    def is_public(self, record_value: PublicationRecord) -> bool | None:
        self.events.append("release.is-public")
        if self.public_after_error:
            return True
        return False

    def verify_public(self, record_value: PublicationRecord) -> PublishedRelease:
        self.events.append("release.verify-public")
        return PublishedRelease("https://github.com/example/linkgate/releases/tag/v0.1.4", "2026-09-12T12:31:00Z")


class FakePagesPush:
    def __init__(self, events: list[str], error: Exception | None = None) -> None:
        self.events = events
        self.error = error

    def push(self, stage, record_value: PublicationRecord) -> None:
        self.events.append("pages.push")
        if self.error:
            raise self.error


class FakePublic:
    def __init__(self, events: list[str]) -> None:
        self.events = events

    def verify(self, record_value, pages_result, release) -> PublicAcceptance:
        self.events.append("public.verify")
        return PublicAcceptance(
            dmg_url="https://github.com/example/linkgate/releases/download/v0.1.4/LinkGate-0.1.4.dmg",
            dmg_sha256="a" * 64,
            appcast_url=record_value.appcast_url,
            appcast_sha256=pages_result.appcast_sha256,
            release_notes_url="https://example.github.io/linkgate/updates/releases/0.1.4.html",
            release_notes_sha256=pages_result.release_notes_sha256,
        )


class FakeEvidence:
    def __init__(self, events: list[str], error: Exception | None = None) -> None:
        self.events = events
        self.error = error

    def write(self, repo_root, record_value, pages_result, release, acceptance, outcome, message):
        self.events.append(f"evidence.{outcome.value}")
        if self.error:
            raise self.error
        return Path(".scratch/publication-evidence/0.1.4")


def ready() -> PreflightReport:
    report = PreflightReport()
    report.add_pass(PreflightCategory.REPOSITORY, "ready")
    return report


def dependencies(events: list[str], **overrides) -> OrchestrationDependencies:
    values = dict(
        lock=FakeLock(events),
        preflight=lambda repo_root, config_path: ready(),
        draft=FakeDraft(events),
        pages_source=FakePagesSource(events),
        content=FakeContent(events),
        release=FakeRelease(events),
        pages_push=FakePagesPush(events),
        public=FakePublic(events),
        evidence=FakeEvidence(events),
        summary=lambda *_: events.append("summary"),
    )
    values.update(overrides)
    return OrchestrationDependencies(**values)


class OrchestrationTests(unittest.TestCase):
    def test_shared_preflight_report_is_forwarded_to_staging(self) -> None:
        events: list[str] = []
        report = ready()
        draft = FakeDraft(events)
        result = orchestrate(
            Path("."), Path("config.json"), dependencies(
                events, preflight=lambda *_: report, draft=draft
            )
        )
        self.assertEqual(result.outcome, PublicationOutcome.PUBLISHED)
        self.assertIs(draft.preflight_report, report)

    def test_happy_path_preserves_publication_order_and_returns_published(self) -> None:
        events: list[str] = []
        result = orchestrate(Path("."), Path("config.json"), dependencies(events))
        self.assertEqual(result.outcome, PublicationOutcome.PUBLISHED)
        self.assertEqual(result.exit_code, EXIT_CODES[PublicationOutcome.PUBLISHED])
        self.assertEqual(
            events,
            [
                "lock.acquire", "summary", "draft.stage", "pages.read", "content.stage",
                "release.verify-draft", "release.transition", "release.verify-public",
                "pages.push", "public.verify", "evidence.PUBLISHED", "lock.release",
            ],
        )

    def test_preflight_block_does_not_call_mutation(self) -> None:
        events: list[str] = []
        report = PreflightReport()
        report.add_blocker(PreflightCategory.CONFIGURATION, "unresolved")
        result = orchestrate(
            Path("."), Path("config.json"), dependencies(events, preflight=lambda *_: report)
        )
        self.assertEqual(result.outcome, PublicationOutcome.BLOCKED_PREFLIGHT)
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(events, ["lock.acquire", "lock.release"])

    def test_failure_before_public_release_rolls_back(self) -> None:
        events: list[str] = []
        result = orchestrate(
            Path("."), Path("config.json"),
            dependencies(events, content=FakeContent(events, PublicationError(FailureClass.APPCAST, "bad feed"))),
        )
        self.assertEqual(result.outcome, PublicationOutcome.ROLLED_BACK)
        self.assertEqual(result.exit_code, 3)
        self.assertIn("draft.rollback", events)
        self.assertNotIn("release.transition", events)

    def test_transition_error_after_release_is_public_is_incomplete_without_rollback(self) -> None:
        events: list[str] = []
        result = orchestrate(
            Path("."), Path("config.json"),
            dependencies(
                events,
                release=FakeRelease(events, RuntimeError("edit response lost"), public_after_error=True),
            ),
        )
        self.assertEqual(result.outcome, PublicationOutcome.INCOMPLETE_PUBLICATION)
        self.assertEqual(result.exit_code, 4)
        self.assertNotIn("draft.rollback", events)

    def test_transition_failure_while_still_draft_rolls_back(self) -> None:
        events: list[str] = []
        result = orchestrate(
            Path("."), Path("config.json"),
            dependencies(
                events,
                release=FakeRelease(events, RuntimeError("publication rejected"), public_after_error=False),
            ),
        )
        self.assertEqual(result.outcome, PublicationOutcome.ROLLED_BACK)
        self.assertEqual(result.exit_code, 3)
        self.assertIn("release.is-public", events)
        self.assertIn("draft.rollback", events)


class AdapterTests(unittest.TestCase):
    def test_default_content_stager_propagates_configured_sparkle_account(self) -> None:
        """The production composition must use the configured Keychain account."""
        from scripts.release.tests.test_staging import config_value

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = config_value()
            config["sparkle"]["keychain_account"] = "LinkGate"
            config_path = root / "publish-config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")

            captured: dict[str, str] = {}

            class RecordingSigner:
                def __init__(self, runner, executable, account="ed25519", private_key_file=None):
                    captured["signer"] = account

            class RecordingVerifier:
                def __init__(self, runner, sign_update, openssl, account="ed25519", private_key_file=None):
                    captured["verifier"] = account

            class Tools:
                def find(self, name):
                    return f"/fake/{name}"

            with patch("scripts.release.publish_beta.orchestrator.SignUpdateAdapter", RecordingSigner), \
                 patch("scripts.release.publish_beta.orchestrator.SparkleSignatureVerifier", RecordingVerifier), \
                 patch("scripts.release.publish_beta.orchestrator.stage_staged_draft_content", return_value="staged"):
                result = DefaultContentStager(object(), Tools()).stage(
                    root,
                    config_path,
                    staged(),
                    PagesSourceState(None, None),
                )

            self.assertEqual(result, "staged")
            self.assertEqual(captured, {"signer": "LinkGate", "verifier": "LinkGate"})

    def test_pages_push_checks_expected_tip_and_publishes_exact_commit_without_force(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.calls = []

            def run(self, args, cwd=None):
                self.calls.append((tuple(args), cwd))
                if tuple(args[:2]) == ("git", "ls-remote") and len(self.calls) == 1:
                    return type("Result", (), {"returncode": 0, "stdout": "b" * 40 + "\trefs/heads/gh-pages\n", "stderr": ""})()
                if tuple(args[:2]) == ("git", "push"):
                    return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()
                return type("Result", (), {"returncode": 0, "stdout": "c" * 40 + "\trefs/heads/gh-pages\n", "stderr": ""})()

        stage = replace(pages(), commit_sha="c" * 40, expected_previous_tip="b" * 40)
        runner = Runner()
        DefaultPagesPusher(runner).push(stage, record())
        push = next(call for call, _ in runner.calls if call[:2] == ("git", "push"))
        self.assertEqual(push, ("git", "push", "https://github.com/example/linkgate.git", "HEAD:refs/heads/gh-pages"))
        self.assertNotIn("--force", push)

    def test_public_verifier_retries_stale_pages_content_and_accepts_exact_bytes(self) -> None:
        from scripts.release.tests.test_staging import config_value, item

        class Http:
            def __init__(self, responses):
                self.responses = responses
                self.calls = []

            def get(self, url, timeout):
                self.calls.append(url)
                values = self.responses[url]
                value = values.pop(0) if len(values) > 1 else values[0]
                return value

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config_value()), encoding="utf-8")
            config = load_config(config_path)
            dmg = b"twelve bytes"
            dmg_fact = AssetFact("LinkGate-0.1.4.dmg", len(dmg), hashlib.sha256(dmg).hexdigest())
            candidate = replace(record(), assets=(dmg_fact, CHECKSUM, MANIFEST))
            expected_feed = serialize_appcast(AppcastFeed("Beta", candidate.appcast_url, "Updates", (item("0.1.4", "6"),)))
            notes = b"<html>release</html>"
            workspace = root / "pages"
            (workspace / "updates/releases").mkdir(parents=True)
            (workspace / "updates/appcast.xml").write_bytes(expected_feed)
            (workspace / "updates/releases/0.1.4.html").write_bytes(notes)
            stage = replace(pages(), workspace=workspace, appcast_sha256=hashlib.sha256(expected_feed).hexdigest(), release_notes_sha256=hashlib.sha256(notes).hexdigest())
            stale = expected_feed.replace(b"LinkGate", b"OldGate", 1)
            from scripts.release.publish_beta.preflight import HttpResponse
            http = Http({
                "https://github.com/example/linkgate/releases/download/v0.1.4/LinkGate-0.1.4.dmg": [HttpResponse(200, dmg)],
                candidate.appcast_url: [HttpResponse(200, stale), HttpResponse(200, expected_feed)],
                "https://example.github.io/linkgate/updates/releases/0.1.4.html": [HttpResponse(200, notes)],
            })
            acceptance = DefaultPublicVerifier(config, http, sleeper=lambda _: None).verify(
                candidate, stage, PublishedRelease("https://github.com/example/linkgate/releases/tag/v0.1.4", "2026-09-12T12:31:00Z")
            )
            self.assertEqual(acceptance.dmg_sha256, dmg_fact.sha256)
            self.assertEqual(http.calls.count(candidate.appcast_url), 2)

    def test_evidence_writer_retains_facts_without_copying_the_dmg(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = pages()
            workspace = stage.workspace
            (workspace / "updates/releases").mkdir(parents=True)
            (workspace / "updates/appcast.xml").write_bytes(b"<rss />")
            (workspace / "updates/releases/0.1.4.html").write_bytes(b"<html />")
            acceptance = PublicAcceptance("https://dmg", "a" * 64, record().appcast_url, "d" * 64, "https://notes", "e" * 64)
            destination = LocalEvidenceWriter().write(
                root, record(), stage, PublishedRelease("https://release", "2026-09-12T12:31:00Z"),
                acceptance, PublicationOutcome.PUBLISHED, "verified",
            )
            self.assertEqual(sorted(path.name for path in destination.iterdir()), [
                "LinkGate-0.1.4.publish.json", "acceptance.json", "appcast.xml", "release-notes.html",
            ])
            self.assertNotIn("dmg", " ".join(path.name for path in destination.iterdir()))
            self.assertEqual(json.loads((destination / "acceptance.json").read_text())["pages_commit_sha"], "b" * 40)

    def test_pages_failure_after_public_release_is_incomplete_without_rollback(self) -> None:
        events: list[str] = []
        result = orchestrate(
            Path("."), Path("config.json"),
            dependencies(events, pages_push=FakePagesPush(events, RuntimeError("concurrent Pages update"))),
        )
        self.assertEqual(result.outcome, PublicationOutcome.INCOMPLETE_PUBLICATION)
        self.assertEqual(result.exit_code, 4)
        self.assertNotIn("draft.rollback", events)

    def test_public_resource_mismatch_after_release_is_incomplete_without_rollback(self) -> None:
        events: list[str] = []

        class FailingPublic(FakePublic):
            def verify(self, record_value, pages_result, release):
                self.events.append("public.verify")
                raise PublicationError(FailureClass.TRUST, "public DMG hash mismatch")

        result = orchestrate(
            Path("."), Path("config.json"),
            dependencies(events, public=FailingPublic(events)),
        )
        self.assertEqual(result.outcome, PublicationOutcome.INCOMPLETE_PUBLICATION)
        self.assertEqual(result.exit_code, 4)
        self.assertNotIn("draft.rollback", events)

    def test_rollback_failure_requires_manual_recovery(self) -> None:
        events: list[str] = []
        draft = FakeDraft(events)
        draft.rollback_result = ["remote tag identity changed"]
        result = orchestrate(Path("."), Path("config.json"), dependencies(events, draft=draft, content=FakeContent(events, RuntimeError("failed"))))
        self.assertEqual(result.outcome, PublicationOutcome.MANUAL_RECOVERY_REQUIRED)
        self.assertEqual(result.exit_code, 5)

    def test_evidence_failure_after_public_verification_is_incomplete(self) -> None:
        events: list[str] = []
        result = orchestrate(
            Path("."), Path("config.json"),
            dependencies(events, evidence=FakeEvidence(events, OSError("read-only evidence root"))),
        )
        self.assertEqual(result.outcome, PublicationOutcome.INCOMPLETE_PUBLICATION)
        self.assertEqual(result.exit_code, 4)
        self.assertNotIn("draft.rollback", events)


if __name__ == "__main__":
    unittest.main()
