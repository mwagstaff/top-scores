from stadium_images.sources.wikimedia import (
    WikimediaSource,
    clean_html,
    license_allowed,
)


def test_license_allowlist_is_explicit() -> None:
    assert license_allowed("CC0 1.0")
    assert license_allowed("Public domain")
    assert license_allowed("CC BY 4.0")
    assert license_allowed("CC BY-SA 3.0")
    assert not license_allowed("CC BY-NC 4.0")
    assert not license_allowed("CC BY-ND 4.0")
    assert not license_allowed("")


def test_clean_html_preserves_artist_link() -> None:
    text, link = clean_html('<a href="https://example.com/jane">Jane Smith</a>')

    assert text == "Jane Smith"
    assert link == "https://example.com/jane"


def test_wikimedia_page_parsing_preserves_provenance() -> None:
    page = {
        "pageid": 12345,
        "title": "File:Emirates Stadium at night.jpg",
        "categories": [{"title": "Category:Emirates Stadium"}],
        "imageinfo": [
            {
                "url": "https://upload.wikimedia.org/example.jpg",
                "thumburl": "https://upload.wikimedia.org/example-3840px.jpg",
                "descriptionurl": "https://commons.wikimedia.org/wiki/File:Example.jpg",
                "width": 4000,
                "height": 2400,
                "thumbwidth": 3840,
                "thumbheight": 2304,
                "mime": "image/jpeg",
                "extmetadata": {
                    "LicenseShortName": {"value": "CC BY-SA 4.0"},
                    "LicenseUrl": {
                        "value": "https://creativecommons.org/licenses/by-sa/4.0/"
                    },
                    "Artist": {
                        "value": '<a href="https://example.com/jane">Jane Smith</a>'
                    },
                    "Credit": {"value": "Jane Smith / Wikimedia Commons"},
                    "ImageDescription": {
                        "value": "Interior with the pitch and floodlights"
                    },
                },
            }
        ],
    }

    candidate = WikimediaSource._parse_page(page, "Emirates Stadium night")

    assert candidate is not None
    assert candidate.id == "wikimedia_12345"
    assert candidate.author == "Jane Smith"
    assert candidate.license == "CC BY-SA 4.0"
    assert candidate.categories == ("Emirates Stadium",)
    assert candidate.source_page.startswith("https://commons.wikimedia.org/")
    assert candidate.image_url == "https://upload.wikimedia.org/example.jpg"
    assert candidate.download_url == ("https://upload.wikimedia.org/example-3840px.jpg")
    assert (candidate.width, candidate.height) == (3840, 2304)
    assert candidate.attribution == (
        "Jane Smith / Wikimedia Commons, CC BY-SA 4.0, via Wikimedia Commons"
    )


def test_wikimedia_page_with_unknown_license_is_skipped() -> None:
    page = {
        "pageid": 1,
        "imageinfo": [
            {
                "url": "https://upload.wikimedia.org/example.jpg",
                "descriptionurl": "https://commons.wikimedia.org/wiki/File:Example.jpg",
                "width": 4000,
                "height": 2400,
                "mime": "image/jpeg",
                "extmetadata": {"LicenseShortName": {"value": "Unknown"}},
            }
        ],
    }

    assert WikimediaSource._parse_page(page, "Example Stadium") is None
