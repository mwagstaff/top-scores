from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Literal

TimeOfDay = Literal["day", "night", "twilight", "unknown"]


@dataclass(frozen=True)
class FilterConfig:
    min_width: int = 1600
    min_height: int = 900
    min_aspect_ratio: float = 1.3
    preferred_aspect_ratio_min: float = 1.5
    preferred_aspect_ratio_max: float = 2.4
    min_score: float = 7.0
    perceptual_hash_distance: int = 6


@dataclass(frozen=True)
class RetentionConfig:
    day: int = 30
    night: int = 30
    twilight: int = 15
    unknown: int = 10

    def limit_for(self, time_of_day: TimeOfDay) -> int:
        return int(getattr(self, time_of_day))


@dataclass(frozen=True)
class Stadium:
    club: str
    name: str
    slug: str
    aliases: tuple[str, ...]
    search_terms: tuple[str, ...]
    latitude: float | None = None
    longitude: float | None = None


@dataclass(frozen=True)
class League:
    slug: str
    name: str
    season: str
    membership_source: str
    stadiums: tuple[Stadium, ...]
    filters: FilterConfig = field(default_factory=FilterConfig)
    retention: RetentionConfig = field(default_factory=RetentionConfig)
    results_per_query: int = 30


@dataclass(frozen=True)
class ImageCandidate:
    source: str
    source_id: str
    source_page: str
    image_url: str
    download_url: str
    author: str
    author_url: str | None
    license: str
    license_url: str | None
    attribution: str
    width: int
    height: int
    mime_type: str
    title: str
    description: str
    categories: tuple[str, ...]
    search_query: str
    tracking_url: str | None = None

    @property
    def id(self) -> str:
        safe_id = "".join(
            character if character.isalnum() or character in "-_" else "_"
            for character in str(self.source_id)
        )
        return f"{self.source}_{safe_id}"

    @property
    def aspect_ratio(self) -> float:
        return self.width / self.height if self.height else 0.0

    @property
    def searchable_text(self) -> str:
        return " ".join((self.title, self.description, *self.categories))


@dataclass(frozen=True)
class ClassificationResult:
    time_of_day: TimeOfDay
    confidence: float
    reasons: tuple[str, ...]


@dataclass(frozen=True)
class ScoreResult:
    score: float
    reasons: tuple[str, ...]


@dataclass
class ImageRecord:
    id: str
    league: str
    stadium_slug: str
    stadium: str
    club: str
    source: str
    source_id: str
    source_page: str
    image_url: str
    download_url: str
    title: str
    description: str
    categories: tuple[str, ...]
    mime_type: str
    author: str
    author_url: str | None
    license: str
    license_url: str | None
    attribution: str
    width: int
    height: int
    orientation: str
    time_of_day: TimeOfDay
    classification_confidence: float
    classification_reasons: tuple[str, ...]
    score: float
    score_reasons: tuple[str, ...]
    identity_confidence: float
    sha256: str
    perceptual_hash: str
    local_original_path: str
    search_query: str
    downloaded_at: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, values: dict[str, Any]) -> ImageRecord:
        values = dict(values)
        values.setdefault("download_url", values.get("image_url", ""))
        values["classification_reasons"] = tuple(
            values.get("classification_reasons", ())
        )
        values["score_reasons"] = tuple(values.get("score_reasons", ()))
        values["categories"] = tuple(values.get("categories", ()))
        return cls(**values)
