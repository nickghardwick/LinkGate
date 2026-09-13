from __future__ import annotations

import base64
import json
import re
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any

from .errors import FailureClass, PublicationError


_MARKETING_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
_COMMIT = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def parse_marketing_version(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not _MARKETING_VERSION.fullmatch(value):
        raise PublicationError(FailureClass.CONFIGURATION, f"invalid marketing version: {value!r}")
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


@dataclass(frozen=True)
class ReleaseIdentity:
    product: str
    marketing_version: str
    build_version: str
    bundle_id: str
    deployment_target: str

    def __post_init__(self) -> None:
        parse_marketing_version(self.marketing_version)
        if not self.build_version.isdigit():
            raise PublicationError(FailureClass.CONFIGURATION, "build version must contain only digits")
        if not self.product or not self.bundle_id or not self.deployment_target:
            raise PublicationError(FailureClass.CONFIGURATION, "release identity contains an empty value")

    @property
    def build_number(self) -> int:
        return int(self.build_version)


@dataclass(frozen=True)
class AssetFact:
    name: str
    size: int
    sha256: str

    def __post_init__(self) -> None:
        if not self.name or self.name in {".", ".."} or "/" in self.name or "\\" in self.name:
            raise PublicationError(FailureClass.CONFIGURATION, f"invalid asset name: {self.name!r}")
        if self.size < 0 or not _SHA256.fullmatch(self.sha256):
            raise PublicationError(FailureClass.CONFIGURATION, f"invalid asset facts for {self.name!r}")


@dataclass(frozen=True)
class RenderedReleaseNotes:
    version: str
    source_sha256: str
    template: bytes
    html_bytes: bytes

    def __post_init__(self) -> None:
        parse_marketing_version(self.version)
        if not self.template:
            raise PublicationError(FailureClass.RELEASE_NOTES, "invalid release-note template")


@dataclass(frozen=True)
class PublicationRecord:
    product: str
    marketing_version: str
    build: str
    source_commit: str
    release_tag: str
    github_repository: str
    github_title: str
    prerelease: bool
    assets: tuple[AssetFact, ...]
    release_manifest_sha256: str
    appcast_url: str
    publication_recorded_at: str

    def __post_init__(self) -> None:
        parse_marketing_version(self.marketing_version)
        if not self.build.isdigit() or not _COMMIT.fullmatch(self.source_commit):
            raise PublicationError(FailureClass.CONFIGURATION, "invalid publication record version or source commit")
        if not _SHA256.fullmatch(self.release_manifest_sha256):
            raise PublicationError(FailureClass.CONFIGURATION, "invalid release manifest hash")
        if not self.release_tag or not self.github_repository or not self.github_title or not self.appcast_url:
            raise PublicationError(FailureClass.CONFIGURATION, "publication record contains an empty value")

    def to_json_bytes(self) -> bytes:
        value: dict[str, Any] = asdict(self)
        value["assets"] = [asdict(asset) for asset in self.assets]
        return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def validate_public_key(value: str) -> None:
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle public key must be valid base64") from exc
    if len(decoded) != 32:
        raise PublicationError(FailureClass.CONFIGURATION, "Sparkle public key must decode to 32 bytes")
