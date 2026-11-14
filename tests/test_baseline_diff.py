from pathlib import Path

import baseline_diff as bd

FIX = Path(__file__).parent / "fixtures"


def _groups(name):
    return bd.analyze_baseline(bd.parse_rtl433_csv(FIX / name))


def test_parse_and_group():
    groups = _groups("baseline_old.csv")
    assert groups["Acurite-Tower|101|1"]["count"] == 2
    assert groups["Acurite-Tower|101|1"]["avg_rssi"] == -61


def test_diff_detects_new_gone_and_power_change():
    report = bd.diff_baselines(_groups("baseline_old.csv"), _groups("baseline_new.csv"), 6.0)
    assert [s["fingerprint"] for s in report["new_signals"]] == ["Honeywell-Door|55|3"]
    assert [s["fingerprint"] for s in report["disappeared"]] == ["Oregon-THGR|7|2"]
    change = report["power_changes"][0]
    assert change["fingerprint"] == "Acurite-Tower|101|1"
    assert change["delta"] == 20


def test_threshold_suppresses_small_changes():
    report = bd.diff_baselines(_groups("baseline_old.csv"), _groups("baseline_new.csv"), 25.0)
    assert report["power_changes"] == []


def test_safe_float():
    assert bd._safe_float("-12.5") == -12.5
    assert bd._safe_float("") is None
