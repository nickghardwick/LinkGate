from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from time import sleep
from typing import Callable, Protocol, Sequence

from .config import PublicationConfig, load_config
from .content import github_release_asset_url
from .errors import FailureClass, PublicationError
from .models import PublicationRecord
from .mutation import (
    GitHubMutation,
    MutationDependencies,
    MutationResult,
    MutationState,
    PublicationLock,
    rollback_staged_draft,
    stage_draft,
)
from .pages import LocalPagesGit, PagesStageResult
from .preflight import (
    DefaultHttpClient,
    DefaultToolLocator,
    HttpClient,
    PreflightDependencies,
    PreflightReport,
    SubprocessRunner,
    ToolLocator,
    run_preflight,
)
from .sparkle import SignUpdateAdapter, SparkleSignatureVerifier
from .staging import stage_staged_draft_content
from .step6 import discover_artifacts, load_manifest, validate_artifacts


class PublicationOutcome(str, Enum):
    PUBLISHED = "PUBLISHED"
    ROLLED_BACK = "ROLLED_BACK"
    INCOMPLETE_PUBLICATION = "INCOMPLETE_PUBLICATION"
    MANUAL_RECOVERY_REQUIRED = "MANUAL_RECOVERY_REQUIRED"
    BLOCKED_PREFLIGHT = "BLOCKED_PREFLIGHT"
    INTERNAL_ERROR = "INTERNAL_ERROR"


EXIT_CODES = {
    PublicationOutcome.PUBLISHED: 0,
    PublicationOutcome.BLOCKED_PREFLIGHT: 2,
    PublicationOutcome.ROLLED_BACK: 3,
    PublicationOutcome.INCOMPLETE_PUBLICATION: 4,
    PublicationOutcome.MANUAL_RECOVERY_REQUIRED: 5,
    PublicationOutcome.INTERNAL_ERROR: 70,
}


@dataclass(frozen=True)
class PublicationResult:
    outcome: PublicationOutcome
    message: str
    exit_code: int
    publication_record: PublicationRecord | None = None
    pages_stage: PagesStageResult | None = None
    evidence_path: Path | None = None


@dataclass(frozen=True)
class PagesSourceState:
    existing_appcast: bytes | None
    expected_previous_tip: str | None


@dataclass(frozen=True)
class PublishedRelease:
    url: str
    published_at: str | None


@dataclass(frozen=True)
class PublicAcceptance:
    dmg_url: str
    dmg_sha256: str
    appcast_url: str
    appcast_sha256: str
    release_notes_url: str
    release_notes_sha256: str


class DraftLifecycle(Protocol):
    def stage(
        self, repo_root: Path, config_path: Path, lock: PublicationLock, preflight_report: PreflightReport
    ) -> MutationResult:
        ...

    def rollback(self, staged: MutationResult) -> list[str]:
        ...


class PagesSource(Protocol):
    def read(self, record: PublicationRecord) -> PagesSourceState:
        ...


class ContentStager(Protocol):
    def stage(self, repo_root: Path, config_path: Path, staged: MutationResult, source: PagesSourceState) -> PagesStageResult:
        ...


class ReleaseLifecycle(Protocol):
    def verify_draft(self, record: PublicationRecord) -> None:
        ...

    def transition(self, record: PublicationRecord) -> PublishedRelease:
        ...

    def is_public(self, record: PublicationRecord) -> bool | None:
        ...

    def verify_public(self, record: PublicationRecord) -> PublishedRelease:
        ...


class PagesPusher(Protocol):
    def push(self, stage: PagesStageResult, record: PublicationRecord) -> None:
        ...


class PublicVerifier(Protocol):
    def verify(self, record: PublicationRecord, stage: PagesStageResult, release: PublishedRelease) -> PublicAcceptance:
        ...


class EvidenceWriter(Protocol):
    def write(
        self,
        repo_root: Path,
        record: PublicationRecord,
        stage: PagesStageResult,
        release: PublishedRelease,
        acceptance: PublicAcceptance | None,
        outcome: PublicationOutcome,
        message: str,
    ) -> Path:
        ...


@dataclass
class OrchestrationDependencies:
    lock: PublicationLock
    preflight: Callable[[Path, Path], PreflightReport]
    draft: DraftLifecycle
    pages_source: PagesSource
    content: ContentStager
    release: ReleaseLifecycle
    pages_push: PagesPusher
    public: PublicVerifier
    evidence: EvidenceWriter
    summary: Callable[[Path, Path], None]


def _result(outcome: PublicationOutcome, message: str, **kwargs) -> PublicationResult:
    return PublicationResult(outcome, message, EXIT_CODES[outcome], **kwargs)


