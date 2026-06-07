#!/usr/bin/env python3
"""
KrakenSDR Test Harness — Generates synthetic DOA data for pipeline testing.

Creates a populated kraken_doa.sqlite database with realistic fake bearings
so you can dry-run the full pipeline (emitter_locator.py → intel_packager.py)
without hardware.

Simulates two scenarios:
  1. Fixed station: All bearings from one position (HOME_QTH)
  2. Mobile collection: Bearings from multiple positions along a drive route

Synthetic emitter locations are placed at known coordinates so you can
verify triangulation accuracy.

Usage:
    ./kraken_test_harness.py                              # default scenario
    ./kraken_test_harness.py --scenario mobile             # mobile collection
    ./kraken_test_harness.py --db /tmp/test_kraken.sqlite  # custom DB path
    ./kraken_test_harness.py --bearings 200 --noise 5      # 200 bearings, ±5° noise

Dependencies: Python 3 (stdlib only)
"""
import argparse
import math
import os
import random
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_DB = PROJECT_DIR / "data" / "kraken_test.sqlite"


def true_bearing(observer_lat, observer_lon, target_lat, target_lon):
    """Compute true bearing from observer to target."""
    lat1 = math.radians(observer_lat)
    lat2 = math.radians(target_lat)
    dlon = math.radians(target_lon - observer_lon)
    x = math.sin(dlon) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def init_db(db_path):
    """Create database matching kraken_doa_collector.py schema."""
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("DROP TABLE IF EXISTS bearings")
    conn.execute("DROP TABLE IF EXISTS sessions")
    conn.execute("""
        CREATE TABLE bearings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            freq_mhz REAL NOT NULL,
            bearing_deg REAL NOT NULL,
            confidence REAL,
            power_db REAL,
            latitude REAL,
            longitude REAL,
            station_id TEXT,
            session_id TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            start_time TEXT,
            end_time TEXT,
            station_id TEXT,
            notes TEXT
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bearings_freq ON bearings(freq_mhz)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bearings_session ON bearings(session_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bearings_time ON bearings(timestamp)")
    conn.commit()
    return conn


def generate_fixed_station(conn, num_bearings, noise_deg, session_id):
    """
    Fixed station scenario: observer at one location, emitters at known positions.
    Good for testing bearing clustering and single-position analysis.
    """
    # Observer: arbitrary position (Oklahoma City area)
    obs_lat, obs_lon = 35.4676, -97.5164

    # Known emitter positions (these are the "answers" for verification)
    emitters = [
        {"freq": 462.7125, "lat": 35.4900, "lon": -97.4800, "label": "FRS repeater NE"},
        {"freq": 154.570,  "lat": 35.4500, "lon": -97.5500, "label": "MURS user SW"},
        {"freq": 146.940,  "lat": 35.4750, "lon": -97.4900, "label": "2m repeater E"},
    ]

    now = datetime.now(timezone.utc)
    count = 0

    for emitter in emitters:
        tb = true_bearing(obs_lat, obs_lon, emitter["lat"], emitter["lon"])
        per_emitter = num_bearings // len(emitters)

        for i in range(per_emitter):
            ts = now - timedelta(seconds=(per_emitter - i) * 2)
            noisy_bearing = (tb + random.gauss(0, noise_deg)) % 360
            confidence = max(0.3, min(1.0, 0.85 + random.gauss(0, 0.1)))
            power = -45 + random.gauss(0, 3)

            conn.execute(
                "INSERT INTO bearings (timestamp, freq_mhz, bearing_deg, confidence, "
                "power_db, latitude, longitude, station_id, session_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (ts.strftime("%Y-%m-%dT%H:%M:%SZ"), emitter["freq"],
                 round(noisy_bearing, 1), round(confidence, 3), round(power, 1),
                 obs_lat, obs_lon, "HOME_QTH", session_id)
            )
            count += 1

    # Record session
    conn.execute(
        "INSERT INTO sessions (id, start_time, end_time, station_id, notes) VALUES (?, ?, ?, ?, ?)",
        (session_id, (now - timedelta(seconds=num_bearings * 2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
         now.strftime("%Y-%m-%dT%H:%M:%SZ"), "HOME_QTH",
         "Synthetic fixed-station test data")
    )
    conn.commit()

    print(f"[FIXED STATION] Observer: ({obs_lat}, {obs_lon})")
    print(f"  Generated {count} bearings across {len(emitters)} emitters")
    print(f"  Noise: ±{noise_deg}° gaussian")
    print()
    print("  Known emitter positions (ground truth):")
    for e in emitters:
        tb = true_bearing(obs_lat, obs_lon, e["lat"], e["lon"])
        print(f"    {e['freq']:.4f} MHz: ({e['lat']}, {e['lon']}) "
              f"true bearing={tb:.1f}° — {e['label']}")

    return count


def generate_mobile_collection(conn, num_bearings, noise_deg, session_id):
    """
    Mobile collection scenario: observer moves along a route, taking bearings
    from different positions. Enables actual triangulation.
    """
    # Target emitter: known position
    target_lat, target_lon = 35.4800, -97.5000
    target_freq = 462.7125

    # Observer route: 5 waypoints moving roughly south-to-north
    waypoints = [
        (35.4550, -97.5200),
        (35.4600, -97.5100),
        (35.4680, -97.5050),
        (35.4750, -97.5150),
        (35.4830, -97.5250),
    ]

    # Second emitter for multi-freq testing
    target2_lat, target2_lon = 35.4650, -97.4850
    target2_freq = 154.570

    now = datetime.now(timezone.utc)
    count = 0
    per_waypoint = num_bearings // (len(waypoints) * 2)  # 2 emitters

    for wi, (wlat, wlon) in enumerate(waypoints):
        for target in [(target_freq, target_lat, target_lon),
                       (target2_freq, target2_lat, target2_lon)]:
            freq, tlat, tlon = target
            tb = true_bearing(wlat, wlon, tlat, tlon)

            for i in range(per_waypoint):
                ts = now - timedelta(seconds=(len(waypoints) * per_waypoint * 2 -
                                              (wi * per_waypoint + i) * 2))
                noisy_bearing = (tb + random.gauss(0, noise_deg)) % 360
                confidence = max(0.3, min(1.0, 0.80 + random.gauss(0, 0.12)))
                power = -40 + random.gauss(0, 4) - wi * 2  # weaker as we move

                conn.execute(
                    "INSERT INTO bearings (timestamp, freq_mhz, bearing_deg, confidence, "
                    "power_db, latitude, longitude, station_id, session_id) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (ts.strftime("%Y-%m-%dT%H:%M:%SZ"), freq,
                     round(noisy_bearing, 1), round(confidence, 3), round(power, 1),
                     wlat, wlon, f"MOBILE_WP{wi+1}", session_id)
                )
                count += 1

    conn.execute(
        "INSERT INTO sessions (id, start_time, end_time, station_id, notes) VALUES (?, ?, ?, ?, ?)",
        (session_id, (now - timedelta(seconds=num_bearings * 2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
         now.strftime("%Y-%m-%dT%H:%M:%SZ"), "MOBILE",
         "Synthetic mobile collection test data")
    )
    conn.commit()

    print(f"[MOBILE COLLECTION] {len(waypoints)} waypoints, 2 emitters")
    print(f"  Generated {count} bearings")
    print(f"  Noise: ±{noise_deg}° gaussian")
    print()
    print("  Waypoints:")
    for i, (lat, lon) in enumerate(waypoints):
        print(f"    WP{i+1}: ({lat}, {lon})")
    print()
    print("  Known emitter positions (ground truth for triangulation verification):")
    print(f"    {target_freq:.4f} MHz: ({target_lat}, {target_lon})")
    print(f"    {target2_freq:.4f} MHz: ({target2_lat}, {target2_lon})")

    return count


def main():
    parser = argparse.ArgumentParser(
        description="KrakenSDR Test Harness — generate synthetic DOA data",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Scenarios:
  fixed    — Single observer position, multiple emitters. Tests clustering.
  mobile   — Observer moves along route. Tests triangulation.
  both     — Generate both scenarios in one database.

After generating data, test the pipeline:
  ./emitter_locator.py --db data/kraken_test.sqlite
  ./emitter_locator.py --db data/kraken_test.sqlite --geojson test_map.json
  ./intel_packager.py --kraken-db data/kraken_test.sqlite -o test_report.md
        """,
    )
    parser.add_argument("--db", default=str(DEFAULT_DB),
                        help=f"Output database path (default: {DEFAULT_DB})")
    parser.add_argument("--scenario", choices=["fixed", "mobile", "both"], default="both",
                        help="Test scenario (default: both)")
    parser.add_argument("--bearings", type=int, default=120,
                        help="Total bearings to generate per scenario (default: 120)")
    parser.add_argument("--noise", type=float, default=3.0,
                        help="Bearing noise in degrees (gaussian σ, default: 3.0)")
    parser.add_argument("--seed", type=int, default=None,
                        help="Random seed for reproducible runs")

    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    print(f"═══ KrakenSDR Test Harness ═══")
    print(f"Database: {args.db}")
    print()

    conn = init_db(args.db)
    total = 0

    if args.scenario in ("fixed", "both"):
        session_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-fixed"
        total += generate_fixed_station(conn, args.bearings, args.noise, session_id)
        print()

    if args.scenario in ("mobile", "both"):
        session_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-mobile"
        total += generate_mobile_collection(conn, args.bearings, args.noise, session_id)
        print()

    conn.close()

    print(f"═══ Total: {total} bearings written to {args.db} ═══")
    print()
    print("Next steps:")
    print(f"  python scripts/emitter_locator.py --db {args.db}")
    print(f"  python scripts/emitter_locator.py --db {args.db} --geojson data/test_emitters.json")
    print(f"  python scripts/intel_packager.py --kraken-db {args.db} -o data/test_report.md")


if __name__ == "__main__":
    main()
