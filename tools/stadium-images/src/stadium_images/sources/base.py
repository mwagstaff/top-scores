from __future__ import annotations

from typing import Protocol

from ..models import ImageCandidate, Stadium


class ImageSource(Protocol):
    name: str

    @property
    def available(self) -> bool: ...

    def search(
        self, stadium: Stadium, query: str, limit: int
    ) -> list[ImageCandidate]: ...

    def before_download(self, candidate: ImageCandidate) -> None: ...