def _summary(repo_root: Path, config_path: Path) -> dict[str, str]:
    config = load_config(config_path)
    manifest_path = repo_root / "dist"
    manifests = sorted(manifest_path.glob("LinkGate-*.release.json"))
    if len(manifests) != 1:
        raise PublicationError(FailureClass.PROVENANCE, "publication summary requires exactly one Step 6 manifest")
    manifest = load_manifest(manifests[0])
    artifacts = validate_artifacts(discover_artifacts(repo_root, manifest))
    return {
        "version": manifest.marketing_version,
        "build": manifest.build,
        "source_commit": manifest.source_commit,
        "tag": config.release_tag(manifest.marketing_version),
        "repository": config.repository,
        "dmg_sha256": artifacts.sha256,
        "prerelease": str(config.prerelease).lower(),
    }


def _cleanup_pages_workspace(stage: PagesStageResult | None) -> None:
    if stage is not None and stage.workspace.exists():
        shutil.rmtree(stage.workspace, ignore_errors=True)


def _rollback_before_publication(
    draft: DraftLifecycle,
    staged: MutationResult | None,
    pages_stage: PagesStageResult | None,
) -> list[str]:
    errors: list[str] = []
    if staged is not None and staged.state is MutationState.STAGED_DRAFT_READY:
        try:
            errors.extend(draft.rollback(staged))
        except Exception as error:
            errors.append(f"draft rollback failed ({type(error).__name__})")
    _cleanup_pages_workspace(pages_stage)
    return errors


def orchestrate(repo_root: Path, config_path: Path, dependencies: OrchestrationDependencies) -> PublicationResult:
    staged: MutationResult | None = None
    pages_stage: PagesStageResult | None = None
    public = False
    transition_started = False
    try:
        dependencies.lock.acquire()
    except Exception as error:
        return _result(PublicationOutcome.BLOCKED_PREFLIGHT, f"publication lock unavailable ({type(error).__name__})")

    try:
        try:
            report = dependencies.preflight(repo_root, config_path)
        except Exception as error:
            return _result(PublicationOutcome.INTERNAL_ERROR, f"preflight failed unexpectedly ({type(error).__name__})")
        if report.blocked:
            return _result(PublicationOutcome.BLOCKED_PREFLIGHT, report.render())

        try:
            dependencies.summary(repo_root, config_path)
            staged = dependencies.draft.stage(repo_root, config_path, dependencies.lock, report)
            if staged.state is MutationState.PREFLIGHT_BLOCKED:
                return _result(PublicationOutcome.BLOCKED_PREFLIGHT, staged.message)
            if staged.state is MutationState.ROLLED_BACK:
                return _result(PublicationOutcome.ROLLED_BACK, staged.message, publication_record=staged.publication_record)
            if staged.state is MutationState.MANUAL_RECOVERY_REQUIRED:
                return _result(PublicationOutcome.MANUAL_RECOVERY_REQUIRED, staged.message, publication_record=staged.publication_record)
            if staged.state is not MutationState.STAGED_DRAFT_READY or staged.publication_record is None:
                return _result(PublicationOutcome.INTERNAL_ERROR, staged.message)

            record = staged.publication_record
            source = dependencies.pages_source.read(record)
            pages_stage = dependencies.content.stage(repo_root, config_path, staged, source)
            dependencies.release.verify_draft(record)
            transition_started = True
            release = dependencies.release.transition(record)
            public = True
            release = dependencies.release.verify_public(record)
            dependencies.pages_push.push(pages_stage, record)
            acceptance = dependencies.public.verify(record, pages_stage, release)
            evidence = dependencies.evidence.write(
                repo_root, record, pages_stage, release, acceptance, PublicationOutcome.PUBLISHED, "publication verified",
            )
            _cleanup_pages_workspace(pages_stage)
            return _result(
                PublicationOutcome.PUBLISHED,
                "GitHub prerelease, Pages feed, public resources, and evidence verified",
                publication_record=record,
                pages_stage=pages_stage,
                evidence_path=evidence,
            )
        except Exception as error:
            if not public and transition_started and staged is not None and staged.publication_record is not None:
                try:
                    public = dependencies.release.is_public(staged.publication_record)
                except Exception:
                    public = None
                if public is None:
                    _cleanup_pages_workspace(pages_stage)
                    return _result(
                        PublicationOutcome.MANUAL_RECOVERY_REQUIRED,
                        "release publication state is ambiguous; manual recovery required",
                        publication_record=staged.publication_record,
                        pages_stage=pages_stage,
                    )
            if not public and staged is not None and staged.state is MutationState.STAGED_DRAFT_READY:
                rollback_errors = _rollback_before_publication(dependencies.draft, staged, pages_stage)
                if rollback_errors:
                    return _result(
                        PublicationOutcome.MANUAL_RECOVERY_REQUIRED,
                        f"publication failed before public release; manual recovery required: {'; '.join(rollback_errors)}",
                        publication_record=staged.publication_record,
                    )
                return _result(
                    PublicationOutcome.ROLLED_BACK,
                    f"publication failed before public release ({type(error).__name__}); rollback completed",
                    publication_record=staged.publication_record,
                )

            if not public and staged is not None and staged.state is not MutationState.STAGED_DRAFT_READY:
                return _result(PublicationOutcome.INTERNAL_ERROR, f"publication failed before draft readiness ({type(error).__name__})")

            message = f"public release exists but publication completion failed ({type(error).__name__})"
            evidence_path = None
            if staged is not None and staged.publication_record is not None and pages_stage is not None:
                try:
                    evidence_path = dependencies.evidence.write(
                        repo_root, staged.publication_record, pages_stage,
                        release if "release" in locals() else PublishedRelease("", None),
                        None, PublicationOutcome.INCOMPLETE_PUBLICATION, message,
                    )
                except Exception:
                    message += "; diagnostic evidence could not be written"
            _cleanup_pages_workspace(pages_stage)
            return _result(
                PublicationOutcome.INCOMPLETE_PUBLICATION,
                message,
                publication_record=staged.publication_record if staged else None,
                pages_stage=pages_stage,
                evidence_path=evidence_path,
            )
    finally:
        dependencies.lock.release()


