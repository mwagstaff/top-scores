from stadium_images.models import Stadium
from stadium_images.sources.geograph import GeographSource


def test_geograph_rdf_preserves_author_license_and_original_page() -> None:
    candidate = GeographSource._parse_rdf(
        """<?xml version="1.0"?>
        <rdf:RDF xmlns="http://web.resource.org/cc/"
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <Work rdf:about="https://www.geograph.org.uk/photo/2253542">
            <dc:title>TQ3185 : The Emirates Stadium</dc:title>
            <dc:creator><Agent><dc:title>Martin Addison</dc:title></Agent></dc:creator>
            <license rdf:resource="http://creativecommons.org/licenses/by-sa/2.0/" />
          </Work>
        </rdf:RDF>""",
        Stadium(
            club="Arsenal",
            name="Emirates Stadium",
            slug="emirates-stadium",
            aliases=(),
            search_terms=("Emirates Stadium Arsenal",),
        ),
        "https://s2.geograph.org.uk/geophotos/02/25/35/2253542_ce82aad8_120x120.jpg",
        "Emirates Stadium Arsenal",
    )

    assert candidate is not None
    assert candidate.source_id == "2253542"
    assert candidate.author == "Martin Addison"
    assert candidate.license == "CC BY-SA 2.0"
    assert candidate.source_page == "https://www.geograph.org.uk/photo/2253542"
    assert candidate.download_url.endswith("2253542_ce82aad8_original.jpg")
