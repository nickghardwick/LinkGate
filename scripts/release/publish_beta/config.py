from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from .errors import FailureClass, PublicationError
from .models import validate_public_key


_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_MACOS_VERSION = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class PublicationConfig:
    schema_version: int
    repository: str
    product: str
    bundle_id: str
    team_id: str
    appcast_path: str
    release_notes_source_pattern: str
    release_notes_url_pattern: str
    appcast_url_pattern: str
    sparkle_version: str
    sparkle_keychain_account: str
    sparkle_public_key: str
    sparkle_archive_name: str
    sparkle_archive_url: str
    sparkle_archive_sha256: str
    sparkle_sign_update_path: str
    sparkle_sign_update_sha256: str
    verification_attempts: int
    verification_interval_seconds: int
    minimum_macos_version: str
    release_tag_pattern: str
    release_title_pattern: str
    prerelease: bool
    pages_branch: str
    pages_commit_author_name: str
    pages_commit_author_email: str

    @property
    def owner(self) -> str:
        return self.repository.split("/", 1)[0]

    @property
    def repo(self) -> str:
        return self.repository.split("/", 1)[1]

    def release_notes_source(self, version: str) -> str:
        return _expand(self.release_notes_source_pattern, version, self.owner, self.repo)

    def release_notes_url(self, version: str) -> str:
        return _expand(self.release_notes_url_pattern, version, self.owner, self.repo)

    def appcast_url(self) -> str:
        return _expand(self.appcast_url_pattern, "", self.owner, self.repo)

    def release_tag(self, version: str) -> str:
        return _expand(self.release_tag_pattern, version, self.owner, self.repo)

    def release_title(self, version: str) -> str:
        return _expand(self.release_title_pattern, version, self.owner, self.repo)


def _expand(pattern: str, version: str, owner: str, repo: str) -> str:
    try:
        expanded = pattern.format(version=version, owner=owner, repo=repo)
    except (KeyError, ValueError) as exc:
        raise PublicationError(FailureClass.CONFIGURATION, f"invalid publication pattern: {pattern!r}") from exc
    if "{" in expanded or "}" in expanded:
        raise PublicationError(FailureClass.CONFIGURATION, f"unexpanded publication pattern: {pattern!r}")
    return expanded