class DefaultDraftLifecycle:
    def __init__(self, dependencies: MutationDependencies, repo_root: Path) -> None:
        self.dependencies = dependencies
        self.repo_root = repo_root

    def stage(
        self, repo_root: Path, config_path: Path, lock: PublicationLock, preflight_report: PreflightReport
    ) -> MutationResult:
        return stage_draft(
            repo_root, config_path, self.dependencies, lock=lock, preflight_report=preflight_report
        )

    def rollback(self, staged: MutationResult) -> list[str]:
        return rollback_staged_draft(self.repo_root, staged, self.dependencies)


class DefaultPagesSource:
    def __init__(self, runner, http: HttpClient) -> None:
        self.runner = runner
        self.http = http

    def read(self, record) -> PagesSourceState:
        response = self.http.get(record.appcast_url, timeout=30)
        if response.status == 404:
            existing_appcast = None
        elif response.status == 200:
            existing_appcast = response.body
        else:
            raise PublicationError(FailureClass.APPCAST, f"existing appcast fetch returned HTTP {response.status}")

        remote = f"https://github.com/{record.github_repository}.git"
        result = self.runner.run(["git", "ls-remote", remote, "refs/heads/gh-pages"])
        if result.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "could not inspect the current gh-pages tip")
        lines = [line.split()[0] for line in result.stdout.splitlines() if line.split()]
        if len(lines) > 1:
            raise PublicationError(FailureClass.REPOSITORY, "gh-pages tip inspection returned multiple refs")
        tip = lines[0] if lines else None
        return PagesSourceState(existing_appcast, tip)


class DefaultContentStager:
    def __init__(self, runner, tools: ToolLocator) -> None:
        self.runner = runner
        self.tools = tools

    def stage(self, repo_root: Path, config_path: Path, staged: MutationResult, source: PagesSourceState) -> PagesStageResult:
        sign_update = self.tools.find("sign_update") or "sign_update"
        openssl = self.tools.find("openssl") or "openssl"
        signer = SignUpdateAdapter(self.runner, sign_update)
        verifier = SparkleSignatureVerifier(self.runner, sign_update, openssl)
        pages_git = LocalPagesGit(self.runner, f"https://github.com/{staged.publication_record.github_repository}.git")
        return stage_staged_draft_content(
            repo_root, config_path, staged, signer, verifier, pages_git,
            source.expected_previous_tip, source.existing_appcast, self.runner,
        )


