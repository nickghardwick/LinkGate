from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Protocol, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from .appcast import parse_appcast
from .config import PublicationConfig, load_config
from .errors import FailureClass, PublicationError
from .models import parse_marketing_version
from .release_notes import release_notes_source_path, render_release_notes
from .sparkle import verify_openssl_capability, verify_sign_update
from .step6 import Step6Artifacts, Step6Manifest, discover_artifacts, load_manifest, validate_artifacts


class PreflightCategory(str, Enum):
    REPOSITORY = "repository"
    STEP6 = "step6"
    RELEASE_NOTES = "release-notes"
    CONFIGURATION = "configuration"
    TOOLING = "tooling"
    SPARKLE = "sparkle"
    GITHUB = "github"
    APPCAST = "appcast"
    TRUST = "artifact-trust"


@dataclass(frozen=True)
class PreflightFinding:
    category: PreflightCategory
    message: str
    blocking: bool = True


@dataclass(frozen=True)
class PreflightContext:
    repo_root: Path
    config_path: Path
    config: PublicationConfig
    manifest: Step6Manifest
    artifacts: Step6Artifacts
    release_notes_path: Path
    tag: str
    sign_update_path: str
    openssl_path: str


@dataclass
class PreflightReport:
    findings: list[PreflightFinding] = field(default_factory=list)
    context: PreflightContext | None = None

    @property
    def blocked(self) -> bool:
        return any(finding.blocking for finding in self.findings)

    @property
    def exit_code(self) -> int:
        return 2 if self.blocked else 0

    def add_pass(self, category: PreflightCategory, message: str) -> None:
        self.findings.append(PreflightFinding(category, message, False))

    def add_blocker(self, category: PreflightCategory, message: str) -> None:
        self.findings.append(PreflightFinding(category, message, True))

    def render(self) -> str:
        lines = ["PREFLIGHT: BLOCKED" if self.blocked else "PREFLIGHT: READY"]
        for finding in self.findings:
            marker = "BLOCKED" if finding.blocking else "PASS"
            lines.append(f"{marker} [{finding.category.value}] {finding.message}")
        return "\n".join(lines)


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    def run(self, args: Sequence[str], cwd: Path | None = None) -> CommandResult:
        ...


class SubprocessRunner:
    def run(self, args: Sequence[str], cwd: Path | None = None) -> CommandResult:
        completed = subprocess.run(
            list(args), cwd=cwd, text=True, capture_output=True, check=False
        )
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)


@dataclass(frozen=True)
class ToolResult:
    name: str
    path: str
    version: str = ""
    version_ok: bool = True


class ToolLocator(Protocol):
    def find(self, name: str) -> str | None:
        ...

    def inspect(self, name: str, path: str) -> ToolResult:
        ...


class DefaultToolLocator:
    def __init__(self, runner: CommandRunner):
        self.runner = runner

    def find(self, name: str) -> str | None:
        if name == "sign_update" and os.environ.get("LINKGATE_SPARKLE_DIR"):
            candidate = Path(os.environ["LINKGATE_SPARKLE_DIR"]).expanduser() / "bin" / "sign_update"
            return str(candidate) if candidate.is_file() and os.access(candidate, os.X_OK) else None
        if name == "sign_update":
            return None
        return shutil.which(name) or (sys.executable if name == "python" else None)

    def inspect(self, name: str, path: str) -> ToolResult:
        result = self.runner.run([path, "--version"])
        output = (result.stdout or result.stderr).strip().splitlines()
        version = output[0] if output else ""
        return ToolResult(name, path, version, result.returncode == 0)


@dataclass(frozen=True)
class HttpResponse:
    status: int
    body: bytes
    error: str = ""


class HttpClient(Protocol):
    def get(self, url: str, timeout: int) -> HttpResponse:
        ...


class DefaultHttpClient:
    def get(self, url: str, timeout: int) -> HttpResponse:
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.netloc:
            raise ValueError("preflight HTTP client only accepts absolute HTTPS URLs")
        request = Request(url, headers={"User-Agent": "LinkGate-publication-preflight"})
        try:
            # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            with urlopen(request, timeout=timeout) as response:
                return HttpResponse(response.status, response.read())
        except HTTPError as error:
            return HttpResponse(error.code, error.read(), str(error))
        except URLError as error:
            return HttpResponse(0, b"", str(error))


