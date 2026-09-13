from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .appcast import AppcastFeed, AppcastItem, parse_appcast, serialize_appcast
from .config import PublicationConfig
from .errors import FailureClass, PublicationError
from .models import PublicationRecord
from .release_notes import render_release_notes
from .sparkle import SignatureVerifier, SignUpdateAdapter, SparkleSignature
from .step6 import Step6Artifacts


@dataclass(frozen=True)
class PublicationContent:
    release_notes_html: bytes
    appcast_xml: bytes
    signature: SparkleSignature


def _publication_time(record: PublicationRecord) -> datetime:
    value = record.publication_recorded_at.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as error:
        raise PublicationError(FailureClass.APPCAST, "publication timestamp is not ISO-8601") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise PublicationError(FailureClass.APPCAST, "publication timestamp must include a timezone")
    return parsed


def github_release_asset_url(config: PublicationConfig, version: str, name: str) -> str:
    return f"https://github.com/{config.repository}/releases/download/{config.release_tag(version)}/{name}"


def build_appcast_item(
    config: PublicationConfig,
    record: PublicationRecord,
    artifacts: Step6Artifacts,
    signature: SparkleSignature,
) -> AppcastItem:
    if signature.length != artifacts.dmg_path.stat().st_size:
        raise PublicationError(FailureClass.APPCAST, "Sparkle signature length does not match the Step 6 DMG")
    version = record.marketing_version
    dmg_name = artifacts.dmg_path.name
    if record.github_repository != config.repository or record.release_tag != config.release_tag(version):
        raise PublicationError(FailureClass.PROVENANCE, "staged release identity does not match publication configuration")
    return AppcastItem(
        title=record.github_title,
        product_url=f"https://github.com/{config.repository}",
        marketing_version=version,
        build_version=record.build,
        minimum_system_version=artifacts.manifest.deployment_target,
        release_notes_url=config.release_notes_url(version),
        enclosure_url=github_release_asset_url(config, version, dmg_name),
        enclosure_length=signature.length,
        ed_signature=signature.ed_signature,
        publication_recorded_at=_publication_time(record),
    )


def _initial_feed(config: PublicationConfig, item: AppcastItem) -> AppcastFeed:
    return AppcastFeed(
        channel_title=f"{config.product} Beta",
        channel_link=f"https://github.com/{config.repository}",
        channel_description=f"{config.product} beta updates",
        items=(item,),
    )


def merge_appcast(config: PublicationConfig, existing: bytes | None, item: AppcastItem) -> bytes:
    if existing is None:
        return serialize_appcast(_initial_feed(config, item))
    feed = parse_appcast(existing)
    candidate_marketing = tuple(int(part) for part in item.marketing_version.split("."))
    historical_marketing = [tuple(int(part) for part in old.marketing_version.split(".")) for old in feed.items]
    historical_builds = [int(old.build_version) for old in feed.items]
    if item.marketing_version in {old.marketing_version for old in feed.items}:
        raise PublicationError(FailureClass.APPCAST, "candidate marketing version already exists in appcast")
    if item.build_version in {old.build_version for old in feed.items}:
        raise PublicationError(FailureClass.APPCAST, "candidate build already exists in appcast")
    if historical_marketing and candidate_marketing <= max(historical_marketing):
        raise PublicationError(FailureClass.APPCAST, "candidate marketing version is not newer than appcast history")
    if historical_builds and int(item.build_version) <= max(historical_builds):
        raise PublicationError(FailureClass.APPCAST, "candidate build is not newer than appcast history")
    return serialize_appcast(
        AppcastFeed(feed.channel_title, feed.channel_link, feed.channel_description, (item, *feed.items))
    )


def prepare_publication_content(
    config: PublicationConfig,
    record: PublicationRecord,
    artifacts: Step6Artifacts,
    notes_source: Path,
    signer: SignUpdateAdapter,
    verifier: SignatureVerifier,
    existing_appcast: bytes | None,
) -> PublicationContent:
    before_hash = hashlib.sha256(artifacts.dmg_path.read_bytes()).hexdigest()
    if before_hash != artifacts.manifest.sha256:
        raise PublicationError(FailureClass.ARTIFACT, "canonical Step 6 DMG hash does not match its manifest")
    recorded_dmg = next((asset for asset in record.assets if asset.name == artifacts.dmg_path.name), None)
    if recorded_dmg is None or recorded_dmg.sha256 != before_hash or recorded_dmg.size != artifacts.dmg_path.stat().st_size:
        raise PublicationError(FailureClass.PROVENANCE, "staged DMG facts do not match the canonical Step 6 artifact")
    rendered = render_release_notes(notes_source.read_bytes(), version=record.marketing_version)
    signature = signer.sign(artifacts.dmg_path)
    if hashlib.sha256(artifacts.dmg_path.read_bytes()).hexdigest() != before_hash:
        raise PublicationError(FailureClass.ARTIFACT, "canonical Step 6 DMG changed during Sparkle signing")
    verifier.verify(artifacts.dmg_path, signature, config.sparkle_public_key)
    item = build_appcast_item(config, record, artifacts, signature)
    return PublicationContent(rendered.html_bytes, merge_appcast(config, existing_appcast, item), signature)
