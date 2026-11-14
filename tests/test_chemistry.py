"""Rover chemistry at the targets (feature E2): parsing the archive's oxide tables, the sols, the placement on the
rover's track, and the API."""

import pytest
from fastapi.testclient import TestClient

from marsgeo.grid import SiteGrid
from pipeline import chemistry as chem
from server.main import app
from server.site_store import get_site, is_built

client = TestClient(app)

MOC_SAMPLE = """sPDL Tool v2.5,Testset Quartiles,SiO2, , , ,TiO2
COMBINED PLS+ICA RESULTS,Min,0.11, , , ,0
File,Target,SiO2,+/-,SiO2 RMSEP,SiO2_shots_stdev,TiO2,+/-,TiO2 RMSEP,TiO2_shots_stdev,Al2O3,+/-,Al2O3 RMSEP,Al2O3_shots_stdev,FeOT,+/-,FeOT RMSEP,FeOT_shots_stdev,MgO,+/-,MgO RMSEP,MgO_shots_stdev,CaO,+/-,CaO RMSEP,CaO_shots_stdev,Na2O,+/-,Na2O RMSEP,Na2O_shots_stdev,K2O,+/-,K2O RMSEP,K2O_shots_stdev,MnO,+/-,MnO RMSEP,MnO_shots_stdev,Sum of Oxides,Distance (m),Laser Power,Spectrum Total
CL5_807009802CCS_F1172850CCAM06611P3.CSV,aegis_post_4613a,51.7,+/-,5,0.5,0.86,+/-,0.46,0.07,10.9,+/-,3.5,0.6,18.4,+/-,3.8,0.5,8.7,+/-,2.4,0.3,1.9,+/-,1,0.1,2.52,+/-,0.62,0.19,1.14,+/-,0.92,0.16,0.1,+/-,0.05,0.01,96.34,2.73126,100A,1
CL5_807009882CCS_F1172850CCAM06611P3.CSV,aegis_post_4613a,48.4,+/-,5,0.8,0.78,+/-,0.44,0.03,10.1,+/-,3.5,0.5,17.6,+/-,3.7,0.5,13.3,+/-,3.1,0.9,1.6,+/-,1,0.2,2.25,+/-,0.62,0.15,0.68,+/-,0.74,0.08,0.11,+/-,0.05,0.02,94.79,2.73126,10,1
"""

SUPERCAM_SAMPLE = """Training set Quartiles,SiO2,,TiO2,,Al2O3,,FeOT,,MgO,,CaO,,Na2O,,K2O,,,,
RMSEP,6.1,,0.3,,1.8,,3.1,,1.1,,1.3,,0.5,,0.6,,,,
cdr_fname,SiO2,SiO2_stdev,TiO2,TiO2_stdev,Al2O3,Al2O3_stdev,FeOT,FeOT_stdev,MgO,MgO_stdev,CaO,CaO_stdev,Na2O,Na2O_stdev,K2O,K2O_stdev,Total,distance_mm,Tot.Em.
scam_0421_0668002890_477_cl1_scam15210_king_salmon_________01p,23.7,1,0.6,0.02,9.1,1.4,32.7,1.5,20.3,0.5,3.4,0.3,1.5,0.3,0.7,0.3,85.2,3126,7.04E+14
scam_0421_0668002950_477_cl1_scam15210_king_salmon_________02p,25.7,1,0.6,0.02,9.3,1.4,30.7,1.5,21.3,0.5,3.2,0.3,1.4,0.3,0.6,0.3,85.0,3130,7.04E+14
scam_0421_0668003001_100_cl1_scam15210_scct_pmian0106________01p,45.7,1,0.6,0.02,9.3,1.4,0.6,1.5,1.2,0.5,6.1,0.3,1.4,0.3,0.6,0.3,86.4,1530,7.04E+14
"""


def test_curiosity_clock_to_sol():
    # the AEGIS target named for sol 4613 was shot at clock 807009802, and the last row of that table on sol 4708
    assert chem.sol_of_sclk(807009802, 137.4, 49269) == 4613
    assert chem.sol_of_sclk(815434678, 137.4, 49269) == 4708


