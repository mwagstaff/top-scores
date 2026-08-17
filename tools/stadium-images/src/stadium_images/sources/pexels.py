from __future__ import annotations

import os

from ..http import HTTPClient
from ..models import ImageCandidate, Stadium


class PexelsSource:
    name = "pexels"
    max_queries_per_stadium = None
    endpoint = "https://api.pexels.com/v1/search"

    def __init__(self, http: HTTPClient, api_key: str | None = None) -> None:
        self.http = http
        self.api_key = api_key or os.getenv("PEXELS_API_KEY")

    @property
    def available(self) -> bool:
        return bool(self.api_key)

    def search(self, stadium: Stadium, query: str, limit: int) -> list[ImageCandidate]:
        if not self.api_key:
            return []
        payload = self.http.get_json(
            self.endpoint,
            params={
                "query": query,
                "per_page": min(max(limit, 1), 80),
                "orientation": "landscape",
            },
            headers={"Authorization": self.api_key},
        )
        photos = payload.get("photos", [])
        if not isinstance(photos, list):
            return []
        return [
            candidate
            for item in photos
            if (candidate := self._parse(item, query)) is not None
        ]

    def before_download(self, candidate: ImageCandidate) -> None:
        return None

    @staticmethod
    def _parse(item: object, query: str) -> ImageCandidate | None:
        if not isinstance(item, dict):
            return None
        identifier = str(item.get("id") or "")
        source_page = str(item.get("url") or "")
        source_images = item.get("src") or {}
        if not isinstance(source_images, dict):
            return None
        image_url = str(source_images.get("original") or "")
        if not identifier or not source_page or not image_url:
            return None
        author = str(item.get("photographer") or "Unknown photographer")
        description = str(item.get("alt") or "")
        return ImageCandidate(
            source="pexels",
            source_id=identifier,
            source_page=source_page,
            image_url=image_url,
            download_url=image_url,
            author=author,
            author_url=str(item.get("photographer_url") or "") or None,
            license="Pexels License",
            license_url="https://www.pexels.com/license/",
            attribution=f"Photo by {author} on Pexels",
            width=int(item.get("width") or 0),
            height=int(item.get("height") or 0),
            mime_type="image/jpeg",
            title=description,
            description=description,
            categories=(),
            search_query=query,
        )