class DefaultReleaseLifecycle:
    def __init__(self, github: GitHubMutation, http: HttpClient, repo_root: Path) -> None:
        self.github = github
        self.http = http
        self.repo_root = repo_root

    def _names(self, record) -> tuple[str, ...]:
        return tuple(asset.name for asset in record.assets) + (f"LinkGate-{record.marketing_version}.publish.json",)

    def _expected_bytes(self, record) -> dict[str, bytes]:
        expected = {
            asset.name: (self.repo_root / "dist" / asset.name).read_bytes()
            for asset in record.assets
        }
        expected[f"LinkGate-{record.marketing_version}.publish.json"] = record.to_json_bytes()
        return expected

    def verify_draft(self, record) -> None:
        self.github.verify_draft(
            record.github_repository, record.release_tag, record.github_title,
            self._names(record), self._expected_bytes(record),
        )

    def transition(self, record) -> PublishedRelease:
        details = self.github.transition_to_public(
            record.github_repository, record.release_tag, record.github_title, self._names(record),
            self._expected_bytes(record),
        )
        return PublishedRelease(
            details.get("url") or f"https://github.com/{record.github_repository}/releases/tag/{record.release_tag}",
            details.get("publishedAt"),
        )

    def is_public(self, record) -> bool | None:
        return self.github.public_state(record.github_repository, record.release_tag, record.github_title)

    def verify_public(self, record) -> PublishedRelease:
        details = self.github.verify_public(
            record.github_repository, record.release_tag, record.github_title, self._names(record)
        )
        dmg = next(asset for asset in record.assets if asset.name.endswith(".dmg"))
        dmg_url = f"https://github.com/{record.github_repository}/releases/download/{record.release_tag}/{dmg.name}"
        response = self.http.get(dmg_url, timeout=30)
        if response.status != 200 or hashlib.sha256(response.body).hexdigest() != dmg.sha256:
            raise PublicationError(FailureClass.TRUST, "public GitHub DMG is unavailable or does not match Step 6 bytes")
        return PublishedRelease(
            details.get("url") or f"https://github.com/{record.github_repository}/releases/tag/{record.release_tag}",
            details.get("publishedAt"),
        )


class DefaultPagesPusher:
    def __init__(self, runner) -> None:
        self.runner = runner

    def push(self, stage: PagesStageResult, record) -> None:
        remote = f"https://github.com/{record.github_repository}.git"
        ref = "refs/heads/gh-pages"
        tip = self.runner.run(["git", "ls-remote", remote, ref])
        if tip.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "could not verify gh-pages tip before push")
        lines = [line.split()[0] for line in tip.stdout.splitlines() if line.split()]
        current = lines[0] if lines else None
        if current != stage.expected_previous_tip:
            raise PublicationError(FailureClass.REPOSITORY, "gh-pages changed since staging")
        pushed = self.runner.run(["git", "push", remote, f"HEAD:{ref}"], cwd=stage.workspace)
        if pushed.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "gh-pages fast-forward push failed")
        final = self.runner.run(["git", "ls-remote", remote, ref])
        if final.returncode != 0 or not final.stdout.split() or final.stdout.split()[0] != stage.commit_sha:
            raise PublicationError(FailureClass.REPOSITORY, "remote gh-pages tip does not match staged commit")


class DefaultPublicVerifier:
    def __init__(self, config: PublicationConfig, http: HttpClient, sleeper: Callable[[float], None] = sleep) -> None:
        self.config = config
        self.http = http
        self.sleeper = sleeper

    def _get(self, url: str, predicate: Callable[[bytes], bool], failure_class: FailureClass, message: str) -> bytes:
        last = ""
        for attempt in range(self.config.verification_attempts):
            response = self.http.get(url, timeout=30)
            last = f"HTTP {response.status}"
            if response.status == 200 and predicate(response.body):
                return response.body
            if attempt + 1 < self.config.verification_attempts:
                self.sleeper(self.config.verification_interval_seconds)
        raise PublicationError(failure_class, f"{message} ({last})")

    def verify(self, record, stage: PagesStageResult, release: PublishedRelease) -> PublicAcceptance:
        from .appcast import parse_appcast

        expected_appcast_path = stage.workspace / "updates/appcast.xml"
        expected_notes_path = stage.workspace / "updates/releases" / f"{record.marketing_version}.html"
        expected_appcast = expected_appcast_path.read_bytes()
        expected_notes = expected_notes_path.read_bytes()
        dmg = next(asset for asset in record.assets if asset.name.endswith(".dmg"))
        dmg_url = github_release_asset_url(self.config, record.marketing_version, dmg.name)
        self._get(
            dmg_url,
            lambda body: hashlib.sha256(body).hexdigest() == dmg.sha256,
            FailureClass.TRUST,
            "public GitHub DMG does not match Step 6 bytes",
        )
        expected_feed = parse_appcast(expected_appcast)
        self._get(
            record.appcast_url,
            lambda body: _same_appcast(body, expected_feed),
            FailureClass.APPCAST,
            "public appcast does not match the staged feed",
        )
        notes_url = self.config.release_notes_url(record.marketing_version)
        self._get(
            notes_url,
            lambda body: body == expected_notes,
            FailureClass.RELEASE_NOTES,
            "public release notes do not match the staged HTML",
        )
        return PublicAcceptance(
            dmg_url=dmg_url,
            dmg_sha256=dmg.sha256,
            appcast_url=record.appcast_url,
            appcast_sha256=stage.appcast_sha256,
            release_notes_url=notes_url,
            release_notes_sha256=stage.release_notes_sha256,
        )


