"""0/360 wraparound tests for bearing math (circular statistics)."""
from types import SimpleNamespace

import pytest

import bearing_math as bm
import emitter_locator as el
import intel_packager as ip

DEG = "\u00b0"


# --- bearing_math primitives -------------------------------------------------

@pytest.mark.parametrize("angles, expected", [
    ([359, 1], 0.0),
    ([350, 10], 0.0),
    ([355, 357, 359, 1, 3, 5], 0.0),
    ([10, 20], 15.0),
    ([170, 190], 180.0),
    ([-1, 1], 0.0),
    ([719, 361], 0.0),
    ([270], 270.0),
])
def test_circular_mean_wraps(angles, expected):
    m = bm.circular_mean_deg(angles)
    assert bm.angular_distance_deg(m, expected) == pytest.approx(0, abs=1e-6)
    assert 0 <= m < 360


def test_circular_mean_undefined_and_empty():
    assert bm.circular_mean_deg([]) is None
    assert bm.circular_mean_deg([0, 180]) is None


@pytest.mark.parametrize("a, b, expected", [
    (1, 359, 2.0),
    (359, 1, -2.0),
    (10, 350, 20.0),
    (350, 10, -20.0),
    (90, 45, 45.0),
    (0, 180, -180.0),
    (180, 0, -180.0),
    (720, 0, 0.0),
])
def test_angular_diff_wraps_to_half_open_range(a, b, expected):
    d = bm.angular_diff_deg(a, b)
    assert d == pytest.approx(expected)
    assert -180 <= d < 180


def test_angular_distance_symmetric():
    assert bm.angular_distance_deg(1, 359) == pytest.approx(2)
    assert bm.angular_distance_deg(359, 1) == pytest.approx(2)


def test_normalize():
    assert bm.normalize_deg(360) == 0.0
    assert bm.normalize_deg(-90) == 270.0
    assert bm.normalize_deg(-1e-18) == 0.0


def test_circular_std_small_across_north():
    assert bm.circular_std_deg([359, 1]) == pytest.approx(1.0, abs=0.05)
    assert bm.circular_std_deg([5, 5, 5]) == 0.0


def test_circular_range_across_north():
    lo, hi, width = bm.circular_range_deg([350, 5, 10])
    assert (lo, hi) == (350.0, 10.0)
    assert width == pytest.approx(20.0)
    assert bm.circular_range_deg([42]) == (42.0, 42.0, 0.0)


# --- emitter_locator.cluster_bearings ----------------------------------------

def _b(*vals):
    return [{"bearing_deg": float(v)} for v in vals]


def test_cluster_north_emitter_not_split_by_other_emitters():
    # Before the fix: [1.5 x2], [358.5 x2], [100 x1] -- north emitter cut in two.
    clusters = el.cluster_bearings(_b(358, 359, 1, 2, 100), tolerance_deg=10)
    assert len(clusters) == 2
    north = clusters[0]
    assert north["count"] == 4
    assert bm.angular_distance_deg(north["mean_bearing"], 0) < 0.2
    assert north["std_dev"] < 3


def test_cluster_symmetric_spread_over_north():
    clusters = el.cluster_bearings(_b(355, 357, 359, 1, 3, 5, 180), tolerance_deg=10)
    assert clusters[0]["count"] == 6
    assert bm.angular_distance_deg(clusters[0]["mean_bearing"], 0) < 0.2
    assert clusters[1]["count"] == 1
    assert clusters[1]["mean_bearing"] == pytest.approx(180)


def test_cluster_mean_bearing_in_range():
    for c in el.cluster_bearings(_b(359.96, 359.99, 0.01), tolerance_deg=5):
        assert 0 <= c["mean_bearing"] < 360


def test_cluster_two_separate_emitters_unchanged():
    clusters = el.cluster_bearings(_b(10, 12, 14, 200, 202), tolerance_deg=10)
    assert [c["count"] for c in clusters] == [3, 2]
    assert clusters[0]["mean_bearing"] == pytest.approx(12.0, abs=0.2)
    assert clusters[1]["mean_bearing"] == pytest.approx(201.0, abs=0.2)


def test_cluster_negative_and_over_360_inputs():
    clusters = el.cluster_bearings(_b(-2, 362, 0), tolerance_deg=10)
    assert len(clusters) == 1 and clusters[0]["count"] == 3
    assert bm.angular_distance_deg(clusters[0]["mean_bearing"], 0) < 0.2


# --- intel_packager triangulation summary ------------------------------------

def test_intel_report_bearing_spread_wraps():
    bearings = [
        {"time": "t1", "freq": "146.940", "bearing": 358.0, "confidence": ""},
        {"time": "t2", "freq": "146.940", "bearing": 2.0, "confidence": ""},
    ]
    args = SimpleNamespace(title=None, location=None)
    report = ip.generate_report([], [], bearings, None, args)
    line = next(l for l in report.splitlines() if "146.940 MHz: 2 bearings" in l)
    assert "mean 0" + DEG in line
    assert "spread 4" + DEG in line
    assert "358" + DEG + " \u2013 2" + DEG in line