def load_config(path: Path) -> PublicationConfig:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PublicationError(FailureClass.CONFIGURATION, f"could not read publication config: {path}") from exc
    if not isinstance(value, dict):
        raise PublicationError(FailureClass.CONFIGURATION, "publication config must be a JSON object")

    required = {
        "schema_version", "repository", "product", "bundle_id", "team_id", "appcast_path",
        "release_notes_source_pattern", "release_notes_url_pattern", "appcast_url_pattern",
        "github_release", "sparkle", "verification", "minimum_macos_version", "pages",
    }
    if set(value) != required:
        raise PublicationError(FailureClass.CONFIGURATION, "publication config fields do not match schema version 1")
    if value["schema_version"] != 1:
        raise PublicationError(FailureClass.CONFIGURATION, "unsupported publication config schema version")

    repository = value["repository"]
    if not isinstance(repository, str) or repository in {"OWNER/REPO", "replace-me/linkgate"} or not _REPOSITORY.fullmatch(repository):
        raise PublicationError(FailureClass.CONFIGURATION, "publication repository is unresolved or invalid")

    strings = ("product", "bundle_id", "team_id", "appcast_path", "release_notes_source_pattern", "release_notes_url_pattern", "appcast_url_pattern", "minimum_macos_version")
    if any(not isinstance(value[key], str) or not value[key] for key in strings):
        raise PublicationError(FailureClass.CONFIGURATION, "publication config contains an empty string")
    if not value["appcast_path"].startswith("/") or ".." in Path(value["appcast_path"]).parts:
        raise PublicationError(FailureClass.CONFIGURATION, "appcast path must be absolute and traversal-free")
    if "{version}" not in value["release_notes_source_pattern"] or not value["release_notes_source_pattern"].endswith(".md"):
        raise PublicationError(FailureClass.CONFIGURATION, "release-note source pattern must contain {version} and end in .md")
    for key in ("release_notes_url_pattern", "appcast_url_pattern"):
        pattern = value[key]
        if not all(token in pattern for token in ("{owner}", "{repo}")):
            raise PublicationError(FailureClass.CONFIGURATION, f"{key} must contain owner and repo placeholders")
        parsed = urlparse(pattern.replace("{owner}", "owner").replace("{repo}", "repo").replace("{version}", "0.0.0"))
        if parsed.scheme != "https" or not parsed.netloc:
            raise PublicationError(FailureClass.CONFIGURATION, f"{key} must be an HTTPS URL pattern")

    github_release = value["github_release"]
    if not isinstance(github_release, dict) or set(github_release) != {"tag_pattern", "title_pattern", "prerelease"}:
        raise PublicationError(FailureClass.CONFIGURATION, "github_release config fields do not match schema")
    if not isinstance(github_release["tag_pattern"], str) or "{version}" not in github_release["tag_pattern"]:
        raise PublicationError(FailureClass.CONFIGURATION, "GitHub release tag pattern must contain {version}")
    if not isinstance(github_release["title_pattern"], str) or "{version}" not in github_release["title_pattern"]:
        raise PublicationError(FailureClass.CONFIGURATION, "GitHub release title pattern must contain {version}")
    if github_release["prerelease"] is not True:
        raise PublicationError(FailureClass.CONFIGURATION, "Step 7 releases must be prereleases")

    sparkle = value["sparkle"]
    verification = value["verification"]
    if not isinstance(sparkle, dict) or set(sparkle) != {"version", "keychain_account", "public_key", "distribution"}:
        raise PublicationError(FailureClass.CONFIGURATION, "sparkle config fields do not match schema")
    if sparkle["version"] != "2.9.6":
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle version must be pinned to 2.9.6")
    keychain_account = sparkle["keychain_account"]
    if (
        not isinstance(keychain_account, str)
        or not keychain_account.strip()
        or keychain_account != keychain_account.strip()
        or keychain_account.startswith("REPLACE_")
    ):
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle Keychain account is unresolved or invalid")
    public_key = sparkle["public_key"]
    if public_key == "REPLACE_AFTER_ONE_TIME_KEY_SETUP":
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle public key is not configured")
    if not isinstance(public_key, str):
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle public key must be a string")
    distribution = sparkle["distribution"]
    distribution_keys = {"archive_name", "archive_url", "archive_sha256", "sign_update_path", "sign_update_sha256"}
    if not isinstance(distribution, dict) or set(distribution) != distribution_keys:
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle distribution provenance fields do not match schema")
    if distribution["archive_name"] != "Sparkle-2.9.6.tar.xz":
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle distribution archive must be Sparkle-2.9.6.tar.xz")
    archive_url = distribution["archive_url"]
    if archive_url != "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz":
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle distribution archive URL must be the official 2.9.6 release asset")
    if any(not isinstance(distribution[key], str) or not _SHA256.fullmatch(distribution[key]) for key in ("archive_sha256", "sign_update_sha256")):
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle distribution hashes must be lowercase SHA-256 values")
    if distribution["sign_update_path"] != "bin/sign_update":
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle sign_update path must be bin/sign_update")
    validate_public_key(public_key)
    if not isinstance(verification, dict) or set(verification) != {"attempts", "interval_seconds"}:
        raise PublicationError(FailureClass.CONFIGURATION, "verification config fields do not match schema")
    if not isinstance(verification["attempts"], int) or verification["attempts"] <= 0 or not isinstance(verification["interval_seconds"], int) or verification["interval_seconds"] < 0:
        raise PublicationError(FailureClass.CONFIGURATION, "verification policy must contain positive attempts and non-negative interval")
    if not _MACOS_VERSION.fullmatch(value["minimum_macos_version"]):
        raise PublicationError(FailureClass.CONFIGURATION, "minimum macOS version is invalid")
    pages = value["pages"]
    if not isinstance(pages, dict) or set(pages) != {"branch", "commit_author_name", "commit_author_email"}:
        raise PublicationError(FailureClass.CONFIGURATION, "pages config fields do not match schema")
    if pages["branch"] != "gh-pages" or any(not isinstance(pages[key], str) or not pages[key] for key in ("commit_author_name", "commit_author_email")):
        raise PublicationError(FailureClass.CONFIGURATION, "Pages branch or commit identity is invalid")

    return PublicationConfig(
        schema_version=1,
        repository=repository,
        product=value["product"],
        bundle_id=value["bundle_id"],
        team_id=value["team_id"],
        appcast_path=value["appcast_path"],
        release_notes_source_pattern=value["release_notes_source_pattern"],
        release_notes_url_pattern=value["release_notes_url_pattern"],
        appcast_url_pattern=value["appcast_url_pattern"],
        sparkle_version=sparkle["version"],
        sparkle_keychain_account=keychain_account,
        sparkle_public_key=public_key,
        sparkle_archive_name=distribution["archive_name"],
        sparkle_archive_url=archive_url,
        sparkle_archive_sha256=distribution["archive_sha256"],
        sparkle_sign_update_path=distribution["sign_update_path"],
        sparkle_sign_update_sha256=distribution["sign_update_sha256"],
        verification_attempts=verification["attempts"],
        verification_interval_seconds=verification["interval_seconds"],
        minimum_macos_version=value["minimum_macos_version"],
        release_tag_pattern=github_release["tag_pattern"],
        release_title_pattern=github_release["title_pattern"],
        prerelease=github_release["prerelease"],
        pages_branch=pages["branch"],
        pages_commit_author_name=pages["commit_author_name"],
        pages_commit_author_email=pages["commit_author_email"],
    )
