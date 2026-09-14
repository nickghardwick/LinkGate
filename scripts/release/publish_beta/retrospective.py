from __future__ import annotations

import hashlib
import json
import tempfile
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Callable, Sequence

from .config import load_config
from .errors import FailureClass, PublicationError
from .models import AssetFact, PublicationRecord, parse_marketing_version
from .appcast import parse_appcast
from .orchestrator import DefaultPublicVerifier, PublishedRelease
from .pages import PagesStageResult
from .preflight import (
    DefaultHttpClient,
    DefaultToolLocator,
    GitHubReadOnly,
    HttpClient,
    SubprocessRunner,
    ToolLocator,
)
from .release_notes import release_notes_source_path, render_release_notes
from .sparkle import verify_openssl_capability, verify_sign_update
from .step6 import discover_artifacts, load_manifest, validate_artifacts


EXPECTED_ASSET_SUFFIXES = (".dmg", ".dmg.sha256", ".release.json")


def _error(message: str, failure_class: FailureClass = FailureClass.PROVENANCE) -> PublicationError:
    return PublicationError(failure_class, message)


def _published_record(data: dict, config, manifest, artifacts) -> PublicationRecord:
    try:
        assets = tuple(AssetFact(item["name"], item["size"], item["sha256"]) for item in data["assets"])
        record = PublicationRecord(
            product=data["product"],
            marketing_version=data["marketing_version"],
            build=data["build"],
            source_commit=data["source_commit"],
            release_tag=data["release_tag"],
            github_repository=data["github_repository"],
            github_title=data["github_title"],
            prerelease=data["prerelease"],
            assets=assets,
            release_manifest_sha256=data["release_manifest_sha256"],
            appcast_url=data["appcast_url"],
            publication_recorded_at=data["publication_recorded_at"],
        )
    except (KeyError, TypeError, ValueError, PublicationError) as error:
        raise _error("published provenance manifest is malformed") from error

    expected_names = tuple(f"LinkGate-{manifest.marketing_version}{suffix}" for suffix in EXPECTED_ASSET_SUFFIXES)
    dmg_fact = validate_artifacts(artifacts)
    expected_facts = {
        dmg_fact.name: dmg_fact,
        artifacts.checksum_path.name: AssetFact(
            artifacts.checksum_path.name,
            artifacts.checksum_path.stat().st_size,
            hashlib.sha256(artifacts.checksum_path.read_bytes()).hexdigest(),
        ),
        artifacts.manifest_path.name: AssetFact(
            artifacts.manifest_path.name,
            artifacts.manifest_path.stat().st_size,
            hashlib.sha256(artifacts.manifest_path.read_bytes()).hexdigest(),
        ),
    }
    if (
        record.product != config.product
        or record.marketing_version != manifest.marketing_version
        or record.build != manifest.build
        or record.source_commit != manifest.source_commit
        or record.release_tag != config.release_tag(manifest.marketing_version)
        or record.github_repository != config.repository
        or record.github_title != config.release_title(manifest.marketing_version)
        or record.prerelease is not True
        or record.appcast_url != config.appcast_url()
        or record.release_manifest_sha256 != hashlib.sha256(artifacts.manifest_path.read_bytes()).hexdigest()
        or tuple(asset.name for asset in record.assets) != expected_names
    ):
        raise _error("published provenance does not match the canonical Step 6 release")
    for asset in record.assets:
        expected = expected_facts.get(asset.name)
        if expected is None or asset != expected:
            raise _error(f"published provenance asset facts do not match Step 6: {asset.name}")
    return record


def _release_details(github: GitHubReadOnly, repository: str, tag: str) -> dict:
    result = github.release_details(repository, tag)
    if result.returncode != 0:
        raise _error("published GitHub Release is unavailable", FailureClass.GITHUB)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise _error("published GitHub Release metadata is malformed", FailureClass.GITHUB) from error
    if not isinstance(value, dict):
        raise _error("published GitHub Release metadata is malformed", FailureClass.GITHUB)
    expected = {"tagName": tag, "name": f"LinkGate {tag[1:]}", "isDraft": False, "isPrerelease": True}
    if any(value.get(key) != expected_value for key, expected_value in expected.items()):
        raise _error("published GitHub Release metadata does not match the immutable beta contract", FailureClass.GITHUB)
    return value


def _download(http: HttpClient, url: str, message: str) -> bytes:
    response = http.get(url, timeout=30)
    if response.status != 200:
        raise _error(f"{message} (HTTP {response.status})", FailureClass.TRUST)
    return response.body


