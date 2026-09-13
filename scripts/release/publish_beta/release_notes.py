from __future__ import annotations

import hashlib
from html import escape
from pathlib import Path

from markdown_it import MarkdownIt

from .config import PublicationConfig
from .errors import FailureClass, PublicationError
from .models import RenderedReleaseNotes, parse_marketing_version


DEFAULT_HTML_TEMPLATE = b"""<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>{title}</title>
</head>
<body>
<main>
{body}</main>
</body>
</html>
"""


def release_notes_source_path(repo_root: Path, config: PublicationConfig, version: str) -> Path:
    parse_marketing_version(version)
    relative = Path(config.release_notes_source(version))
    if relative.is_absolute() or ".." in relative.parts:
        raise PublicationError(FailureClass.RELEASE_NOTES, "release-note source path must stay within the repository")
    return repo_root / relative


def render_release_notes(source: bytes, *, version: str, template: bytes = DEFAULT_HTML_TEMPLATE) -> RenderedReleaseNotes:
    parse_marketing_version(version)
    try:
        markdown = source.decode("utf-8")
        template_text = template.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PublicationError(FailureClass.RELEASE_NOTES, "release notes and template must be UTF-8") from exc

    renderer = MarkdownIt("commonmark", {"html": False, "linkify": False, "typographer": False})
    body = renderer.render(markdown)
    try:
        html = template_text.format(title=escape(f"LinkGate {version} release notes"), body=body)
    except (KeyError, ValueError) as exc:
        raise PublicationError(FailureClass.RELEASE_NOTES, "release-note template must contain title and body fields") from exc
    return RenderedReleaseNotes(
        version=version,
        source_sha256=hashlib.sha256(source).hexdigest(),
        template=template,
        html_bytes=html.encode("utf-8"),
    )
