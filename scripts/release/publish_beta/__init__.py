"""Deterministic, offline-testable foundations for LinkGate publication."""

from .appcast import AppcastFeed, AppcastItem, parse_appcast, serialize_appcast
from .config import PublicationConfig, load_config
from .content import PublicationContent, build_appcast_item, merge_appcast, prepare_publication_content
from .errors import FailureClass, PublicationError
from .models import AssetFact, PublicationRecord, ReleaseIdentity, RenderedReleaseNotes
from .pages import LocalPagesGit, PagesStageResult, stage_pages
from .release_notes import render_release_notes, release_notes_source_path
from .sparkle import SignUpdateAdapter, SparkleSignature, SparkleSignatureVerifier, parse_sign_update_output, verify_openssl_capability
from .staging import stage_staged_draft_content
from .step6 import Step6Artifacts, Step6Manifest, discover_artifacts, load_manifest, validate_artifacts

__all__ = [
    "AppcastFeed",
    "AppcastItem",
    "AssetFact",
    "FailureClass",
    "PublicationConfig",
    "PublicationContent",
    "PublicationError",
    "PublicationRecord",
    "ReleaseIdentity",
    "RenderedReleaseNotes",
    "PagesStageResult",
    "LocalPagesGit",
    "SignUpdateAdapter",
    "SparkleSignature",
    "SparkleSignatureVerifier",
    "verify_openssl_capability",
    "Step6Artifacts",
    "Step6Manifest",
    "discover_artifacts",
    "load_manifest",
    "load_config",
    "build_appcast_item",
    "merge_appcast",
    "parse_sign_update_output",
    "prepare_publication_content",
    "parse_appcast",
    "release_notes_source_path",
    "render_release_notes",
    "serialize_appcast",
    "stage_pages",
    "stage_staged_draft_content",
    "validate_artifacts",
]
