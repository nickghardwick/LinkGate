from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

from .errors import FailureClass, PublicationError
from .models import AssetFact, parse_marketing_version


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_COMMIT = re.compile(r"^[0-9a-f]{40}$")


@dataclass(frozen=True)
class Step6Manifest:
    product: str
    marketing_version: str
    build: str
    bundle_id: str
    source_commit: str
    architectures: tuple[str, ...]
    deployment_target: str
    signing_identity: str
    notarized: bool
    stapled: bool
    xcode_version: str
    macos_version: str
    artifact_name: str
    sha256: str
    artifact_size: int | None = None


@dataclass(frozen=True)
class Step6Artifacts:
    manifest: Step6Manifest
    manifest_path: Path
    dmg_path: Path
    checksum_path: Path


def _error(message: str) -> PublicationError:
    return PublicationError(FailureClass.PROVENANCE, message)


def load_manifest(path: Path) -> Step6Manifest:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise _error(f"could not read Step 6 release manifest: {path}") from exc
    if not isinstance(value, dict):
        raise _error("Step 6 release manifest must be a JSON object")

    required = {
        "product", "marketing_version", "build", "bundle_id", "source_commit",
        "architectures", "deployment_target", "signing_identity", "notarized",
        "stapled", "xcode_version", "macos_version", "artifact_name", "sha256",
    }
    if set(value) - required - {"artifact_size", "size"} or not required.issubset(value):
        raise _error("Step 6 release manifest fields do not match the expected schema")
    try:
        version = value["marketing_version"]
        build = value["build"]
        parse_marketing_version(version)
        if not isinstance(build, str) or not build.isdigit():
            raise ValueError("invalid build")
        source_commit = value["source_commit"]
        if not isinstance(source_commit, str) or not _COMMIT.fullmatch(source_commit):
            raise ValueError("invalid source commit")
        architectures = value["architectures"]
        if not isinstance(architectures, list) or not architectures or any(not isinstance(item, str) or not item for item in architectures):
            raise ValueError("invalid architectures")
        if not all(isinstance(value[key], str) and value[key] for key in (
            "product", "bundle_id", "deployment_target", "signing_identity", "xcode_version", "macos_version", "artifact_name", "sha256"
        )):
            raise ValueError("empty manifest value")
        if not _SHA256.fullmatch(value["sha256"]):
            raise ValueError("invalid hash")
        artifact_name = value["artifact_name"]
        if Path(artifact_name).name != artifact_name or artifact_name != f"LinkGate-{version}.dmg":
            raise ValueError("artifact name does not match version")
        if not isinstance(value["notarized"], bool) or not isinstance(value["stapled"], bool) or not value["notarized"] or not value["stapled"]:
            raise ValueError("artifact is not notarized and stapled")
        artifact_size = value.get("artifact_size", value.get("size"))
        if artifact_size is not None and (not isinstance(artifact_size, int) or artifact_size < 0):
            raise ValueError("invalid artifact size")
    except (KeyError, TypeError, ValueError) as exc:
        raise _error(f"invalid Step 6 release manifest: {exc}") from exc

    return Step6Manifest(
        product=value["product"], marketing_version=version, build=build,
        bundle_id=value["bundle_id"], source_commit=source_commit,
        architectures=tuple(architectures), deployment_target=value["deployment_target"],
        signing_identity=value["signing_identity"], notarized=value["notarized"],
        stapled=value["stapled"], xcode_version=value["xcode_version"],
        macos_version=value["macos_version"], artifact_name=artifact_name,
        sha256=value["sha256"], artifact_size=artifact_size,
    )


def discover_artifacts(repo_root: Path, manifest: Step6Manifest) -> Step6Artifacts:
    dist = repo_root / "dist"
    manifest_path = dist / f"LinkGate-{manifest.marketing_version}.release.json"
    dmg_path = dist / manifest.artifact_name
    checksum_path = dist / f"{manifest.artifact_name}.sha256"
    if not manifest_path.is_file() or not dmg_path.is_file() or not checksum_path.is_file():
        missing = [str(path.relative_to(repo_root)) for path in (manifest_path, dmg_path, checksum_path) if not path.is_file()]
        raise PublicationError(FailureClass.ARTIFACT, f"missing canonical Step 6 artifact(s): {', '.join(missing)}")
    return Step6Artifacts(manifest, manifest_path, dmg_path, checksum_path)


def _checksum(path: Path, artifact_name: str) -> str:
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, UnicodeDecodeError) as exc:
        raise PublicationError(FailureClass.ARTIFACT, f"could not read checksum file: {path}") from exc
    if len(lines) != 1:
        raise PublicationError(FailureClass.ARTIFACT, "checksum file must contain exactly one entry")
    fields = lines[0].split()
    if len(fields) != 2 or fields[1] != artifact_name or not _SHA256.fullmatch(fields[0]):
        raise PublicationError(FailureClass.ARTIFACT, "checksum file is malformed or names the wrong DMG")
    return fields[0]


def validate_artifacts(artifacts: Step6Artifacts) -> AssetFact:
    manifest = artifacts.manifest
    checksum = _checksum(artifacts.checksum_path, manifest.artifact_name)
    actual_size = artifacts.dmg_path.stat().st_size
    actual_hash = hashlib.sha256(artifacts.dmg_path.read_bytes()).hexdigest()
    if checksum != actual_hash or manifest.sha256 != actual_hash:
        raise PublicationError(FailureClass.ARTIFACT, "DMG SHA-256 does not agree with the checksum file and manifest")
    if manifest.artifact_size is not None and manifest.artifact_size != actual_size:
        raise PublicationError(FailureClass.ARTIFACT, "DMG size does not match the Step 6 manifest")
    return AssetFact(manifest.artifact_name, actual_size, actual_hash)
