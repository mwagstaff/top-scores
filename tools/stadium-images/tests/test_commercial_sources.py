from stadium_images.sources.pexels import PexelsSource
from stadium_images.sources.unsplash import UnsplashSource


def test_unsplash_parsing_preserves_tracking_and_attribution_links() -> None:
    candidate = UnsplashSource._parse(
        {
            "id": "photo-123",
            "width": 4000,
            "height": 2400,
            "description": "Anfield stadium at night",
            "urls": {"raw": "https://images.unsplash.com/photo-123?ixid=abc"},
            "links": {
                "html": "https://unsplash.com/photos/photo-123",
                "download_location": "https://api.unsplash.com/photos/photo-123/download?ixid=abc",
            },
            "user": {
                "name": "Jane Smith",
                "links": {"html": "https://unsplash.com/@jane"},
            },
        },
        "Anfield stadium",
    )

    assert candidate is not None
    assert candidate.tracking_url.endswith("ixid=abc")
    assert "utm_source=top_scores" in candidate.source_page
    assert candidate.author_url is not None
    assert "utm_medium=referral" in candidate.author_url
    assert candidate.license_url == "https://unsplash.com/license"


def test_pexels_parsing_preserves_photo_and_photographer_links() -> None:
    candidate = PexelsSource._parse(
        {
            "id": 987,
            "width": 3600,
            "height": 2100,
            "url": "https://www.pexels.com/photo/stadium-987/",
            "photographer": "John Smith",
            "photographer_url": "https://www.pexels.com/@john",
            "alt": "Old Trafford interior",
            "src": {"original": "https://images.pexels.com/photos/987/original.jpeg"},
        },
        "Old Trafford",
    )

    assert candidate is not None
    assert candidate.id == "pexels_987"
    assert candidate.attribution == "Photo by John Smith on Pexels"
    assert candidate.source_page == "https://www.pexels.com/photo/stadium-987/"
    assert candidate.license_url == "https://www.pexels.com/license/"
