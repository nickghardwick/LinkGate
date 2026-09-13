from __future__ import annotations

import hashlib
import json
import fcntl
import shutil
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Callable, Mapping, Sequence

from .config import PublicationConfig, load_config
from .errors import FailureClass, PublicationError
from .models import AssetFact, PublicationRecord
from .preflight import (
    CommandResult,
    CommandRunner,
    DefaultToolLocator,
    HttpClient,
    PreflightDependencies,
    PreflightReport,
    SubprocessRunner,
    ToolLocator,
    GitHubReadOnly,
    _manifest_path,
    run_preflight,
)
from .release_notes import release_notes_source_path
from .step6 import discover_artifacts, load_manifest, validate_artifacts


class MutationState(str, Enum):
    PREFLIGHT_BLOCKED = "PREFLIGHT_BLOCKED"
    STAGED_DRAFT_READY = "STAGED_DRAFT_READY"
    ROLLED_BACK = "ROLLED_BACK"
    MANUAL_RECOVERY_REQUIRED = "MANUAL_RECOVERY_REQUIRED"
    INTERNAL_ERROR = "INTERNAL_ERROR"


@dataclass(frozen=True)
class MutationResult:
    state: MutationState
    message: str
    publication_record: PublicationRecord | None = None
    ownership: InvocationOwnership | None = None


@dataclass
class InvocationOwnership:
    repository: str
    tag: str
    expected_commit: str
    title: str
    local_tag_created: bool = False
    remote_tag_created: bool = False
    draft_release_created: bool = False
    workspace: Path | None = None


class MutationFailure(Exception):
    def __init__(self, stage: str, message: str, failure_class: FailureClass = FailureClass.GITHUB):
        super().__init__(message)
        self.stage = stage
        self.failure_class = failure_class


@dataclass
class MutationDependencies:
    runner: CommandRunner = field(default_factory=SubprocessRunner)
    tools: ToolLocator | None = None
    http: HttpClient | None = None
    preflight: Callable[..., PreflightReport] = run_preflight
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    workspace_factory: Callable[[], str] = lambda: tempfile.mkdtemp(prefix="linkgate-publish-")

    def __post_init__(self) -> None:
        if self.tools is None:
            self.tools = DefaultToolLocator(self.runner)

    def preflight_dependencies(self) -> PreflightDependencies:
        if self.http is None:
            return PreflightDependencies(runner=self.runner, tools=self.tools)
        return PreflightDependencies(runner=self.runner, tools=self.tools, http=self.http)


def _failure(stage: str, result: CommandResult, failure_class: FailureClass = FailureClass.GITHUB) -> MutationFailure:
    return MutationFailure(stage, f"command failed during {stage} (exit {result.returncode})", failure_class)


class GitTagMutation:
    def __init__(self, runner: CommandRunner):
        self.runner = runner

    def local_commit(self, repo_root: Path, tag: str) -> str | None:
        result = self.runner.run(["git", "rev-parse", "--verify", f"{tag}^{{}}"], cwd=repo_root)
        if result.returncode != 0:
            return None
        value = result.stdout.strip()
        return value or None

    def create_local(self, repo_root: Path, tag: str, commit: str, title: str) -> None:
        if self.local_commit(repo_root, tag) is not None:
            raise MutationFailure("local tag creation", "intended local tag already exists", FailureClass.REPOSITORY)
        result = self.runner.run(
            ["git", "tag", "--annotate", tag, commit, "--message", title], cwd=repo_root
        )
        if result.returncode != 0:
            raise _failure("local tag creation", result, FailureClass.REPOSITORY)
        if self.local_commit(repo_root, tag) != commit:
            raise MutationFailure("local tag verification", "local tag does not resolve to the Step 6 source commit", FailureClass.REPOSITORY)

    def push(self, repository: str, tag: str) -> None:
        url = f"https://github.com/{repository}.git"
        result = self.runner.run(["git", "push", url, f"refs/tags/{tag}:refs/tags/{tag}"])
        if result.returncode != 0:
            raise _failure("remote tag push", result, FailureClass.REPOSITORY)

    def delete_local_if_owned(self, repo_root: Path, ownership: InvocationOwnership) -> None:
        if not ownership.local_tag_created:
            return
        if self.local_commit(repo_root, ownership.tag) != ownership.expected_commit:
            raise MutationFailure("local tag rollback", "local tag identity changed; manual recovery required", FailureClass.REPOSITORY)
        result = self.runner.run(["git", "tag", "--delete", ownership.tag], cwd=repo_root)
        if result.returncode != 0:
            raise _failure("local tag rollback", result, FailureClass.REPOSITORY)


