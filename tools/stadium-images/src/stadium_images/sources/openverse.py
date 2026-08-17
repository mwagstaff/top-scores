from __future__ import annotations

from typing import ClassVar
from urllib.parse import urlparse

from ..http import HTTPClient
from ..models import ImageCandidate, Stadium


class OpenverseSource:
    """Discover non-Wikimedia openly licensed images through Openverse."""

    name = "openverse"
    endpoint = "https://api.openverse.org/v1/images/"
    max_queries_per_stadium = 2
    allowed_licenses: ClassVar[set[str]] = {"cc0", "pdm", "by", "by-sa"}

    def __init__(self, http: HTTPClient) -> None:
        self.http = http
        # Anonymous access currently permits a 20-request burst and 200/day.
        self.http.set_host_interval("api.openverse.org", 3.2)

    @property
    def available(self) -> bool:
        return True

    def search(self, stadium: Stadium, query: str, limit: int) -> list[ImageCandidate]:
        payload = self.http.get_json(
            self.endpoint,
            params={
                "q": query,
                "license": "cc0,pdm,by,by-sa",
                "excluded_source": "wikimedia",
                "aspect_ratio": "wide",
                "mature": "false",
                "page_size": min(max(limit, 1), 20),
            },
        )
        results = payload.get("results", [])
        if not isinstance(results, list):
            return []
        return [
            candidate
            for item in results
            if (candidate := self._parse(item, query)) is not None
        ]

    def before_download(self, candidate: ImageCandidate) -> None:
        return None

    @classmethod
    def _parse(cls, item: object, query: str) -> ImageCandidate | None:
        if not isinstance(item, dict):
            return None
        identifier = str(item.get("id") or "")
        image_url = str(item.get("url") or "")
        source_page = str(item.get("foreign_landing_url") or "")
        license_code = str(item.get("license") or "").casefold()
        license_url = str(item.get("license_url") or "")
        if (
            not identifier
            or not image_url.startswith(("http://", "https://"))
            or not source_page.startswith("https://")
            or license_code not in cls.allowed_licenses
            or not license_url.startswith("https://")
        ):
            return None

        mime_type = _mime_type(item.get("filetype"), image_url)
        if mime_type is None:
            return None
        provider = str(item.get("source") or item.get("provider") or "unknown")
        author = str(item.get("creator") or "Unknown creator")
        title = str(item.get("title") or "")
        tags = tuple(
            str(tag.get("name"))
            for tag in item.get("tags", [])
            if isinstance(tag, dict) and tag.get("name")
        )
        license_name = _license_name(
            license_code,
            str(item.get("license_version") or ""),
        )
        attribution = str(item.get("attribution") or "").strip()
        if not attribution:
            attribution = f"{title or 'Image'} by {author}, {license_name}"
        return ImageCandidate(
            source=f"openverse-{provider}",
            source_id=identifier,
            source_page=source_page,
            image_url=image_url,
            download_url=image_url,
            author=author,
            author_url=str(item.get("creator_url") or "") or None,
            license=license_name,
            license_url=license_url,
            attribution=attribution,
            width=int(item.get("width") or 0),
            height=int(item.get("height") or 0),
            mime_type=mime_type,
            title=title,
            description="",
            categories=tags,
            search_query=query,
        )


def _license_name(code: str, version: str) -> str:
    suffix = f" {version}" if version else ""
    return {
        "cc0": f"CC0{suffix}",
        "pdm": f"Public Domain Mark{suffix}",
        "by": f"CC BY{suffix}",
        "by-sa": f"CC BY-SA{suffix}",
    }[code]


def _mime_type(filetype: object, image_url: str) -> str | None:
    extension = str(filetype or "").casefold().lstrip(".")
    if not extension:
        extension = urlparse(image_url).path.rsplit(".", 1)[-1].casefold()
    return {
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
    }.get(extension)
