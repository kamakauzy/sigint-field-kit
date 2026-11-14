import pytest

import emitter_locator as el

LAT, LON = 40.0, -75.0


def test_haversine_one_degree_latitude():
    assert el.haversine_distance(0, 0, 1, 0) == pytest.approx(111195, rel=1e-3)


def test_bearing_to_point_north_and_east():
    lat, lon = el.bearing_to_point(LAT, LON, 0, 1000)
    assert lon == pytest.approx(LON, abs=1e-9)
    assert el.haversine_distance(LAT, LON, lat, lon) == pytest.approx(1000, rel=1e-6)
    lat, lon = el.bearing_to_point(LAT, LON, 90, 1000)
    assert lat == pytest.approx(LAT, abs=1e-4)
    assert lon > LON


def test_intersect_known_target():
    target = (LAT, LON)
    # Observers 1 km due west and 1 km due south of the target
    west = el.bearing_to_point(*target, 270, 1000)
    south = el.bearing_to_point(*target, 180, 1000)
    obs = [(west[0], west[1], 90.0), (south[0], south[1], 0.0)]
    lat, lon, err = el.intersect_bearings(obs)
    assert el.haversine_distance(lat, lon, *target) < 15
    assert err < 1


def test_intersect_needs_two_positions():
    assert el.intersect_bearings([(LAT, LON, 10.0)]) is None
    assert el.intersect_bearings([(LAT, LON, 10.0), (LAT, LON, 80.0)]) is None


def test_intersect_parallel_bearings_rejected():
    assert el.intersect_bearings([(LAT, LON, 0.0), (LAT, LON + 0.01, 0.0)]) is None


def test_cluster_groups_nearby_bearings():
    bearings = [{"bearing_deg": b} for b in (10.0, 14.0, 200.0)]
    clusters = el.cluster_bearings(bearings, tolerance_deg=10)
    assert clusters[0]["count"] == 2
    assert clusters[0]["mean_bearing"] == pytest.approx(12.0, abs=0.2)


def test_format_compass():
    assert el.format_compass(0) == "N"
    assert el.format_compass(359) == "N"
    assert el.format_compass(90) == "E"
    assert el.format_compass(225) == "SW"
