from pathlib import Path

import pytest

from stadium_images.config import ConfigError, find_stadium, load_league

CONFIG_DIR = Path(__file__).resolve().parents[1] / "config"


def test_premier_league_config_has_current_twenty_clubs() -> None:
    league = load_league("premier-league", CONFIG_DIR)

    assert league.season == "2026/27"
    assert len(league.stadiums) == 20
    assert league.retention.total == 20
    assert {stadium.club for stadium in league.stadiums} >= {
        "Coventry City",
        "Hull City",
        "Ipswich Town",
    }
    assert all(len(stadium.search_terms) > 1 for stadium in league.stadiums)


def test_find_stadium_accepts_club_slug_and_alias() -> None:
    league = load_league("premier-league", CONFIG_DIR)

    assert find_stadium(league, "Arsenal").name == "Emirates Stadium"
    assert find_stadium(league, "anfield").club == "Liverpool"
    assert find_stadium(league, "newcastle-united").name == "St James' Park"
    assert find_stadium(league, "Bramley-Moore Dock").club == "Everton"


def test_unknown_stadium_is_explicit() -> None:
    league = load_league("premier-league", CONFIG_DIR)

    with pytest.raises(ConfigError, match="No stadium or club matching"):
        find_stadium(league, "Made Up Ground")


def test_major_european_venue_config_is_expansion_ready() -> None:
    league = load_league("major-european-venues", CONFIG_DIR)

    assert league.season == "2026/27"
    assert len(league.stadiums) == 24
    assert league.retention.total == 12
    assert {stadium.name for stadium in league.stadiums} >= {
        "Spotify Camp Nou",
        "Santiago Bernabéu Stadium",
        "Allianz Arena",
        "San Siro",
        "Parc des Princes",
        "Estádio da Luz",
        "Celtic Park",
    }
    assert all(len(stadium.search_terms) >= 5 for stadium in league.stadiums)


def test_championship_config_has_current_twenty_four_clubs() -> None:
    league = load_league("championship", CONFIG_DIR)

    assert league.season == "2026/27"
    assert len(league.stadiums) == 24
    assert league.retention.total == 10
    assert {stadium.club for stadium in league.stadiums} >= {
        "Wolverhampton Wanderers",
        "Bolton Wanderers",
        "Lincoln City",
        "West Ham United",
        "Wrexham",
    }
    assert all(len(stadium.search_terms) >= 5 for stadium in league.stadiums)
