from pathlib import Path

from PIL import Image

from stadium_images.database import StateDatabase
from stadium_images.models import League, Stadium
from stadium_images.processing.review import create_review_sheet


def test_empty_review_sheet_keeps_a_labelled_row_for_every_stadium(
    tmp_path: Path,
) -> None:
    stadium = Stadium(
        club="Test FC",
        name="Test Stadium",
        slug="test-stadium",
        aliases=(),
        search_terms=("Test Stadium",),
    )
    league = League(
        slug="test-league",
        name="Test League",
        season="2026/27",
        membership_source="https://example.com",
        stadiums=(stadium,),
    )
    output = tmp_path / "output"
    destination = output / "review" / "test-league.jpg"

    with StateDatabase(output / ".state.sqlite3") as database:
        count = create_review_sheet(output, database, league, destination)

    assert count == 0
    with Image.open(destination) as sheet:
        assert sheet.size == (960, 234)