def test_parse_chemcam_moc_and_group():
    rows = chem.parse_moc(MOC_SAMPLE)
    assert len(rows) == 2 and rows[0]["target"] == "aegis_post_4613a" and rows[0]["oxides"]["SiO2"] == 51.7
    assert rows[0]["dist_m"] == pytest.approx(2.73126) and rows[0]["total"] == pytest.approx(96.34)
    t = chem.group_targets(rows, 137.4, 49269)
    assert len(t) == 1 and t[0]["sol"] == 4613 and t[0]["n_points"] == 2
    assert t[0]["oxides"]["SiO2"] == pytest.approx(50.05) and t[0]["oxides"]["MgO"] == pytest.approx(11.0)


def test_parse_supercam_skips_calibration_targets():
    rows = chem.parse_supercam(SUPERCAM_SAMPLE)
    assert {r["target"] for r in rows} == {"King Salmon", "Scct Pmian0106"} and all(r["sol"] == 421 for r in rows)
    t = chem.group_targets(rows, 77.4, 52304)
    assert [x["name"] for x in t] == ["King Salmon"] and t[0]["n_points"] == 2 and "MnO" not in t[0]["oxides"]
    assert t[0]["dist_m"] == pytest.approx(3.128, abs=0.01)


def test_placement_uses_the_rover_position_that_sol():
    g = SiteGrid(lon0=10.0, lat0=0.0, x_min=-500.0, y_max=500.0, res=1.0, width=1000, height=1000)
    a = g.xy_to_lonlat(0.0, 0.0)
    b = g.xy_to_lonlat(200.0, 100.0)
    out_of_site = g.xy_to_lonlat(5000.0, 0.0)
    wps = [(10, float(a[0]), float(a[1])), (12, float(b[0]), float(b[1])), (20, float(out_of_site[0]), float(out_of_site[1]))]
    ts = [{"name": "x", "sol": 11}, {"name": "y", "sol": 12}, {"name": "z", "sol": 12}, {"name": "far", "sol": 25}, {"name": "early", "sol": 3}]
    placed = {t["name"]: t for t in chem.place(ts, wps, g)}
    assert set(placed) == {"x", "y", "z"}   # sol 25: rover outside the site; sol 3: before the first waypoint
    x, y = g.lonlat_to_xy(placed["x"]["lon"], placed["x"]["lat"])
    assert abs(x) < 0.01 and abs(y) < 0.01   # alone on its sol: at the rover
    for k in ("y", "z"):                      # two on one sol: on the 4 m ring round the rover
        x, y = g.lonlat_to_xy(placed[k]["lon"], placed[k]["lat"])
        assert ((x - 200.0) ** 2 + (y - 100.0) ** 2) ** 0.5 == pytest.approx(chem.RING_M, abs=0.05)


@pytest.mark.skipif(not is_built("gale_boxwork") or get_site("gale_boxwork").chemistry is None, reason="no Gale chemistry built")
def test_gale_chemistry_api():
    j = client.get("/api/sites/gale_boxwork/chemistry").json()
    ts = j["targets"]
    assert j["instrument"] == "ChemCam LIBS" and len(ts) > 300
    s = get_site("gale_boxwork")
    lon0, lat0, lon1, lat1 = s.grid.bounds_lonlat()
    assert all(lon0 <= t["lon"] <= lon1 and lat0 <= t["lat"] <= lat1 for t in ts)
    assert all(4200 <= t["sol"] <= 4900 and t["color"].startswith("#") and t["hint"] for t in ts)
    assert sum(1 for t in ts if t["total"] and 80 <= t["total"] <= 110) > 0.8 * len(ts)   # oxide sums near 100 %
    hab = s.cfg["habitat"]
    near = client.get("/api/sites/gale_boxwork/chemistry", params={"lon": hab["lon"], "lat": hab["lat"], "n": 4, "within_m": 400}).json()["targets"]
    d = [t["dist_from_m"] for t in near]
    assert d == sorted(d) and all(v <= 400 for v in d) and len(near) <= 4


@pytest.mark.skipif(not is_built("jezero_threeforks") or get_site("jezero_threeforks").chemistry is None, reason="no Jezero chemistry built")
def test_jezero_chemistry_api():
    j = client.get("/api/sites/jezero_threeforks/chemistry").json()
    assert j["instrument"] == "SuperCam LIBS" and len(j["targets"]) > 100
    assert not any(t["name"].lower().startswith("scct") for t in j["targets"])