class GitHubMutation(GitHubReadOnly):
    """The staging-only mutation surface; it has no release-publish or Pages methods."""

    def remote_tag_commit(self, repository: str, tag: str) -> str | None:
        result = self.tag(repository, tag)
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).lower()
            if "not found" in detail or "404" in detail:
                return None
            raise _failure("remote tag verification", result, FailureClass.GITHUB)
        try:
            payload = json.loads(result.stdout)
            object_data = payload["object"]
            object_type = object_data["type"]
            object_sha = object_data["sha"]
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise MutationFailure("remote tag verification", "GitHub returned an unusable tag response") from error
        if object_type == "commit":
            return object_sha
        if object_type != "tag":
            raise MutationFailure("remote tag verification", "remote tag does not resolve to a commit")
        tag_object = self.runner.run([
            self.gh_path, "api", "--method", "GET", f"repos/{repository}/git/tags/{object_sha}"
        ])
        if tag_object.returncode != 0:
            raise _failure("remote tag verification", tag_object, FailureClass.GITHUB)
        try:
            return json.loads(tag_object.stdout)["object"]["sha"]
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise MutationFailure("remote tag verification", "GitHub returned an unusable annotated tag response") from error

    def create_draft(self, repository: str, tag: str, title: str, notes_path: Path) -> None:
        result = self.runner.run([
            self.gh_path, "release", "create", tag, "--repo", repository,
            "--title", title, "--draft", "--prerelease", "--verify-tag",
            "--notes-file", str(notes_path),
        ])
        if result.returncode != 0:
            raise _failure("draft release creation", result)

    def details(self, repository: str, tag: str) -> dict:
        result = self.runner.run([
            self.gh_path, "release", "view", tag, "--repo", repository,
            "--json", "tagName,name,isDraft,isPrerelease,assets,url,publishedAt",
        ])
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).lower()
            if "not found" in detail or "404" in detail:
                raise MutationFailure("draft release verification", "draft release is absent")
            raise _failure("draft release verification", result)
        try:
            value = json.loads(result.stdout)
        except (TypeError, ValueError, json.JSONDecodeError) as error:
            raise MutationFailure("draft release verification", "GitHub returned invalid release metadata") from error
        if not isinstance(value, dict):
            raise MutationFailure("draft release verification", "GitHub returned invalid release metadata")
        return value

    def verify_draft(
        self,
        repository: str,
        tag: str,
        title: str,
        expected_assets: Sequence[str],
        expected_bytes: Mapping[str, bytes] | None = None,
    ) -> dict:
        details = self.details(repository, tag)
        _verify_draft_assets(details, expected_assets, tag, title)
        if expected_bytes is not None:
            self._verify_asset_bytes(repository, tag, expected_bytes)
        return details

    def verify_public(self, repository: str, tag: str, title: str, expected_assets: Sequence[str]) -> dict:
        details = self.details(repository, tag)
        if (
            not _release_identity_matches(details, tag, title)
            or details.get("isDraft") is not False
            or details.get("isPrerelease") is not True
        ):
            raise MutationFailure("public release verification", "public release metadata does not match the staging contract")
        _verify_asset_names(details, expected_assets, "public release verification")
        return details

    def transition_to_public(
        self,
        repository: str,
        tag: str,
        title: str,
        expected_assets: Sequence[str],
        expected_bytes: Mapping[str, bytes] | None = None,
    ) -> dict:
        self.verify_draft(repository, tag, title, expected_assets, expected_bytes)
        result = self.runner.run([
            self.gh_path, "release", "edit", tag, "--repo", repository,
            "--draft=false", "--prerelease=true",
        ])
        if result.returncode != 0:
            raise _failure("GitHub prerelease publication", result)
        details = self.details(repository, tag)
        if (
            details.get("tagName") != tag
            or details.get("name") != title
            or details.get("isDraft") is not False
            or details.get("isPrerelease") is not True
        ):
            raise MutationFailure("GitHub prerelease publication", "published release does not match the immutable release contract")
        _verify_asset_names(details, expected_assets, "public release verification")
        return details

    def public_state(self, repository: str, tag: str, title: str) -> bool | None:
        details = self.details(repository, tag)
        if details.get("tagName") != tag or details.get("name") != title:
            return False
        if details.get("isPrerelease") is not True:
            return False
        return details.get("isDraft") is False

    def upload(self, repository: str, tag: str, path: Path) -> None:
        result = self.runner.run([
            self.gh_path, "release", "upload", tag, str(path), "--repo", repository,
        ])
        if result.returncode != 0:
            raise _failure("release asset upload", result)

    def download(self, repository: str, tag: str, name: str, directory: Path) -> Path:
        result = self.runner.run([
            self.gh_path, "release", "download", tag, "--repo", repository,
            "--pattern", name, "--dir", str(directory),
        ])
        if result.returncode != 0:
            raise _failure("release asset read-back", result)
        path = directory / name
        if not path.is_file():
            raise MutationFailure("release asset read-back", f"downloaded asset is missing: {name}")
        return path

    def _verify_asset_bytes(self, repository: str, tag: str, expected: Mapping[str, bytes]) -> None:
        directory = Path(tempfile.mkdtemp(prefix="linkgate-draft-readback-"))
        try:
            for name, expected_bytes in expected.items():
                downloaded = self.download(repository, tag, name, directory)
                actual = downloaded.read_bytes()
                if actual != expected_bytes:
                    raise MutationFailure(
                        "draft asset read-back",
                        f"draft asset bytes do not match intended local bytes: {name}",
                    )
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def delete_draft_if_owned(self, repository: str, tag: str, title: str) -> None:
        details = self.details(repository, tag)
        if not _release_matches(details, tag, title):
            raise MutationFailure("draft release rollback", "draft release identity changed; manual recovery required")
        result = self.runner.run([
            self.gh_path, "release", "delete", tag, "--repo", repository,
            "--yes", "--cleanup-tag=false",
        ])
        if result.returncode != 0:
            raise _failure("draft release rollback", result)

    def delete_remote_tag_if_owned(self, repository: str, ownership: InvocationOwnership) -> None:
        if not ownership.remote_tag_created:
            return
        commit = self.remote_tag_commit(repository, ownership.tag)
        if commit != ownership.expected_commit:
            raise MutationFailure("remote tag rollback", "remote tag identity changed; manual recovery required", FailureClass.REPOSITORY)
        url = f"https://github.com/{repository}.git"
        result = self.runner.run(["git", "push", url, f":refs/tags/{ownership.tag}"])
        if result.returncode != 0:
            raise _failure("remote tag rollback", result, FailureClass.REPOSITORY)