def _same_appcast(body: bytes, expected) -> bool:
    try:
        from .appcast import parse_appcast

        return parse_appcast(body) == expected
    except PublicationError:
        return False


class LocalEvidenceWriter:
    def write(self, repo_root, record, stage, release, acceptance, outcome, message) -> Path:
        root = repo_root / ".scratch" / "publication-evidence"
        root.mkdir(parents=True, exist_ok=True)
        destination = root / record.marketing_version
        if destination.exists():
            raise OSError("publication evidence already exists for this version")
        temporary = Path(tempfile.mkdtemp(prefix=f".{record.marketing_version}-", dir=root))
        try:
            (temporary / f"LinkGate-{record.marketing_version}.publish.json").write_bytes(record.to_json_bytes())
            shutil.copyfile(stage.workspace / "updates/appcast.xml", temporary / "appcast.xml")
            shutil.copyfile(
                stage.workspace / "updates/releases" / f"{record.marketing_version}.html",
                temporary / "release-notes.html",
            )
            acceptance_data = {
                "outcome": outcome.value,
                "message": message,
                "source_commit": record.source_commit,
                "marketing_version": record.marketing_version,
                "build": record.build,
                "tag": record.release_tag,
                "github_repository": record.github_repository,
                "github_release_url": release.url,
                "published_at": release.published_at,
                "publication_recorded_at": record.publication_recorded_at,
                "pages_commit_sha": stage.commit_sha,
                "appcast_sha256": stage.appcast_sha256,
                "release_notes_sha256": stage.release_notes_sha256,
                "acceptance": asdict(acceptance) if acceptance is not None else None,
            }
            (temporary / "acceptance.json").write_text(
                json.dumps(acceptance_data, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            temporary.replace(destination)
            return destination
        except Exception:
            shutil.rmtree(temporary, ignore_errors=True)
            raise


def default_dependencies(repo_root: Path, config_path: Path) -> OrchestrationDependencies:
    runner = SubprocessRunner()
    tools = DefaultToolLocator(runner)
    http = DefaultHttpClient()
    mutation_dependencies = MutationDependencies(runner=runner, tools=tools, http=http)
    config = None
    try:
        config = load_config(config_path)
    except PublicationError:
        pass
    gh_path = tools.find("gh") or "gh"
    release = DefaultReleaseLifecycle(GitHubMutation(runner, gh_path), http, repo_root)

    return OrchestrationDependencies(
        lock=PublicationLock(repo_root / ".linkgate-publish.lock"),
        preflight=lambda root, path: run_preflight(root, path, PreflightDependencies(runner=runner, tools=tools, http=http)),
        draft=DefaultDraftLifecycle(mutation_dependencies, repo_root),
        pages_source=DefaultPagesSource(runner, http),
        content=DefaultContentStager(runner, tools),
        release=release,
        pages_push=DefaultPagesPusher(runner),
        public=DefaultPublicVerifier(config, http) if config is not None else _UnavailablePublicVerifier(),
        evidence=LocalEvidenceWriter(),
        summary=_print_summary,
    )


class _UnavailablePublicVerifier:
    def verify(self, record, stage, release):
        raise PublicationError(FailureClass.CONFIGURATION, "publication configuration is unresolved")


def _print_summary(repo_root: Path, config_path: Path) -> None:
    summary = _summary(repo_root, config_path)
    print("PRE-MUTATION SUMMARY")
    for key in ("version", "build", "source_commit", "tag", "repository", "dmg_sha256", "prerelease"):
        print(f"{key}: {summary[key]}")


def main(argv: Sequence[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Publish a LinkGate beta release")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path, default=Path("scripts/release/publish-config.json"))
    arguments = parser.parse_args(argv)
    repo_root = arguments.repo_root.resolve()
    config_path = arguments.config if arguments.config.is_absolute() else repo_root / arguments.config
    result = orchestrate(repo_root, config_path, default_dependencies(repo_root, config_path))
    print(f"PUBLICATION: {result.outcome.value}")
    print(result.message)
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