@dataclass
class PreflightDependencies:
    runner: CommandRunner = field(default_factory=SubprocessRunner)
    tools: ToolLocator | None = None
    http: HttpClient = field(default_factory=DefaultHttpClient)

    def __post_init__(self) -> None:
        if self.tools is None:
            self.tools = DefaultToolLocator(self.runner)


@dataclass(frozen=True)
class XcodeMetadata:
    product: str
    marketing_version: str
    build: str
    bundle_id: str
    architectures: tuple[str, ...]
    deployment_target: str
    code_sign_identity: str
    development_team: str | None


def parse_xcode_metadata(output: str) -> XcodeMetadata:
    try:
        value = json.loads(output)
        settings = value[0]["buildSettings"]

        def required(name: str) -> str:
            result = settings.get(name)
            if not isinstance(result, str) or not result:
                raise ValueError(f"missing {name}")
            return result

        architectures = tuple(required("ARCHS").split())
        if not architectures:
            raise ValueError("missing ARCHS")
        return XcodeMetadata(
            product=required("PRODUCT_NAME"),
            marketing_version=required("MARKETING_VERSION"),
            build=required("CURRENT_PROJECT_VERSION"),
            bundle_id=required("PRODUCT_BUNDLE_IDENTIFIER"),
            architectures=architectures,
            deployment_target=required("MACOSX_DEPLOYMENT_TARGET"),
            code_sign_identity=required("CODE_SIGN_IDENTITY"),
            development_team=settings.get("DEVELOPMENT_TEAM"),
        )
    except (IndexError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise PublicationError(FailureClass.PROVENANCE, f"invalid Xcode build metadata: {error}") from error


class GitHubReadOnly:
    """Read-only gh adapter. It intentionally exposes no GitHub mutation operation."""

    def __init__(self, runner: CommandRunner, gh_path: str):
        self.runner = runner
        self.gh_path = gh_path

    def auth_status(self) -> CommandResult:
        return self.runner.run([self.gh_path, "auth", "status", "--hostname", "github.com"])

    def repository(self, repository: str) -> CommandResult:
        return self.runner.run([self.gh_path, "repo", "view", repository, "--json", "nameWithOwner,viewerPermission"])

    def tag(self, repository: str, tag: str) -> CommandResult:
        return self.runner.run([self.gh_path, "api", "--method", "GET", f"repos/{repository}/git/ref/tags/{tag}"])

    def tag_object(self, repository: str, sha: str) -> CommandResult:
        return self.runner.run([self.gh_path, "api", "--method", "GET", f"repos/{repository}/git/tags/{sha}"])

    def release(self, repository: str, tag: str) -> CommandResult:
        return self.runner.run([self.gh_path, "release", "view", tag, "--repo", repository, "--json", "tagName,name,isDraft,isPrerelease"])

    def release_details(self, repository: str, tag: str) -> CommandResult:
        return self.runner.run([
            self.gh_path,
            "release",
            "view",
            tag,
            "--repo",
            repository,
            "--json",
            "tagName,name,isDraft,isPrerelease,url,publishedAt,assets",
        ])

    def ref(self, repository: str, reference: str) -> CommandResult:
        return self.runner.run([self.gh_path, "api", "--method", "GET", f"repos/{repository}/git/ref/{reference}"])

    def commit(self, repository: str, sha: str) -> CommandResult:
        return self.runner.run([self.gh_path, "api", "--method", "GET", f"repos/{repository}/commits/{sha}"])


def _run_git(deps: PreflightDependencies, repo_root: Path, args: Sequence[str]) -> CommandResult:
    return deps.runner.run(["git", *args], cwd=repo_root)


def _check_repository(report: PreflightReport, repo_root: Path, manifest: Step6Manifest | None, tag: str | None, deps: PreflightDependencies) -> None:
    top_level = _run_git(deps, repo_root, ["rev-parse", "--show-toplevel"])
    if top_level.returncode != 0 or Path(top_level.stdout.strip()).resolve() != repo_root.resolve():
        report.add_blocker(PreflightCategory.REPOSITORY, "current directory is not the intended LinkGate Git checkout")
    else:
        report.add_pass(PreflightCategory.REPOSITORY, "current checkout resolves to the requested repository")

    branch = _run_git(deps, repo_root, ["rev-parse", "--abbrev-ref", "HEAD"])
    if branch.returncode != 0 or branch.stdout.strip() != "main":
        report.add_blocker(PreflightCategory.REPOSITORY, "current branch is not main")
    else:
        report.add_pass(PreflightCategory.REPOSITORY, "current branch is main")

    status = _run_git(deps, repo_root, ["status", "--porcelain", "--untracked-files=all"])
    staged = _run_git(deps, repo_root, ["diff", "--cached", "--quiet"])
    unstaged = _run_git(deps, repo_root, ["diff", "--quiet"])
    if status.returncode != 0 or status.stdout.strip() or staged.returncode != 0 or unstaged.returncode != 0:
        report.add_blocker(PreflightCategory.REPOSITORY, "working tree or index is not clean")
    else:
        report.add_pass(PreflightCategory.REPOSITORY, "working tree and index are clean")

    if os.environ.get("VERSION") is not None or os.environ.get("BUILD") is not None:
        report.add_blocker(PreflightCategory.REPOSITORY, "VERSION/BUILD overrides are present")
    else:
        report.add_pass(PreflightCategory.REPOSITORY, "VERSION/BUILD overrides are absent")

    if manifest is None:
        return
    head = _run_git(deps, repo_root, ["rev-parse", "HEAD"])
    if head.returncode != 0 or head.stdout.strip() != manifest.source_commit:
        report.add_blocker(PreflightCategory.REPOSITORY, "HEAD does not match Step 6 source commit")
    else:
        report.add_pass(PreflightCategory.REPOSITORY, "HEAD matches Step 6 source commit")
    if tag is not None:
        existing = _run_git(deps, repo_root, ["tag", "--list", tag])
        if existing.returncode != 0:
            report.add_blocker(PreflightCategory.REPOSITORY, "could not inspect local release tags")
        elif existing.stdout.strip():
            report.add_blocker(PreflightCategory.REPOSITORY, f"local tag already exists: {tag}")
        else:
            report.add_pass(PreflightCategory.REPOSITORY, f"local tag is absent: {tag}")


def _check_manifest_policy(report: PreflightReport, manifest: Step6Manifest) -> None:
    if manifest.product != "LinkGate":
        report.add_blocker(PreflightCategory.STEP6, "Step 6 manifest product is not LinkGate")
    if manifest.bundle_id != "com.nickghardwick.LinkGate":
        report.add_blocker(PreflightCategory.STEP6, "Step 6 manifest bundle ID does not match LinkGate")
    if manifest.signing_identity.endswith("(Z8A8ZWCZ45)"):
        report.add_pass(PreflightCategory.STEP6, "Step 6 signing identity names Team ID Z8A8ZWCZ45")
    else:
        report.add_blocker(PreflightCategory.STEP6, "Step 6 signing identity does not name Team ID Z8A8ZWCZ45")


def _check_xcode(report: PreflightReport, repo_root: Path, manifest: Step6Manifest | None, config: PublicationConfig | None, deps: PreflightDependencies) -> None:
    if manifest is None:
        return
    if deps.tools is None or deps.tools.find("xcodebuild") is None:
        report.add_blocker(PreflightCategory.TOOLING, "xcodebuild is unavailable")
        return
    result = deps.runner.run(
        ["xcodebuild", "-project", "LinkGate.xcodeproj", "-scheme", "LinkGate", "-configuration", "Release", "-showBuildSettings", "-json"],
        cwd=repo_root,
    )
    if result.returncode != 0:
        report.add_blocker(PreflightCategory.STEP6, "could not read committed Xcode build settings")
        return
    try:
        metadata = parse_xcode_metadata(result.stdout)
    except PublicationError as error:
        report.add_blocker(PreflightCategory.STEP6, str(error))
        return
    pairs = (
        ("product", metadata.product, manifest.product),
        ("marketing version", metadata.marketing_version, manifest.marketing_version),
        ("build", metadata.build, manifest.build),
        ("bundle ID", metadata.bundle_id, manifest.bundle_id),
        ("deployment target", metadata.deployment_target, manifest.deployment_target),
    )
    mismatches = [name for name, actual, expected in pairs if actual != expected]
    if tuple(metadata.architectures) != tuple(manifest.architectures):
        mismatches.append("architectures")
    if not metadata.code_sign_identity or not manifest.signing_identity.startswith(metadata.code_sign_identity):
        mismatches.append("signing identity")
    if config is not None:
        if metadata.product != config.product or metadata.bundle_id != config.bundle_id or metadata.deployment_target != config.minimum_macos_version:
            mismatches.append("publication configuration")
        if metadata.development_team is not None and metadata.development_team != config.team_id:
            mismatches.append("Team ID")
        if f"({config.team_id})" not in manifest.signing_identity:
            mismatches.append("manifest Team ID")
    if mismatches:
        report.add_blocker(PreflightCategory.STEP6, "Xcode metadata disagrees with Step 6/configuration: " + ", ".join(sorted(set(mismatches))))
    else:
        report.add_pass(PreflightCategory.STEP6, "Xcode metadata agrees with Step 6 provenance and publication policy")


def _check_release_notes(report: PreflightReport, repo_root: Path, manifest: Step6Manifest | None, config: PublicationConfig | None, deps: PreflightDependencies) -> None:
    if manifest is None:
        return
    relative = Path(config.release_notes_source(manifest.marketing_version) if config else f"release-notes/{manifest.marketing_version}.md")
    if relative.is_absolute() or ".." in relative.parts or relative.name != f"{manifest.marketing_version}.md":
        report.add_blocker(PreflightCategory.RELEASE_NOTES, "release-note path does not match the version-specific convention")
        return
    path = repo_root / relative
    if not path.is_file():
        report.add_blocker(PreflightCategory.RELEASE_NOTES, f"release-note source is missing: {relative}")
        return
    tracked = _run_git(deps, repo_root, ["ls-files", "--error-unmatch", str(relative)])
    ignored = _run_git(deps, repo_root, ["check-ignore", "-q", "--no-index", "--", str(relative)])
    same_commit = _run_git(deps, repo_root, ["cat-file", "-e", f"{manifest.source_commit}:{relative}"])
    if tracked.returncode != 0:
        report.add_blocker(PreflightCategory.RELEASE_NOTES, f"release-note source is not tracked: {relative}")
    elif ignored.returncode == 0:
        report.add_blocker(PreflightCategory.RELEASE_NOTES, f"release-note source is ignored: {relative}")
    elif same_commit.returncode != 0:
        report.add_blocker(PreflightCategory.RELEASE_NOTES, "release-note source is not present in the Step 6 source commit")
    else:
        try:
            render_release_notes(path.read_bytes(), version=manifest.marketing_version)
        except PublicationError as error:
            report.add_blocker(PreflightCategory.RELEASE_NOTES, str(error))
        else:
            report.add_pass(PreflightCategory.RELEASE_NOTES, f"release-note source is tracked, versioned, and deterministically renderable: {relative}")


def _check_tools(report: PreflightReport, deps: PreflightDependencies, config: PublicationConfig | None) -> dict[str, str]:
    assert deps.tools is not None
    required = ("git", "gh", "python", "openssl", "xcodebuild", "xcrun", "codesign", "stapler", "spctl", "hdiutil", "sign_update")
    found: dict[str, str] = {}
    for name in required:
        path = deps.tools.find(name)
        if path is None:
            category = PreflightCategory.SPARKLE if name == "sign_update" else PreflightCategory.TOOLING
            report.add_blocker(category, f"required tool is unavailable: {name}")
            continue
        found[name] = path
        if name == "sign_update":
            if config is None:
                report.add_blocker(PreflightCategory.SPARKLE, "cannot verify sign_update provenance while publication configuration is invalid")
            else:
                try:
                    verify_sign_update(config, path)
                except PublicationError as error:
                    report.add_blocker(PreflightCategory.SPARKLE, str(error))
                else:
                    report.add_pass(PreflightCategory.SPARKLE, f"sign_update matches the pinned official Sparkle {config.sparkle_version} distribution")
        elif name in {"git", "gh", "python"}:
            inspected = deps.tools.inspect(name, path)
            if inspected.version:
                report.add_pass(PreflightCategory.TOOLING, f"{name} available at {path} ({inspected.version})")
            else:
                report.add_pass(PreflightCategory.TOOLING, f"{name} available at {path}")
        elif name == "openssl":
            try:
                verify_openssl_capability(deps.runner, path)
            except PublicationError as error:
                report.add_blocker(PreflightCategory.TOOLING, str(error))
            else:
                report.add_pass(PreflightCategory.TOOLING, f"OpenSSL at {path} supports Ed25519 verification")
    return found


def _check_github(report: PreflightReport, config: PublicationConfig | None, tag: str | None, tools: dict[str, str], deps: PreflightDependencies) -> None:
    if config is None or tag is None:
        return
    gh_path = tools.get("gh")
    if gh_path is None:
        return
    github = GitHubReadOnly(deps.runner, gh_path)
    auth = github.auth_status()
    if auth.returncode != 0:
        report.add_blocker(PreflightCategory.GITHUB, "gh is not authenticated")
        return
    report.add_pass(PreflightCategory.GITHUB, "gh is authenticated")
    repository = github.repository(config.repository)
    if repository.returncode != 0:
        report.add_blocker(PreflightCategory.GITHUB, f"configured GitHub repository is inaccessible: {config.repository}")
        return
    try:
        repository_data = json.loads(repository.stdout)
        permission = repository_data["viewerPermission"]
        if repository_data.get("nameWithOwner") != config.repository or permission not in {"ADMIN", "MAINTAIN", "WRITE"}:
            report.add_blocker(PreflightCategory.GITHUB, f"authenticated GitHub user lacks apparent write access to {config.repository}")
            return
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        report.add_blocker(PreflightCategory.GITHUB, f"gh did not report usable repository access: {error}")
        return
    report.add_pass(PreflightCategory.GITHUB, f"configured GitHub repository is accessible: {config.repository}")
    remote_tag = github.tag(config.repository, tag)
    if remote_tag.returncode == 0:
        report.add_blocker(PreflightCategory.GITHUB, f"remote release tag already exists: {tag}")
    elif "not found" in (remote_tag.stderr + remote_tag.stdout).lower() or "404" in remote_tag.stderr:
        report.add_pass(PreflightCategory.GITHUB, f"remote release tag is absent: {tag}")
    else:
        report.add_blocker(PreflightCategory.GITHUB, f"could not determine whether remote tag exists: {tag}")
    release = github.release(config.repository, tag)
    if release.returncode == 0:
        report.add_blocker(PreflightCategory.GITHUB, f"GitHub Release already exists for tag: {tag}")
    elif "not found" in (release.stderr + release.stdout).lower() or "404" in release.stderr:
        report.add_pass(PreflightCategory.GITHUB, f"GitHub Release is absent for tag: {tag}")
    else:
        report.add_blocker(PreflightCategory.GITHUB, f"could not determine whether GitHub Release exists: {tag}")


def _check_appcast(report: PreflightReport, config: PublicationConfig | None, manifest: Step6Manifest | None, deps: PreflightDependencies) -> None:
    if config is None or manifest is None:
        return
    try:
        response = deps.http.get(config.appcast_url(), timeout=30)
    except Exception as error:
        report.add_blocker(PreflightCategory.APPCAST, f"could not fetch existing appcast: {error}")
        return
    if response.status == 404:
        report.add_pass(PreflightCategory.APPCAST, "no existing appcast found; first-publication bootstrap state")
        return
    if response.status != 200:
        report.add_blocker(PreflightCategory.APPCAST, f"existing appcast fetch returned HTTP {response.status}: {response.error}")
        return
    try:
        feed = parse_appcast(response.body)
    except PublicationError as error:
        report.add_blocker(PreflightCategory.APPCAST, f"existing appcast is invalid: {error}")
        return
    candidate_version = parse_marketing_version(manifest.marketing_version)
    existing_builds = [int(item.build_version) for item in feed.items]
    existing_versions = [parse_marketing_version(item.marketing_version) for item in feed.items]
    if existing_builds and int(manifest.build) <= max(existing_builds):
        report.add_blocker(PreflightCategory.APPCAST, "candidate build is not greater than the existing appcast")
    elif existing_versions and candidate_version <= max(existing_versions):
        report.add_blocker(PreflightCategory.APPCAST, "candidate marketing version is not newer than the existing appcast")
    else:
        report.add_pass(PreflightCategory.APPCAST, "existing appcast is valid and older than the candidate")


def _check_trust(report: PreflightReport, repo_root: Path, artifacts: Step6Artifacts | None, deps: PreflightDependencies) -> None:
    if artifacts is None:
        return
    validator = repo_root / "scripts/release/validate-dmg.sh"
    if not validator.is_file():
        report.add_blocker(PreflightCategory.TRUST, "Step 6 DMG validator is unavailable")
        return
    with tempfile.TemporaryDirectory(prefix="linkgate-preflight-") as directory:
        metadata = Path(directory) / "metadata.json"
        observed = Path(directory) / "observed.json"
        metadata.write_text(json.dumps({
            "product": artifacts.manifest.product,
            "marketing_version": artifacts.manifest.marketing_version,
            "build": artifacts.manifest.build,
            "bundle_id": artifacts.manifest.bundle_id,
            "deployment_target": artifacts.manifest.deployment_target,
            "signing_identity": artifacts.manifest.signing_identity,
        }), encoding="utf-8")
        result = deps.runner.run([
            "bash", "scripts/release/validate-dmg.sh", "--dmg", str(artifacts.dmg_path),
            "--metadata", str(metadata), "--observed-out", str(observed), "--require-stapled-ticket",
        ], cwd=repo_root)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        report.add_blocker(PreflightCategory.TRUST, detail[-1] if detail else "canonical DMG trust validation failed")
    else:
        report.add_pass(PreflightCategory.TRUST, "canonical DMG passed read-only structure, signature, stapler, and Gatekeeper validation")


def _manifest_path(repo_root: Path) -> Path | None:
    candidates = sorted((repo_root / "dist").glob("LinkGate-*.release.json"))
    return candidates[0] if len(candidates) == 1 else None


def run_preflight(repo_root: Path, config_path: Path, dependencies: PreflightDependencies | None = None) -> PreflightReport:
    deps = dependencies or PreflightDependencies()
    report = PreflightReport()
    manifest: Step6Manifest | None = None
    artifacts: Step6Artifacts | None = None
    config: PublicationConfig | None = None
    tag: str | None = None

    manifest_path = _manifest_path(repo_root)
    if manifest_path is not None:
        try:
            manifest = load_manifest(manifest_path)
            if manifest.product == "LinkGate":
                report.add_pass(PreflightCategory.STEP6, f"loaded Step 6 manifest for LinkGate {manifest.marketing_version} ({manifest.build})")
            else:
                report.add_blocker(PreflightCategory.STEP6, "Step 6 manifest product is not LinkGate")
            _check_manifest_policy(report, manifest)
            artifacts = discover_artifacts(repo_root, manifest)
            asset = validate_artifacts(artifacts)
            report.add_pass(PreflightCategory.STEP6, f"canonical DMG/checksum/manifest agree ({asset.name}, {asset.size} bytes)")
        except PublicationError as error:
            report.add_blocker(PreflightCategory.STEP6, str(error))
    else:
        report.add_blocker(PreflightCategory.STEP6, "canonical Step 6 release manifest is missing")

    try:
        config = load_config(config_path)
        report.add_pass(PreflightCategory.CONFIGURATION, f"publication configuration is resolved for {config.repository}")
    except PublicationError as error:
        report.add_blocker(PreflightCategory.CONFIGURATION, str(error))

    if manifest is not None:
        tag = config.release_tag(manifest.marketing_version) if config else f"v{manifest.marketing_version}"
    _check_repository(report, repo_root, manifest, tag, deps)
    _check_xcode(report, repo_root, manifest, config, deps)
    _check_release_notes(report, repo_root, manifest, config, deps)
    tools = _check_tools(report, deps, config)
    _check_github(report, config, tag, tools, deps)
    _check_appcast(report, config, manifest, deps)
    _check_trust(report, repo_root, artifacts, deps)
    if not report.blocked and config is not None and manifest is not None and artifacts is not None and tag is not None:
        report.context = PreflightContext(
            repo_root=repo_root,
            config_path=config_path,
            config=config,
            manifest=manifest,
            artifacts=artifacts,
            release_notes_path=release_notes_source_path(repo_root, config, manifest.marketing_version),
            tag=tag,
            sign_update_path=tools["sign_update"],
            openssl_path=tools["openssl"],
        )
    return report


def main(argv: Sequence[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Read-only LinkGate beta publication preflight")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path, default=Path("scripts/release/publish-config.json"))
    arguments = parser.parse_args(argv)
    repo_root = arguments.repo_root.resolve()
    config_path = arguments.config if arguments.config.is_absolute() else repo_root / arguments.config
    try:
        report = run_preflight(repo_root, config_path)
    except Exception as error:
        print(f"PREFLIGHT: INTERNAL ERROR\nINTERNAL ERROR: {error}")
        return 1
    print(report.render())
    return report.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
