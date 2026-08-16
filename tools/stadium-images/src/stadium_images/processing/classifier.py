from __future__ import annotations

from pathlib import Path
from typing import Protocol

from PIL import Image, ImageStat

from ..models import ClassificationResult, ImageCandidate


class ImageClassifier(Protocol):
    def classify(
        self, image_path: Path, candidate: ImageCandidate
    ) -> ClassificationResult: ...


class HeuristicImageClassifier:
    night_keywords = ("night", "nighttime", "floodlight", "after dark")
    twilight_keywords = ("twilight", "dusk", "sunset", "evening", "blue hour")
    day_keywords = ("daytime", "daylight", "sunny", "sunshine", "afternoon")

    def classify(
        self, image_path: Path, candidate: ImageCandidate
    ) -> ClassificationResult:
        luminance = self._average_luminance(image_path)
        keyword_result = self._classify_keywords(candidate.searchable_text.casefold())

        if keyword_result is not None:
            label, keyword = keyword_result
            confidence = 0.82
            if (
                label == "night"
                and luminance <= 0.35
                or label == "day"
                and luminance >= 0.43
            ):
                confidence = 0.92
            elif label == "twilight" and 0.18 <= luminance <= 0.55:
                confidence = 0.88
            return ClassificationResult(
                time_of_day=label,
                confidence=confidence,
                reasons=(
                    f"metadata keyword: {keyword}",
                    f"average luminance: {luminance:.2f}",
                ),
            )

        query_result = self._classify_keywords(candidate.search_query.casefold())
        if query_result is not None:
            query_label, query_keyword = query_result
            if query_label == "night" and luminance < 0.28:
                return ClassificationResult(
                    "night",
                    0.68,
                    (
                        f"search keyword: {query_keyword}",
                        f"low average luminance: {luminance:.2f}",
                    ),
                )
            if query_label == "day" and luminance >= 0.43:
                return ClassificationResult(
                    "day",
                    0.66,
                    (
                        f"search keyword: {query_keyword}",
                        f"high average luminance: {luminance:.2f}",
                    ),
                )

        if luminance < 0.20:
            return ClassificationResult(
                "night", 0.78, (f"low average luminance: {luminance:.2f}",)
            )
        if luminance < 0.36:
            return ClassificationResult(
                "twilight", 0.58, (f"mid-low average luminance: {luminance:.2f}",)
            )
        if luminance >= 0.48:
            return ClassificationResult(
                "day", 0.72, (f"high average luminance: {luminance:.2f}",)
            )
        return ClassificationResult(
            "unknown", 0.35, (f"ambiguous average luminance: {luminance:.2f}",)
        )

    def _classify_keywords(self, text: str) -> tuple[str, str] | None:
        for label, keywords in (
            ("night", self.night_keywords),
            ("twilight", self.twilight_keywords),
            ("day", self.day_keywords),
        ):
            for keyword in keywords:
                if keyword in text:
                    return label, keyword
        return None

    @staticmethod
    def _average_luminance(image_path: Path) -> float:
        with Image.open(image_path) as image:
            sample = image.convert("RGB")
            sample.thumbnail((256, 256))
            red, green, blue = ImageStat.Stat(sample).mean
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
