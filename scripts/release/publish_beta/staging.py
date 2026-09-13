from __future__ import annotations

from pathlib import Path

from .config import load_config
from .content import prepare_publication_content
from .errors import FailureClass, PublicationError
from .mutation import MutationResult, MutationState
from .pages import PagesGit, PagesStageResult, stage_pages
from .preflight import CommandRunner, SubprocessRunner
from .sparkle import SignatureVerifier, SignUpdateAdapter
from .step6 import discover_artifacts, validate_artifacts
from .release_notes import release_notes_source_path


def stage_staged_draft_content(
    repo_root: Path,
    config_path: Path,
    staged: MutationResult,
    signer: SignUpdateAdapter,
    verifier: SignatureVerifier,
    pages_git: PagesGit,
    expected_previous_pages_tip: str | None,
    existing_appcast: bytes | None,
    runner: CommandRunner | None = None,
) -> PagesStageResult:
    """Prepare signed update content and a local Pages commit for a D7 draft."""
    if staged.state is not MutationState.STAGED_DRAFT_READY or staged.publication_record is None:
        raise PublicationError(FailureClass.REPOSITORY, "Step 7D must produce a verified staged draft first")
    config = load_config(config_path)
    record = staged.publication_record
    artifacts = discover_artifacts(repo_root, record_to_manifest(record, repo_root))
    validate_artifacts(artifacts)
    notes_path = release_notes_source_path(repo_root, config, record.marketing_version)
    if not notes_path.is_file():
        raise PublicationError(FailureClass.RELEASE_NOTES, "candidate release-note source is missing")
    content = prepare_publication_content(
        config, record, artifacts, notes_path, signer, verifier, existing_appcast
    )
    return stage_pages(
        config,
        content.appcast_xml,
        content.release_notes_html,
        record.marketing_version,
        record.build,
        record.publication_recorded_at,
        expected_previous_pages_tip,
        pages_git,
        runner or SubprocessRunner(),
    )


def record_to_manifest(record, repo_root: Path):
    """Load the authoritative Step 6 manifest selected by the staged record."""
    from .step6 import load_manifest

    path = repo_root / "dist" / f"LinkGate-{record.marketing_version}.release.json"
    manifest = load_manifest(path)
    if manifest.build != record.build or manifest.source_commit != record.source_commit:
        raise PublicationError(FailureClass.PROVENANCE, "Step 6 manifest does not match staged publication provenance")
    return manifest
