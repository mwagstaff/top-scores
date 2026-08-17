from __future__ import annotations

import html
import os
import re
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urlencode

from ..http import HTTPClient
from ..models import ImageCandidate, Stadium, license_reference_url


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.first_link: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "a" and self.first_link is None:
            self.first_link = dict(attrs).get("href")

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def clean_html(value: str) -> tuple[str, str | None]:
    parser = _TextExtractor()
    parser.feed(html.unescape(value or ""))
    text = re.sub(r"\s+", " ", " ".join(parser.parts)).strip()
    link = parser.first_link
    if link and link.startswith("//"):
        link = f"https:{link}"
    return text, link


def license_allowed(value: str) -> bool:
    normalized = re.sub(r"[_-]+", " ", value.upper()).strip()
    normalized = re.sub(r"\s+", " ", normalized)
    if "PUBLIC DOMAIN" in normalized or normalized.startswith("CC0"):
        return True
    if "NONCOMMERCIAL" in normalized or "NO DERIV" in normalized:
        return False
    return bool(re.fullmatch(r"CC BY(?: SA)?(?: \d(?:\.\d)?)?", normalized))


class WikimediaSource:
    name = "wikimedia"
    max_queries_per_stadium = None
    endpoint = "https://commons.wikimedia.org/w/api.php"

    def __init__(self, http: HTTPClient) -> None:
        self.http = http
        self.http.set_host_interval("commons.wikimedia.org", 1.1)
        self.http.set_host_interval("upload.wikimedia.org", 3.1)
        self.download_width = max(
            1600,
            int(os.getenv("WIKIMEDIA_DOWNLOAD_WIDTH", "2560")),
        )

    @property
    def available(self) -> bool:
        return True

    def search(self, stadium: Stadium, query: str, limit: int) -> list[ImageCandidate]:
        payload = self.http.get_json(
            self.endpoint,
            params={
                "action": "query",
                "format": "json",
                "formatversion": 2,
                "generator": "search",
                "gsrsearch": query,
                "gsrnamespace": 6,
                "gsrlimit": min(max(limit, 1), 50),
                "prop": "imageinfo|categories",
                "iiprop": "url|size|mime|extmetadata",
                "iiurlwidth": self.download_width,
                "cllimit": "max",
                "origin": "*",
            },
        )
        query_payload = payload.get("query")
        pages = (
            query_payload.get("pages", []) if isinstance(query_payload, dict) else []
        )
        if not isinstance(pages, list):
            return []
        candidates: list[ImageCandidate] = []
        for page in pages:
            candidate = self._parse_page(page, query, self.download_width)
            if candidate is not None:
                candidates.append(candidate)
        return candidates

    def before_download(self, candidate: ImageCandidate) -> None:
        return None

    @staticmethod
    def _parse_page(
        page: object, query: str, download_width: int = 2560
    ) -> ImageCandidate | None:
        if not isinstance(page, dict):
            return None
        image_info_values = page.get("imageinfo")
        if not isinstance(image_info_values, list) or not image_info_values:
            return None
        image_info = image_info_values[0]
        if not isinstance(image_info, dict):
            return None
        metadata = image_info.get("extmetadata") or {}
        if not isinstance(metadata, dict):
            return None

        license_name = _metadata_value(metadata, "LicenseShortName") or _metadata_value(
            metadata, "UsageTerms"
        )
        if not license_name or not license_allowed(license_name):
            return None
        image_url = str(image_info.get("url") or "")
        file_name = str(page.get("title") or "").removeprefix("File:")
        download_url = (
            f"https://commons.wikimedia.org/w/thumb.php?"
            f"{urlencode({'f': file_name, 'w': download_width})}"
        )
        mime_type = str(image_info.get("mime") or "")
        if (
            not image_url
            or not file_name
            or mime_type not in {"image/jpeg", "image/png", "image/webp"}
        ):
            return None

        artist, artist_url = clean_html(_metadata_value(metadata, "Artist"))
        credit, _ = clean_html(_metadata_value(metadata, "Credit"))
        description, _ = clean_html(
            _metadata_value(metadata, "ImageDescription")
            or _metadata_value(metadata, "ObjectName")
        )
        categories: list[str] = []
        for category in page.get("categories", []):
            if isinstance(category, dict) and category.get("title"):
                categories.append(str(category["title"]).removeprefix("Category:"))
        page_id = str(page.get("pageid") or "")
        source_page = str(image_info.get("descriptionurl") or "")
        if not page_id or not source_page:
            return None
        license_url = license_reference_url(
            license_name, _metadata_value(metadata, "LicenseUrl") or None
        )
        author = artist or "Unknown author"
        attribution = f"{author}, {license_name}, via Wikimedia Commons"
        if credit and credit.casefold() not in {"own work", "self-photographed"}:
            credited_author = credit
            if author.casefold() not in credit.casefold():
                credited_author = f"{author} ({credit})"
            attribution = f"{credited_author}, {license_name}, via Wikimedia Commons"
        return ImageCandidate(
            source="wikimedia",
            source_id=page_id,
            source_page=source_page,
            image_url=image_url,
            download_url=download_url,
            author=author,
            author_url=artist_url,
            license=license_name,
            license_url=license_url,
            attribution=attribution,
            width=int(image_info.get("thumbwidth") or image_info.get("width") or 0),
            height=int(image_info.get("thumbheight") or image_info.get("height") or 0),
            mime_type=mime_type,
            title=str(page.get("title") or "").removeprefix("File:"),
            description=description,
            categories=tuple(categories),
            search_query=query,
        )


def _metadata_value(metadata: dict[str, Any], key: str) -> str:
    item = metadata.get(key)
    if isinstance(item, dict):
        return str(item.get("value") or "").strip()
    return ""
