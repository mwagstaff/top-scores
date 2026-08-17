import json
import shutil
from pathlib import Path

from PIL import Image
from rich.console import Console

from stadium_images.collector import Collector
from stadium_images.database import StateDatabase
from stadium_images.http import RateLimitError
from stadium_images.models import (
    FilterConfig,
    ImageCandidate,
    League,
    RetentionConfig,
    Stadium,
)


class FakeSource:
    name = "wikimedia"
    available = True

    def __init__(self, image_url: str) -> None:
        self.image_url = image_url

    def search(self, stadium: Stadium, query: str, limit: int) -> list[ImageCandidate]:
        return [
            ImageCandidate(
                source="wikimedia",
                source_id="987",
                source_page="https://commons.wikimedia.org/wiki/File:Stadium.jpg",
                image_url=self.image_url,
                download_url=self.image_url,
                author="Example Photographer",
                author_url="https://commons.wikimedia.org/wiki/User:Example",
                license="CC BY 4.0",
                license_url="https://creativecommons.org/licenses/by/4.0/",
                attribution="Example Photographer, CC BY 4.0, via Wikimedia Commons",
                width=2000,
                height=1200,
                mime_type="image/jpeg",
                title="Test Stadium interior at night",
                description="Wide angle pitch view under floodlights",
                categories=("Test Stadium",),
                search_query=query,
            )
        ]

    def before_download(self, candidate: ImageCandidate) -> None:
        return None


class FakeHTTP:
    def download(self, url: str, destination: Path) -> None:
        shutil.copy2(Path(url), destination)


class RateLimitedHTTP:
    def __init__(self) -> None:
        self.download_attempts = 0

    def download(self, url: str, destination: Path) -> None:
        self.download_attempts += 1
        raise RateLimitError(url, 600)


def test_collection_writes_ranked_output_metadata_and_resume_state(
    tmp_path: Path,
) -> None:
    source_image = tmp_path / "source.jpg"
    Image.new("RGB", (2000, 1200), (20, 30, 45)).save(source_image)
    output = tmp_path / "output"
    stadium = Stadium(
        club="Test FC",
        name="Test Stadium",
        slug="test-stadium",
        aliases=(),
        search_terms=("Test Stadium night",),
    )
    league = League(
        slug="test-league",
        name="Test League",
        season="2026/27",
        membership_source="https://example.com",
        stadiums=(stadium,),
        filters=FilterConfig(min_score=7),
        retention=RetentionConfig(day=1, night=1),
        results_per_query=10,
    )

    with (
        StateDatabase(output / ".state.sqlite3") as database,
        (tmp_path / "console.txt").open("w", encoding="utf-8") as console_output,
    ):
        collector = Collector(
            output_dir=output,
            database=database,
            http=FakeHTTP(),  # type: ignore[arg-type]
            sources={"wikimedia": FakeSource(str(source_image))},
            console=Console(file=console_output),
        )
        collector.collect(league, (stadium,), ("wikimedia",))
        collector.collect(league, (stadium,), ("wikimedia",))

        assert len(database.list_images("test-league", "test-stadium")) == 1

    ranked = output / "test-league" / "test-fc" / "night" / "001.jpg"
    metadata = json.loads(
        (output / "test-league" / "test-fc" / "metadata.json").read_text()
    )
    manifest = json.loads((output / "manifest.json").read_text())
    attributions = (output / "ATTRIBUTIONS.md").read_text()

    assert ranked.exists()
    assert metadata["images"][0]["license"] == "CC BY 4.0"
    assert metadata["images"][0]["download_url"] == str(source_image)
    assert metadata["images"][0]["sha256"]
    assert manifest["leagues"]["test-league"]["stadiums"]["test-fc"]["night"][0][
        "path"
    ].endswith("night/001.jpg")
    assert "Example Photographer" in attributions


def test_collection_stops_rate_limited_provider_and_saves_outputs(
    tmp_path: Path,
) -> None:
    output = tmp_path / "output"
    stadium = Stadium(
        club="Test FC",
        name="Test Stadium",
        slug="test-stadium",
        aliases=(),
        search_terms=("Test Stadium night", "Test Stadium pitch"),
    )
    league = League(
        slug="test-league",
        name="Test League",
        season="2026/27",
        membership_source="https://example.com",
        stadiums=(stadium,),
        filters=FilterConfig(min_score=7),
        results_per_query=10,
    )
    http = RateLimitedHTTP()
    console_path = tmp_path / "console.txt"

    with (
        StateDatabase(output / ".state.sqlite3") as database,
        console_path.open("w", encoding="utf-8") as console_output,
    ):
        Collector(
            output_dir=output,
            database=database,
            http=http,  # type: ignore[arg-type]
            sources={"wikimedia": FakeSource("https://upload.wikimedia.org/test.jpg")},
            console=Console(file=console_output),
        ).collect(league, (stadium,), ("wikimedia",))

        assert database.list_images("test-league", "test-stadium") == []

    assert http.download_attempts == 1
    assert (output / "manifest.json").exists()
    assert "Progress has been saved" in console_path.read_text()
