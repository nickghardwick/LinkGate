from __future__ import annotations

import hashlib
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence

from .appcast import parse_appcast
from .config import PublicationConfig
from .errors import FailureClass, PublicationError
from .preflight import CommandRunner, SubprocessRunner


@dataclass(frozen=True)
class PagesStageResult:
    state: str
    commit_sha: str
    expected_previous_tip: str | None
    bootstrap: bool
    appcast_sha256: str
    release_notes_sha256: str
    marketing_version: str
    build_version: str
    publication_recorded_at: str
    workspace: Path


class PagesGit(Protocol):
    def prepare(self, workspace: Path, expected_previous_tip: str | None, branch: str) -> None:
        ...


class LocalPagesGit:
    """Prepares a local Pages checkout; it has no push operation."""

    def __init__(self, runner: CommandRunner, remote_url: str) -> None:
        self.runner = runner
        self.remote_url = remote_url

    def prepare(self, workspace: Path, expected_previous_tip: str | None, branch: str) -> None:
        if expected_previous_tip is None:
            result = self.runner.run(["git", "init", "--initial-branch", branch, str(workspace)])
            if result.returncode != 0:
                raise PublicationError(FailureClass.REPOSITORY, "could not initialize Pages bootstrap workspace")
            return
        result = self.runner.run(
            ["git", "clone", "--no-checkout", "--branch", branch, self.remote_url, str(workspace)]
        )
        if result.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "could not read the existing Pages branch")
        tip = _git_output(self.runner, ["git", "rev-parse", "HEAD"], workspace)
        if tip != expected_previous_tip:
            raise PublicationError(FailureClass.REPOSITORY, "Pages branch changed from the expected tip")
        checkout = self.runner.run(["git", "checkout", "--detach", expected_previous_tip], cwd=workspace)
        if checkout.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "could not check out the expected Pages tip")


def _git_output(runner: CommandRunner, args: Sequence[str], cwd: Path) -> str:
    result = runner.run(args, cwd=cwd)
    if result.returncode != 0:
        raise PublicationError(FailureClass.REPOSITORY, "Pages Git inspection failed")
    return result.stdout.strip()


def _files(root: Path) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    for path in root.rglob("*"):
        if path.is_file() and ".git" not in path.relative_to(root).parts:
            result[str(path.relative_to(root))] = path.read_bytes()
    return result


def _expected_changes(before: dict[str, bytes], after: dict[str, bytes], version: str, bootstrap: bool) -> dict[str, str]:
    appcast = "updates/appcast.xml"
    notes = f"updates/releases/{version}.html"
    changed = {path for path in set(before) | set(after) if before.get(path) != after.get(path)}
    expected = {appcast: "A" if bootstrap else "M", notes: "A"}
    if changed != set(expected):
        raise PublicationError(FailureClass.REPOSITORY, "Pages staging changed paths outside the LinkGate update site")
    for path, status in expected.items():
        if status == "A" and path in before:
            raise PublicationError(FailureClass.REPOSITORY, f"Pages file already exists: {path}")
        if status == "M" and path not in before:
            raise PublicationError(FailureClass.REPOSITORY, f"Pages appcast is missing from existing history: {path}")
    return expected


def stage_pages(
    config: PublicationConfig,
    appcast_xml: bytes,
    release_notes_html: bytes,
    version: str,
    build: str,
    publication_recorded_at: str,
    expected_previous_tip: str | None,
    pages_git: PagesGit,
    runner: CommandRunner | None = None,
    workspace_factory=tempfile.mkdtemp,
) -> PagesStageResult:
    command_runner = runner or SubprocessRunner()
    parse_appcast(appcast_xml)
    workspace = Path(workspace_factory(prefix="linkgate-pages-"))
    bootstrap = expected_previous_tip is None
    try:
        pages_git.prepare(workspace, expected_previous_tip, config.pages_branch)
        before = _files(workspace)
        appcast_path = workspace / "updates/appcast.xml"
        notes_path = workspace / "updates/releases" / f"{version}.html"
        appcast_path.parent.mkdir(parents=True, exist_ok=True)
        notes_path.parent.mkdir(parents=True, exist_ok=True)
        appcast_path.write_bytes(appcast_xml)
        notes_path.write_bytes(release_notes_html)
        after = _files(workspace)
        expected = _expected_changes(before, after, version, bootstrap)

        add = command_runner.run(["git", "add", "--", "updates/appcast.xml", f"updates/releases/{version}.html"], cwd=workspace)
        if add.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "could not stage Pages update files")
        names = _git_output(command_runner, ["git", "diff", "--cached", "--name-status"], workspace)
        actual = {}
        for line in names.splitlines():
            status, path = line.split("\t", 1)
            actual[path] = status
        if actual != expected:
            raise PublicationError(FailureClass.REPOSITORY, "staged Pages diff does not match the exact update contract")

        commit = command_runner.run(
            [
                "git", "-c", f"user.name={config.pages_commit_author_name}",
                "-c", f"user.email={config.pages_commit_author_email}",
                "commit", "--message", f"Publish {config.product} {version} update feed",
            ], cwd=workspace,
        )
        if commit.returncode != 0:
            raise PublicationError(FailureClass.REPOSITORY, "could not create the local Pages commit")
        commit_sha = _git_output(command_runner, ["git", "rev-parse", "HEAD"], workspace)
        if len(commit_sha) != 40:
            raise PublicationError(FailureClass.REPOSITORY, "Pages commit did not return a full commit SHA")
        return PagesStageResult(
            state="PAGES_STAGE_READY",
            commit_sha=commit_sha,
            expected_previous_tip=expected_previous_tip,
            bootstrap=bootstrap,
            appcast_sha256=hashlib.sha256(appcast_xml).hexdigest(),
            release_notes_sha256=hashlib.sha256(release_notes_html).hexdigest(),
            marketing_version=version,
            build_version=build,
            publication_recorded_at=publication_recorded_at,
            workspace=workspace,
        )
    except Exception:
        shutil.rmtree(workspace, ignore_errors=True)
        raise
