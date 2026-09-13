from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from urllib.parse import urlparse
from xml.etree import ElementTree as ET

from .errors import FailureClass, PublicationError
from .models import parse_marketing_version


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = f"{{{SPARKLE_NAMESPACE}}}"

ET.register_namespace("sparkle", SPARKLE_NAMESPACE)


@dataclass(frozen=True)
class AppcastItem:
    title: str
    product_url: str
    marketing_version: str
    build_version: str
    minimum_system_version: str
    release_notes_url: str
    enclosure_url: str
    enclosure_length: int
    ed_signature: str
    publication_recorded_at: datetime

    def __post_init__(self) -> None:
        parse_marketing_version(self.marketing_version)
        if not self.build_version.isdigit() or self.enclosure_length < 0:
            raise PublicationError(FailureClass.APPCAST, "appcast item contains an invalid build or length")
        for field_name, value in (("product URL", self.product_url), ("release-note URL", self.release_notes_url), ("enclosure URL", self.enclosure_url)):
            parsed = urlparse(value)
            if parsed.scheme != "https" or not parsed.netloc:
                raise PublicationError(FailureClass.APPCAST, f"{field_name} must be an HTTPS URL")
        if not self.title or not self.minimum_system_version or not self.ed_signature:
            raise PublicationError(FailureClass.APPCAST, "appcast item is missing a required value")
        if self.publication_recorded_at.tzinfo is None or self.publication_recorded_at.utcoffset() is None:
            raise PublicationError(FailureClass.APPCAST, "publication time must be timezone-aware")

    @property
    def pub_date(self) -> str:
        return format_datetime(self.publication_recorded_at.astimezone(timezone.utc), usegmt=True)


@dataclass(frozen=True)
class AppcastFeed:
    channel_title: str
    channel_link: str
    channel_description: str
    items: tuple[AppcastItem, ...]


def _validate_feed(feed: AppcastFeed) -> None:
    if not feed.channel_title or not feed.channel_description or urlparse(feed.channel_link).scheme != "https":
        raise PublicationError(FailureClass.APPCAST, "appcast channel is incomplete or has a non-HTTPS link")
    marketing_versions = set()
    builds = set()
    previous_build = None
    for item in feed.items:
        if item.marketing_version in marketing_versions or item.build_version in builds:
            raise PublicationError(FailureClass.APPCAST, "appcast contains duplicate marketing version or build")
        marketing_versions.add(item.marketing_version)
        builds.add(item.build_version)
        if previous_build is not None and int(item.build_version) >= previous_build:
            raise PublicationError(FailureClass.APPCAST, "appcast items must be newest-first by build")
        previous_build = int(item.build_version)


def serialize_appcast(feed: AppcastFeed) -> bytes:
    _validate_feed(feed)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = feed.channel_title
    ET.SubElement(channel, "link").text = feed.channel_link
    ET.SubElement(channel, "description").text = feed.channel_description
    for item in feed.items:
        element = ET.SubElement(channel, "item")
        ET.SubElement(element, "title").text = item.title
        ET.SubElement(element, "link").text = item.product_url
        ET.SubElement(element, f"{SPARKLE}version").text = item.build_version
        ET.SubElement(element, f"{SPARKLE}shortVersionString").text = item.marketing_version
        ET.SubElement(element, f"{SPARKLE}minimumSystemVersion").text = item.minimum_system_version
        ET.SubElement(element, f"{SPARKLE}releaseNotesLink").text = item.release_notes_url
        ET.SubElement(element, "pubDate").text = item.pub_date
        ET.SubElement(
            element,
            "enclosure",
            {
                "url": item.enclosure_url,
                f"{SPARKLE}edSignature": item.ed_signature,
                "length": str(item.enclosure_length),
                "type": "application/octet-stream",
            },
        )
    return ET.tostring(root, encoding="utf-8", xml_declaration=True, short_empty_elements=True) + b"\n"


def _required_text(element: ET.Element, tag: str) -> str:
    child = element.find(tag)
    if child is None or not child.text:
        raise PublicationError(FailureClass.APPCAST, f"appcast is missing {tag}")
    return child.text


def parse_appcast(data: bytes) -> AppcastFeed:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise PublicationError(FailureClass.APPCAST, "appcast XML is malformed") from exc
    if root.tag != "rss" or root.attrib.get("version") != "2.0":
        raise PublicationError(FailureClass.APPCAST, "appcast root must be RSS 2.0")
    channels = root.findall("channel")
    if len(channels) != 1:
        raise PublicationError(FailureClass.APPCAST, "appcast must contain exactly one channel")
    channel = channels[0]
    items: list[AppcastItem] = []
    for element in channel.findall("item"):
        enclosure = element.find("enclosure")
        if enclosure is None:
            raise PublicationError(FailureClass.APPCAST, "appcast item is missing enclosure")
        signature = enclosure.attrib.get(f"{SPARKLE}edSignature", "")
        length = enclosure.attrib.get("length", "")
        try:
            enclosure_length = int(length)
            publication_time = parsedate_to_datetime(_required_text(element, "pubDate"))
        except (TypeError, ValueError, OverflowError) as exc:
            raise PublicationError(FailureClass.APPCAST, "appcast item has invalid length or publication date") from exc
        items.append(
            AppcastItem(
                title=_required_text(element, "title"),
                product_url=_required_text(element, "link"),
                marketing_version=_required_text(element, f"{SPARKLE}shortVersionString"),
                build_version=_required_text(element, f"{SPARKLE}version"),
                minimum_system_version=_required_text(element, f"{SPARKLE}minimumSystemVersion"),
                release_notes_url=_required_text(element, f"{SPARKLE}releaseNotesLink"),
                enclosure_url=enclosure.attrib.get("url", ""),
                enclosure_length=enclosure_length,
                ed_signature=signature,
                publication_recorded_at=publication_time,
            )
        )
    feed = AppcastFeed(
        channel_title=_required_text(channel, "title"),
        channel_link=_required_text(channel, "link"),
        channel_description=_required_text(channel, "description"),
        items=tuple(items),
    )
    _validate_feed(feed)
    return feed
