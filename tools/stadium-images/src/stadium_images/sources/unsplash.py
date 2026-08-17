from __future__ import annotations

import os

from ..http import HTTPClient
from ..models import ImageCandidate, Stadium


class UnsplashSource:
    name = "unsplash"
    max_queries_per_stadium = None
    endpoint = "https://api.unsplash.com/search/photos"

    def __init__(self, http: HTTPClient, access_key: str | None = None) -> None:
        self.http = http
        self.access_key = access_key or os.getenv("UNSPLASH_ACCESS_KEY")

    @property
    def available(self) -> bool:
        return bool(self.access_key)

    def search(self, stadium: Stadium, query: str, limit: int) -> list[ImageCandidate]:
        if not self.access_key:
            return []
        payload = self.http.get_json(
            self.endpoint,
            params={
                "query": query,
                "per_page": min(max(limit, 1), 30),
                "orientation": "landscape",
            },
            headers={"Authorization": f"Client-ID {self.access_key}"},
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
        if candidate.tracking_url and self.access_key:
            self.http.notify_download(
                candidate.tracking_url,
                headers={"Authorization": f"Client-ID {self.access_key}"},
            )

    @staticmethod
    def _parse(item: object, query: str) -> ImageCandidate | None:
        if not isinstance(item, dict):
            return None
        identifier = str(item.get("id") or "")
        links = item.get("links") or {}
        urls = item.get("urls") or {}
        user = item.get("user") or {}
        if not all(isinstance(value, dict) for value in (links, urls, user)):
            return None
        image_url = str(urls.get("raw") or urls.get("full") or "")
        source_page = _attribution_url(str(links.get("html") or ""))
        if not identifier or not image_url or not source_page:
            return None
        user_links = user.get("links") or {}
        if not isinstance(user_links, dict):
            user_links = {}
        description = str(item.get("description") or item.get("alt_description") or "")
        author = str(user.get("name") or user.get("username") or "Unknown photographer")
        return ImageCandidate(
            source="unsplash",
            source_id=identifier,
            source_page=source_page,
            image_url=image_url,
            download_url=_append_parameters(image_url, "fm=jpg&q=90"),
            author=author,
            author_url=_attribution_url(str(user_links.get("html") or "")) or None,
            license="Unsplash License",
            license_url="https://unsplash.com/license",
            attribution=f"Photo by {author} on Unsplash",
            width=int(item.get("width") or 0),
            height=int(item.get("height") or 0),
            mime_type="image/jpeg",
            title=description,
            description=description,
            categories=(),
            search_query=query,
            tracking_url=str(links.get("download_location") or "") or None,
        )


def _append_parameters(url: str, parameters: str) -> str:
    return f"{url}{'&' if '?' in url else '?'}{parameters}"


def _attribution_url(url: str) -> str:
    if not url:
        return ""
    return _append_parameters(url, "utm_source=top_scores&utm_medium=referral")
