"""Suit atmosphere model: suit pressure, ppO2 and inspired CO2 (NASA-STD-3001 Vol 2 [V2 11035/11036/11040])."""

import pytest

from server import eva


def test_ppco2_low_with_a_fresh_scrubber_and_rises_near_capacity():
    assert eva.ppco2_mmhg(300.0, 10.0) == pytest.approx(1.6)          # washout only, under 2 mmHg
    assert eva.ppco2_mmhg(300.0, 70.0) == pytest.approx(1.6)          # breakthrough starts after 70 %
    assert eva.ppco2_mmhg(300.0, 100.0) == pytest.approx(1.6 + 20.0)  # saturated cartridge
    assert eva.ppco2_mmhg(600.0, 50.0) > eva.ppco2_mmhg(300.0, 50.0)  # harder work, more CO2 in the helmet
    assert eva.ppco2_mmhg(300.0, 100.0) > eva.PPCO2_WARNING


def test_ppo2_is_suit_pressure_minus_water_vapour_and_co2():
    assert eva.ppo2_kpa(eva.SUIT_P_KPA, 0.0) == pytest.approx(eva.SUIT_P_KPA - eva.PPH2O_KPA)
    assert eva.ppo2_kpa(eva.SUIT_P_KPA, 7.5) == pytest.approx(eva.SUIT_P_KPA - eva.PPH2O_KPA - 1.0, abs=1e-3)
    assert eva.ppo2_kpa(eva.SUIT_P_KPA, 0.0) > 21.0   # well above sea-level oxygen pressure


def _summary(pc):
    return {"min_margin_min": 60.0, "limiting": "O2", "max_ppco2_mmhg": pc}


def test_go_no_go_checks_the_planned_co2():
    events = [{"kind": "egress", "t0": 0, "t1": 900}, {"kind": "ingress", "t0": 5000, "t1": 5900}]
    go, issues = eva.go_no_go(_summary(4.0), {}, events, [], None, None)
    assert go and not any("CO2" in i["text"] for i in issues)
    go, issues = eva.go_no_go(_summary(17.0), {}, events, [], None, None)
    assert go and any("CO2" in i["text"] and i["level"] == "caution" for i in issues)
    go, issues = eva.go_no_go(_summary(24.0), {}, events, [], None, None)
    assert not go and any("20 mmHg" in i["text"] for i in issues)
