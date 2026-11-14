"""The climatology adapts to each site: elevation for pressure, latitude for the seasons."""

import pytest

from server import climate


def test_gale_is_unchanged_without_a_site():
    assert climate.pressure_pa(260, 12) == pytest.approx(climate.pressure_pa(260, 12))
    with climate.at_site(climate.GALE_LAT, climate.GALE_ELEV_M):
        inside = climate.air_temp_range(260), climate.pressure_pa(260, 12)
    assert inside == (climate.air_temp_range(260), climate.pressure_pa(260, 12))


def test_higher_sites_have_thinner_air():
    with climate.at_site(18.45, -2540.0):  # Jezero crater floor, ~2 km above Gale
        p = [climate.pressure_pa(ls, 12) for ls in range(0, 360, 30)]
    assert 600 < min(p) and max(p) < 800  # MEDA measures roughly 600-760 Pa at Jezero
    assert max(p) < max(climate.pressure_pa(ls, 12) for ls in range(0, 360, 30))


def test_seasons_follow_the_sites_own_sunlight():
    # Gale (4.6 S) is warmest near perihelion / southern summer; at 18 N that season is much less
    # special, because the noon sun is low there in northern winter.
    gale_swing = climate.air_temp_range(260)[1] - climate.air_temp_range(80)[1]
    with climate.at_site(18.45, -2540.0):
        jez_swing = climate.air_temp_range(260)[1] - climate.air_temp_range(80)[1]
    assert gale_swing > 10 and jez_swing < gale_swing / 2