def _release_matches(details: dict, tag: str, title: str) -> bool:
    return (
        _release_identity_matches(details, tag, title)
        and details.get("isDraft") is True
        and details.get("isPrerelease") is True
    )


def _release_identity_matches(details: dict, tag: str, title: str) -> bool:
    return details.get("tagName") == tag and details.get("name") == title


def _verify_asset_names(details: dict, expected: Sequence[str], stage: str) -> None:
    assets = details.get("assets")
    if not isinstance(assets, list) or {item.get("name") for item in assets if isinstance(item, dict)} != set(expected) or len(assets) != len(expected):
        raise MutationFailure(stage, "release does not contain exactly the expected assets")


def _asset_fact(path: Path) -> AssetFact:
    data = path.read_bytes()
    return AssetFact(path.name, len(data), hashlib.sha256(data).hexdigest())


def _verify_remote_asset(github: GitHubMutation, repository: str, tag: str, source: Path, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    downloaded = github.download(repository, tag, source.name, directory)
    expected = source.read_bytes()
    actual = downloaded.read_bytes()
    if actual != expected or hashlib.sha256(actual).hexdigest() != hashlib.sha256(expected).hexdigest():
        raise MutationFailure("release asset read-back", f"remote asset bytes do not match local asset: {source.name}")


def _verify_draft_assets(details: dict, expected: Sequence[str], tag: str, title: str) -> None:
    if not _release_matches(details, tag, title):
        raise MutationFailure("draft release verification", "draft release metadata does not match the staging contract")
    _verify_asset_names(details, expected, "draft release verification")


def _rollback(
    repo_root: Path,
    github: GitHubMutation,
    tags: GitTagMutation,
    ownership: InvocationOwnership,
    workspace: Path | None,
) -> list[str]:
    errors: list[str] = []
    release_removed = not ownership.draft_release_created
    if ownership.draft_release_created:
        try:
            github.delete_draft_if_owned(ownership.repository, ownership.tag, ownership.title)
            release_removed = True
        except MutationFailure as error:
            errors.append(str(error))
    if release_removed:
        try:
            github.delete_remote_tag_if_owned(ownership.repository, ownership)
        except MutationFailure as error:
            errors.append(str(error))
        try:
            tags.delete_local_if_owned(repo_root, ownership)
        except MutationFailure as error:
            errors.append(str(error))
    else:
        errors.append("tag cleanup stopped because the draft release could not be safely removed")
    if workspace is not None and workspace.exists():
        try:
            shutil.rmtree(workspace)
        except OSError as error:
            errors.append(f"workspace cleanup failed ({type(error).__name__})")
    return errors


def _result_after_failure(
    message: str,
    rollback_errors: list[str],
    publication_record: PublicationRecord | None = None,
) -> MutationResult:
    if rollback_errors:
        return MutationResult(
            MutationState.MANUAL_RECOVERY_REQUIRED,
            f"{message}; manual recovery required: {'; '.join(rollback_errors)}",
            publication_record,
        )
    return MutationResult(MutationState.ROLLED_BACK, f"{message}; rollback completed", publication_record)


class PublicationLock:
    def __init__(self, path: Path):
        self.path = path
        self.handle = None

    def acquire(self) -> None:
        self.handle = self.path.open("a+")
        try:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.handle.close()
            self.handle = None
            raise MutationFailure("publication lock", "another LinkGate publication invocation is active", FailureClass.REPOSITORY)

    def release(self) -> None:
        if self.handle is not None:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()
            self.handle = None


def _stage_draft(
    repo_root: Path,
    config_path: Path,
    dependencies: MutationDependencies,
    preflight_report: PreflightReport | None = None,
) -> MutationResult:
    preflight = preflight_report or dependencies.preflight(repo_root, config_path, dependencies.preflight_dependencies())
    if preflight.blocked:
        return MutationResult(MutationState.PREFLIGHT_BLOCKED, "read-only preflight is blocked; no mutation attempted")

    try:
        if preflight.context is not None:
            context = preflight.context
            config = context.config
            manifest = context.manifest
            artifacts = context.artifacts
            notes_path = context.release_notes_path
        else:
            config = load_config(config_path)
            manifest_path = _manifest_path(repo_root)
            if manifest_path is None:
                raise PublicationError(FailureClass.PROVENANCE, "canonical Step 6 release manifest is missing")
            manifest = load_manifest(manifest_path)
            artifacts = discover_artifacts(repo_root, manifest)
            validate_artifacts(artifacts)
            notes_path = release_notes_source_path(repo_root, config, manifest.marketing_version)
            if not notes_path.is_file():
                raise PublicationError(FailureClass.RELEASE_NOTES, "canonical release notes are missing")
        asset_paths = (artifacts.dmg_path, artifacts.checksum_path, artifacts.manifest_path)
        asset_facts = tuple(_asset_fact(path) for path in asset_paths)
        tag = config.release_tag(manifest.marketing_version)
        title = config.release_title(manifest.marketing_version)
        timestamp = dependencies.clock().astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    except (PublicationError, OSError) as error:
        return MutationResult(MutationState.PREFLIGHT_BLOCKED, f"publication inputs changed after preflight: {type(error).__name__}")

    tools = dependencies.tools
    if tools is None:
        return MutationResult(MutationState.INTERNAL_ERROR, "mutation tooling dependencies are unavailable")
    gh_path = tools.find("gh")
    if gh_path is None:
        return MutationResult(MutationState.PREFLIGHT_BLOCKED, "gh is unavailable after preflight")

    workspace = Path(dependencies.workspace_factory())
    ownership = InvocationOwnership(config.repository, tag, manifest.source_commit, title)
    ownership.workspace = workspace
    tags = GitTagMutation(dependencies.runner)
    github = GitHubMutation(dependencies.runner, gh_path)
    publication_record: PublicationRecord | None = None
    try:
        tags.create_local(repo_root, tag, manifest.source_commit, title)
        ownership.local_tag_created = True
        tags.push(config.repository, tag)
        if github.remote_tag_commit(config.repository, tag) != manifest.source_commit:
            raise MutationFailure("remote tag verification", "remote tag does not resolve to the Step 6 source commit", FailureClass.REPOSITORY)
        ownership.remote_tag_created = True

        github.create_draft(config.repository, tag, title, notes_path)
        details = github.details(config.repository, tag)
        if not _release_matches(details, tag, title):
            raise MutationFailure("draft release verification", "created release does not match the staging contract")
        ownership.draft_release_created = True

        for path in asset_paths:
            github.upload(config.repository, tag, path)
        expected_step6_names = tuple(path.name for path in asset_paths)
        details = github.details(config.repository, tag)
        _verify_draft_assets(details, expected_step6_names, tag, title)
        for index, path in enumerate(asset_paths):
            download_dir = workspace / f"readback-{index}"
            download_dir.mkdir()
            _verify_remote_asset(github, config.repository, tag, path, download_dir)

        publication_record = PublicationRecord(
            product=manifest.product,
            marketing_version=manifest.marketing_version,
            build=manifest.build,
            source_commit=manifest.source_commit,
            release_tag=tag,
            github_repository=config.repository,
            github_title=title,
            prerelease=True,
            assets=asset_facts,
            release_manifest_sha256=next(asset.sha256 for asset in asset_facts if asset.name == artifacts.manifest_path.name),
            appcast_url=config.appcast_url(),
            publication_recorded_at=timestamp,
        )
        publish_path = workspace / f"LinkGate-{manifest.marketing_version}.publish.json"
        publish_path.write_bytes(publication_record.to_json_bytes())
        github.upload(config.repository, tag, publish_path)
        _verify_remote_asset(github, config.repository, tag, publish_path, workspace / "readback-publish")
        expected_names = expected_step6_names + (publish_path.name,)
        _verify_draft_assets(github.details(config.repository, tag), expected_names, tag, title)
    except MutationFailure as error:
        rollback_errors: list[str] = []
        local_commit = tags.local_commit(repo_root, ownership.tag)
        if error.stage == "local tag verification" and not ownership.local_tag_created:
            if local_commit == ownership.expected_commit:
                ownership.local_tag_created = True
            elif local_commit is None:
                rollback_errors.append("local tag ownership could not be established; manual recovery required")
            else:
                rollback_errors.append("local tag identity could not be established; manual recovery required")
        elif error.stage == "local tag creation" and local_commit is not None:
            rollback_errors.append("local tag existed before mutation or ownership could not be established; manual recovery required")
        elif error.stage == "local tag verification" and not ownership.local_tag_created and local_commit is not None:
            rollback_errors.append("local tag identity could not be established; manual recovery required")
        if error.stage == "remote tag push":
            try:
                ambiguous_remote = github.remote_tag_commit(ownership.repository, ownership.tag)
            except MutationFailure:
                ambiguous_remote = None
                rollback_errors.append("remote tag ownership could not be established; manual recovery required")
            if ambiguous_remote is not None:
                rollback_errors.append("remote tag may have been created by a failed push; manual recovery required")
        elif not ownership.remote_tag_created:
            try:
                remote_commit = github.remote_tag_commit(ownership.repository, ownership.tag)
            except MutationFailure:
                rollback_errors.append("remote tag ownership could not be established; manual recovery required")
            else:
                if remote_commit == ownership.expected_commit:
                    ownership.remote_tag_created = True
                elif remote_commit is not None:
                    rollback_errors.append("remote tag identity could not be established; manual recovery required")
                elif error.stage == "remote tag verification":
                    rollback_errors.append("remote tag ownership could not be established; manual recovery required")
        if not ownership.draft_release_created:
            try:
                details = github.details(ownership.repository, ownership.tag)
                release_matches = _release_matches(details, ownership.tag, ownership.title)
                if release_matches and error.stage != "draft release creation":
                    ownership.draft_release_created = True
            except MutationFailure as release_error:
                if "absent" not in str(release_error):
                    rollback_errors.append("draft release ownership could not be established; manual recovery required")
            else:
                if error.stage == "draft release creation" or not release_matches:
                    rollback_errors.append("draft release identity could not be established; manual recovery required")
        errors = rollback_errors + _rollback(repo_root, github, tags, ownership, workspace)
        return _result_after_failure(f"staging failed during {error.stage}", errors, publication_record)
    except Exception as error:
        errors = _rollback(repo_root, github, tags, ownership, workspace)
        if errors:
            return MutationResult(MutationState.MANUAL_RECOVERY_REQUIRED, f"internal staging error; manual recovery required: {'; '.join(errors)}")
        return MutationResult(MutationState.INTERNAL_ERROR, f"internal staging error ({type(error).__name__}); rollback completed")

    try:
        shutil.rmtree(workspace)
    except OSError as error:
        return MutationResult(MutationState.MANUAL_RECOVERY_REQUIRED, f"draft is staged but workspace cleanup failed ({type(error).__name__})", publication_record)
    return MutationResult(
        MutationState.STAGED_DRAFT_READY,
        "draft prerelease staged and all four assets verified",
        publication_record,
        ownership,
    )


def stage_draft(
    repo_root: Path,
    config_path: Path,
    dependencies: MutationDependencies,
    lock: PublicationLock | None = None,
    preflight_report: PreflightReport | None = None,
) -> MutationResult:
    if lock is not None:
        return _stage_draft(repo_root, config_path, dependencies, preflight_report)
    lock = PublicationLock(repo_root / ".linkgate-publish.lock")
    try:
        lock.acquire()
    except MutationFailure as error:
        return MutationResult(MutationState.PREFLIGHT_BLOCKED, str(error))
    try:
        return _stage_draft(repo_root, config_path, dependencies, preflight_report)
    finally:
        lock.release()


def rollback_staged_draft(
    repo_root: Path,
    staged: MutationResult,
    dependencies: MutationDependencies,
) -> list[str]:
    """Roll back a successful draft staging invocation before public release."""
    if staged.ownership is None:
        return ["draft ownership was not recorded; manual recovery required"]
    tools = dependencies.tools
    if tools is None:
        return ["mutation tooling dependencies are unavailable; manual recovery required"]
    gh_path = tools.find("gh")
    if gh_path is None:
        return ["gh is unavailable for draft rollback; manual recovery required"]
    github = GitHubMutation(dependencies.runner, gh_path)
    tags = GitTagMutation(dependencies.runner)
    return _rollback(repo_root, github, tags, staged.ownership, staged.ownership.workspace)
