import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

import freq_identify

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "build_freq_db.py"


@pytest.fixture(scope="module")
def offline_db(tmp_path_factory):
    db = tmp_path_factory.mktemp("db") / "freq.sqlite"
    subprocess.run([sys.executable, str(SCRIPT), "--db", str(db), "--offline"],
                   check=True, capture_output=True)
    return db


def test_offline_seed_builds(offline_db):
    conn = sqlite3.connect(offline_db)
    assert conn.execute("SELECT COUNT(*) FROM allocations").fetchone()[0] > 0


def test_lookup_gps_l5(offline_db):
    conn = freq_identify.get_db(offline_db)
    assert freq_identify.best_name(conn, 1176.45) == "GPS L5"


def test_lookup_ism_band(offline_db):
    conn = freq_identify.get_db(offline_db)
    rows = freq_identify.lookup_freq(conn, 2450.0)
    assert any("2.4 GHz" in r[0] for r in rows)


def test_lookup_unallocated_returns_nothing(offline_db):
    conn = freq_identify.get_db(offline_db)
    assert freq_identify.lookup_freq(conn, 0.0001) == []


def test_missing_db_exits(tmp_path):
    with pytest.raises(SystemExit):
        freq_identify.get_db(tmp_path / "nope.sqlite")
