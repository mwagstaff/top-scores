from __future__ import annotations

from typing import ClassVar
from xml.etree import ElementTree

from ..http import HTTPClient
from ..models import ImageCandidate, Stadium

DC = "http://purl.org/dc/elements/1.1/"
CC = "http://web.resource.org/cc/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
LICENSE_URL = "https://creativecommons.org/licenses/by-sa/2.0/"


class GeographSource:
    """Curated football-ground photographs from Geograph Britain and Ireland."""

    name = "geograph"
    max_queries_per_stadium = 1
    article_url = "https://www.geograph.org.uk/article/Football-Grounds"
    curated_images: ClassVar[dict[str, tuple[str, ...]]] = {
        "emirates-stadium": (
            "https://s2.geograph.org.uk/geophotos/02/25/35/2253542_ce82aad8_120x120.jpg",
            "https://s0.geograph.org.uk/geophotos/01/61/27/1612772_f2c90188_120x120.jpg",
        ),
        "villa-park": (
            "https://s1.geograph.org.uk/geophotos/05/64/51/5645185_d177e959_120x120.jpg",
            "https://s0.geograph.org.uk/geophotos/03/77/96/3779644_37933380_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/01/84/91/1849117_26896ec0_120x120.jpg",
        ),
        "vitality-stadium": (
            "https://s0.geograph.org.uk/geophotos/01/22/40/1224028_d674612e_120x120.jpg",
            "https://s3.geograph.org.uk/geophotos/03/36/20/3362087_ff6f174f_120x120.jpg",
            "https://s2.geograph.org.uk/geophotos/07/61/23/7612378_589d49c1_120x120.jpg",
        ),
        "gtech-community-stadium": (
            "https://s3.geograph.org.uk/geophotos/06/36/32/6363263_353e95bc_120x120.jpg",
        ),
        "american-express-stadium": (
            "https://s0.geograph.org.uk/geophotos/02/55/36/2553672_25d0c080_120x120.jpg",
        ),
        "stamford-bridge": (
            "https://s1.geograph.org.uk/geophotos/06/13/48/6134845_0aa7693d_120x120.jpg",
            "https://s2.geograph.org.uk/geophotos/04/41/86/4418606_401bf1fe_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/01/60/87/1608769_958f57ab_120x120.jpg",
        ),
        "selhurst-park": (
            "https://s3.geograph.org.uk/geophotos/02/63/12/2631239_b1d4b9d4_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/05/26/12/5261253_c87f9ab4_120x120.jpg",
            "https://s0.geograph.org.uk/photos/13/87/138704_65b5a396_120x120.jpg",
        ),
        "hill-dickinson-stadium": (
            "https://s0.geograph.org.uk/geophotos/08/10/54/8105428_e06192a2_120x120.jpg",
        ),
        "craven-cottage": (
            "https://s1.geograph.org.uk/geophotos/05/73/53/5735333_27f729e8_120x120.jpg",
            "https://s2.geograph.org.uk/geophotos/04/80/40/4804030_f97bc70a_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/04/21/80/4218033_05b3da7d_120x120.jpg",
        ),
        "elland-road": (
            "https://s3.geograph.org.uk/geophotos/03/85/11/3851155_9abf6b9e_120x120.jpg",
            "https://s0.geograph.org.uk/geophotos/05/97/31/5973184_2cb5251d_120x120.jpg",
            "https://s0.geograph.org.uk/photos/63/15/631544_85adcb86_120x120.jpg",
        ),
        "anfield": (
            "https://s0.geograph.org.uk/geophotos/02/99/93/2999368_127c4230_120x120.jpg",
            "https://s1.geograph.org.uk/photos/09/03/090357_b997d1e0_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/05/54/19/5541901_414672fc_120x120.jpg",
        ),
        "etihad-stadium": (
            "https://s0.geograph.org.uk/geophotos/04/77/17/4771708_31e25c3e_120x120.jpg",
            "https://s0.geograph.org.uk/geophotos/04/37/82/4378272_de8284f3_120x120.jpg",
        ),
        "old-trafford": (
            "https://s2.geograph.org.uk/geophotos/05/63/12/5631234_f1357087_120x120.jpg",
            "https://s3.geograph.org.uk/geophotos/05/86/64/5866415_11415272_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/03/81/41/3814169_07c796cd_120x120.jpg",
        ),
        "st-james-park": (
            "https://s1.geograph.org.uk/photos/34/79/347985_5525d715_120x120.jpg",
            "https://s2.geograph.org.uk/geophotos/03/86/93/3869370_f4b26e4b_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/02/90/66/2906625_702ada89_120x120.jpg",
        ),
        "city-ground": (
            "https://s3.geograph.org.uk/geophotos/05/60/37/5603771_ef3febce_120x120.jpg",
            "https://s1.geograph.org.uk/geophotos/07/55/91/7559113_1aa4ecfd_120x120.jpg",
        ),
        "stadium-of-light": (
            "https://s2.geograph.org.uk/geophotos/06/23/38/6233862_8e05042c_120x120.jpg",
            "https://s0.geograph.org.uk/geophotos/01/69/71/1697188_9b52f76c_120x120.jpg",
        ),
        "tottenham-hotspur-stadium": (
            "https://s1.geograph.org.uk/geophotos/06/23/14/6231417_3ffb0e5a_120x120.jpg",
            "https://s0.geograph.org.uk/geophotos/06/23/14/6231412_e1c31931_120x120.jpg",
        ),
    }

    def __init__(self, http: HTTPClient) -> None:
        self.http = http
        self.http.set_host_interval("www.geograph.org.uk", 0.5)
        for host_index in range(4):
            self.http.set_host_interval(f"s{host_index}.geograph.org.uk", 0.5)

    @property
    def available(self) -> bool:
        return True

    def search(self, stadium: Stadium, query: str, limit: int) -> list[ImageCandidate]:
        candidates: list[ImageCandidate] = []
        for thumbnail_url in self.curated_images.get(stadium.slug, ())[:limit]:
            photo_id = _photo_id(thumbnail_url)
            metadata = self.http.get_text(
                f"https://www.geograph.org.uk/photo/{photo_id}.rdf"
            )
            candidate = self._parse_rdf(metadata, stadium, thumbnail_url, query)
            if candidate is not None:
                candidates.append(candidate)
        return candidates

    def before_download(self, candidate: ImageCandidate) -> None:
        return None

    @staticmethod
    def _parse_rdf(
        value: str,
        stadium: Stadium,
        thumbnail_url: str,
        query: str,
    ) -> ImageCandidate | None:
        root = ElementTree.fromstring(value)
        work = root.find(f"{{{CC}}}Work")
        if work is None:
            return None
        title = work.findtext(f"{{{DC}}}title", default="").strip()
        author = work.findtext(
            f"{{{DC}}}creator/{{{CC}}}Agent/{{{DC}}}title", default=""
        ).strip()
        license_element = work.find(f"{{{CC}}}license")
        license_url = (
            license_element.get(f"{{{RDF}}}resource", "")
            if license_element is not None
            else ""
        ).replace("http://", "https://", 1)
        photo_id = _photo_id(thumbnail_url)
        if not title or not author or license_url != LICENSE_URL:
            return None
        return ImageCandidate(
            source="geograph",
            source_id=photo_id,
            source_page=f"https://www.geograph.org.uk/photo/{photo_id}",
            image_url=_original_url(thumbnail_url),
            download_url=_original_url(thumbnail_url),
            author=author,
            author_url=None,
            license="CC BY-SA 2.0",
            license_url=LICENSE_URL,
            attribution=f"© {author}, CC BY-SA 2.0, via Geograph Britain and Ireland",
            # Geograph's RDF does not expose dimensions. The downloaded original is
            # verified before scoring and rejected if it is below the configured size.
            width=1600,
            height=900,
            mime_type="image/jpeg",
            title=title,
            description=f"Curated photograph of {stadium.name}, {stadium.club}",
            categories=("Football stadium", "Geograph curated football grounds"),
            search_query=query,
        )


def _photo_id(url: str) -> str:
    return url.rsplit("/", 1)[-1].split("_", 1)[0].lstrip("0")


def _original_url(url: str) -> str:
    return url.replace("_120x120.jpg", "_original.jpg")