def verify_published_beta(
    repo_root: Path,
    config_path: Path,
    version: str,
    *,
    runner=None,
    http: HttpClient | None = None,
    tools: ToolLocator | None = None,
    clock: Callable[[], datetime] | None = None,
) -> dict:
    parse_marketing_version(version)
    runner = runner or SubprocessRunner()
    http = http or DefaultHttpClient()
    tools = tools or DefaultToolLocator(runner)
    config = load_config(config_path)
    manifest_path = repo_root / "dist" / f"LinkGate-{version}.release.json"
    if not manifest_path.is_file():
        raise _error("canonical Step 6 manifest for the requested version is missing")
    manifest = load_manifest(manifest_path)
    if manifest.marketing_version != version:
        raise _error("requested version does not match the canonical Step 6 manifest")
    artifacts = discover_artifacts(repo_root, manifest)
    validate_artifacts(artifacts)
    notes_path = release_notes_source_path(repo_root, config, version)
    if not notes_path.is_file():
        raise _error("canonical release-note source is missing", FailureClass.RELEASE_NOTES)
    rendered_notes = render_release_notes(notes_path.read_bytes(), version=version).html_bytes

    gh_path = tools.find("gh")
    sign_update = tools.find("sign_update")
    openssl = tools.find("openssl")
    if gh_path is None or sign_update is None or openssl is None:
        raise _error("required retrospective verification tool is unavailable", FailureClass.TOOLING)
    verify_sign_update(config, sign_update)
    verify_openssl_capability(runner, openssl)
    github = GitHubReadOnly(runner, gh_path)
    tag = config.release_tag(version)
    tag_result = github.tag(config.repository, tag)
    if tag_result.returncode != 0:
        raise _error("published release tag is unavailable", FailureClass.GITHUB)
    try:
        tag_data = json.loads(tag_result.stdout)
        tag_object = tag_data["object"]
        if tag_object["type"] == "tag":
            tag_data = json.loads(github.tag_object(config.repository, tag_object["sha"]).stdout)
            tag_object = tag_data["object"]
        if tag_object["type"] != "commit" or tag_object["sha"] != manifest.source_commit:
            raise ValueError("tag target mismatch")
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise _error("published release tag does not resolve to the canonical Step 6 source commit", FailureClass.GITHUB) from error
    release = _release_details(github, config.repository, tag)
    asset_names = [item.get("name") for item in release.get("assets", []) if isinstance(item, dict)]
    expected_names = [f"LinkGate-{version}{suffix}" for suffix in EXPECTED_ASSET_SUFFIXES] + [f"LinkGate-{version}.publish.json"]
    if asset_names != expected_names and set(asset_names) != set(expected_names):
        raise _error("published GitHub Release assets do not match the immutable contract", FailureClass.GITHUB)

    asset_urls = {
        name: f"https://github.com/{config.repository}/releases/download/{tag}/{name}"
        for name in expected_names
    }
    public_assets = {name: _download(http, url, f"public asset unavailable: {name}") for name, url in asset_urls.items()}
    try:
        publish_data = json.loads(public_assets[f"LinkGate-{version}.publish.json"])
    except (KeyError, json.JSONDecodeError) as error:
        raise _error("published publication provenance is malformed", FailureClass.PROVENANCE) from error
    record = _published_record(publish_data, config, manifest, artifacts)
    if public_assets[f"LinkGate-{version}.release.json"] != manifest_path.read_bytes():
        raise _error("public Step 6 manifest bytes do not match local canonical provenance", FailureClass.TRUST)
    local_assets = {
        artifacts.dmg_path.name: artifacts.dmg_path.read_bytes(),
        artifacts.checksum_path.name: artifacts.checksum_path.read_bytes(),
        artifacts.manifest_path.name: artifacts.manifest_path.read_bytes(),
    }
    for name, local_bytes in local_assets.items():
        if public_assets[name] != local_bytes:
            raise _error(f"public asset bytes do not match canonical local bytes: {name}", FailureClass.TRUST)

    appcast_bytes = _download(http, record.appcast_url, "public appcast unavailable")
    public_feed = parse_appcast(appcast_bytes)
    if len(public_feed.items) == 0:
        raise _error("public appcast contains no release item", FailureClass.APPCAST)
    public_item = public_feed.items[0]
    expected_enclosure = f"https://github.com/{config.repository}/releases/download/{tag}/{artifacts.dmg_path.name}"
    if (
        public_item.marketing_version != version
        or public_item.build_version != manifest.build
        or public_item.minimum_system_version != manifest.deployment_target
        or public_item.release_notes_url != config.release_notes_url(version)
        or public_item.enclosure_url != expected_enclosure
        or public_item.enclosure_length != artifacts.dmg_path.stat().st_size
    ):
        raise _error("public appcast item does not match the immutable release facts", FailureClass.APPCAST)
    try:
        appcast_time = parsedate_to_datetime(public_item.pub_date)
        publication_time = datetime.fromisoformat(record.publication_recorded_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise _error("public appcast publication time is malformed", FailureClass.APPCAST) from error
    if appcast_time.astimezone(timezone.utc) != publication_time.astimezone(timezone.utc).replace(microsecond=0):
        raise _error("public appcast publication time does not match publication provenance", FailureClass.APPCAST)
    with tempfile.TemporaryDirectory(prefix=f"linkgate-retrospective-{version}-") as directory:
        workspace = Path(directory)
        (workspace / "updates/releases").mkdir(parents=True)
        (workspace / "updates/appcast.xml").write_bytes(appcast_bytes)
        notes_file = workspace / "updates/releases" / f"{version}.html"
        notes_file.write_bytes(rendered_notes)
        stage = PagesStageResult(
            state="PAGES_STAGE_READY",
            commit_sha="" * 40,
            expected_previous_tip=None,
            bootstrap=False,
            appcast_sha256=hashlib.sha256(appcast_bytes).hexdigest(),
            release_notes_sha256=hashlib.sha256(rendered_notes).hexdigest(),
            marketing_version=version,
            build_version=manifest.build,
            publication_recorded_at=record.publication_recorded_at,
            workspace=workspace,
            sign_update_path=sign_update,
            openssl_path=openssl,
        )
        public_acceptance = DefaultPublicVerifier(config, http, runner=runner).verify(
            record,
            stage,
            PublishedRelease(release.get("url", ""), release.get("publishedAt")),
        )
        pages_ref = github.ref(config.repository, "heads/gh-pages")
        if pages_ref.returncode != 0:
            raise _error("public gh-pages ref is unavailable", FailureClass.GITHUB)

    try:
        pages_sha = json.loads(pages_ref.stdout)["object"]["sha"]
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise _error("public gh-pages ref metadata is malformed", FailureClass.GITHUB) from error
    pages_commit = github.commit(config.repository, pages_sha)
    if pages_commit.returncode != 0:
        raise _error("public gh-pages commit is unavailable", FailureClass.GITHUB)
    try:
        pages_data = json.loads(pages_commit.stdout)
        changed_paths = {item["filename"] for item in pages_data["files"]}
        parent_count = len(pages_data["parents"])
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise _error("public gh-pages commit metadata is malformed", FailureClass.GITHUB) from error
    if pages_data.get("commit", {}).get("message", "").rstrip("\n") != f"Publish LinkGate {version} update feed" or changed_paths != {
        "updates/appcast.xml", f"updates/releases/{version}.html"
    } or parent_count != 1:
        raise _error("public gh-pages commit does not match the published update content", FailureClass.GITHUB)

    evidence_dir = repo_root / ".scratch" / "publication-evidence" / version
    evidence_dir.mkdir(parents=True, exist_ok=True)
    historical = {}
    historical_path = evidence_dir / "acceptance.json"
    if historical_path.is_file():
        try:
            historical = json.loads(historical_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            historical = {"unreadable_historical_acceptance": True}
    pages_tip = pages_sha
    timestamp = (clock or (lambda: datetime.now(timezone.utc)))().astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    result = {
        "outcome": "RETROSPECTIVE_ACCEPTED",
        "original_outcome": historical.get("outcome", "PUBLISHED"),
        "historical_publication_message": historical.get("message", "original publication acceptance record retained"),
        "retrospective_verified_at": timestamp,
        "source_commit": record.source_commit,
        "marketing_version": record.marketing_version,
        "build": record.build,
        "release_tag": record.release_tag,
        "github_repository": record.github_repository,
        "github_release_url": release.get("url", ""),
        "published_at": release.get("publishedAt"),
        "publication_recorded_at": record.publication_recorded_at,
        "dmg_sha256": manifest.sha256,
        "appcast_url": record.appcast_url,
        "appcast_sha256": public_acceptance.appcast_sha256,
        "release_notes_url": public_acceptance.release_notes_url,
        "release_notes_sha256": public_acceptance.release_notes_sha256,
        "pages_tip": pages_tip,
        "official_sparkle_verification": "PASS",
        "independent_public_key_verification": "PASS",
    }
    (evidence_dir / "retrospective-acceptance.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Read-only acceptance of an immutable LinkGate beta")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path, default=Path("scripts/release/publish-config.json"))
    parser.add_argument("--version", required=True)
    args = parser.parse_args(argv)
    root = args.repo_root.resolve()
    config = args.config if args.config.is_absolute() else root / args.config
    try:
        result = verify_published_beta(root, config, args.version)
    except PublicationError as error:
        print(f"RETROSPECTIVE: BLOCKED\n{error}")
        return 4
    print("RETROSPECTIVE: ACCEPTED")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
