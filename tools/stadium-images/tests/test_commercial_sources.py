from stadium_images.sources.openverse import OpenverseSource
from stadium_images.sources.pexels import PexelsSource
from stadium_images.sources.unsplash import UnsplashSource


def test_openverse_parsing_preserves_original_source_and_cc_attribution() -> None:
    candidate = OpenverseSource._parse(
        {
            "id": "flickr-photo-123",
            "title": "Villa Park panorama",
            "creator": "Jane Smith",
            "creator_url": "https://www.flickr.com/photos/jane/",
            "source": "flickr",
            "foreign_landing_url": "https://www.flickr.com/photos/jane/123/",
            "url": "https://live.staticflickr.com/123/stadium_b.jpg",
            "license": "by",
            "license_version": "2.0",
            "license_url": "https://creativecommons.org/licenses/by/2.0/",
            "attribution": "Villa Park panorama by Jane Smith, CC BY 2.0",
            "width": 3000,
            "height": 1800,
            "filetype": "jpg",
            "tags": [{"name": "villa park"}, {"name": "stadium"}],
        },
        "Villa Park stadium",
    )

    assert candidate is not None
    assert candidate.source == "openverse-flickr"
    assert candidate.source_page == "https://www.flickr.com/photos/jane/123/"
    assert candidate.license == "CC BY 2.0"
    assert candidate.license_url == "https://creativecommons.org/licenses/by/2.0/"
    assert candidate.download_url == "https://live.staticflickr.com/123/stadium_b.jpg"


def test_openverse_rejects_non_commercial_creative_commons_licenses() -> None:
    candidate = OpenverseSource._parse(
        {
            "id": "photo-456",
            "source": "flickr",
            "foreign_landing_url": "https://www.flickr.com/photos/jane/456/",
            "url": "https://live.staticflickr.com/456/stadium.jpg",
            "license": "by-nc",
            "license_url": "https://creativecommons.org/licenses/by-nc/2.0/",
            "width": 3000,
            "height": 1800,
            "filetype": "jpg",
        },
        "stadium",
    )

    assert candidate is None


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
