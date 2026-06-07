#!/usr/bin/env python3
"""
KrakenSDR DOA Collector — Polls the KrakenSDR Pi and logs bearings.

Connects to the KrakenSDR DOA data forwarder (port 8081) running on the
Raspberry Pi, collects bearing data, and logs everything to a local SQLite
database + CSV for integration with the intel pipeline.

The collector runs continuously, polling at a configurable interval. Each
bearing record includes timestamp, frequency, bearing angle, confidence,
power, and the observer's position (for later triangulation).

Usage:
    ./kraken_doa_collector.py                          # defaults from config
    ./kraken_doa_collector.py --host 192.168.1.120     # specify Pi IP
    ./kraken_doa_collector.py --duration 3600           # run for 1 hour
    ./kraken_doa_collector.py --lat 35.1234 --lon -97.4567  # with GPS position

Dependencies: Python 3 (stdlib only — urllib, sqlite3, json)
"""
import argparse
import csv
import json
import os
import signal
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_CONFIG = PROJECT_DIR / "kraken" / "config" / "kraken_defaults.json"
DEFAULT_DB = PROJECT_DIR / "data" / "kraken_doa.sqlite"
DEFAULT_CSV = PROJECT_DIR / "data" / "bearings.csv"


def load_config(config_path=None):
    """Load config from JSON, with fallback defaults."""
    defaults = {
        "host": "192.168.1.120",
        "api_port": 8081,
        "poll_interval_sec": 2,
        "min_confidence": 0.3,
        "db_path": str(DEFAULT_DB),
        "csv_path": str(DEFAULT_CSV),
        "station_id": "HOME_QTH",
        "latitude": None,
        "longitude": None,
    }

    path = Path(config_path) if config_path else DEFAULT_CONFIG
    if path.exists():
        try:
            with open(path) as f:
                cfg = json.load(f)
            kraken_pi = cfg.get("kraken_pi", {})
            collection = cfg.get("collection", {})
            station = cfg.get("station", {})
            defaults.update({
                "host": kraken_pi.get("host", defaults["host"]),
                "api_port": kraken_pi.get("api_port", defaults["api_port"]),
                "poll_interval_sec": collection.get("poll_interval_sec", defaults["poll_interval_sec"]),
                "min_confidence": collection.get("min_confidence", defaults["min_confidence"]),
                "db_path": str(PROJECT_DIR / collection.get("db_path", "data/kraken_doa.sqlite")),
                "csv_path": str(PROJECT_DIR / collection.get("bearing_log_csv", "data/bearings.csv")),
                "station_id": station.get("id", defaults["station_id"]),
                "latitude": station.get("latitude"),
                "longitude": station.get("longitude"),
            })
        except (json.JSONDecodeError, KeyError) as e:
            print(f"[WARN] Config parse error: {e}, using defaults", file=sys.stderr)

    return defaults


def init_db(db_path):
    """Create SQLite database with bearing and session tables."""
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS bearings (
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
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            start_time TEXT NOT NULL,
            end_time TEXT,
            station_id TEXT,
            latitude REAL,
            longitude REAL,
            bearing_count INTEGER DEFAULT 0,
            notes TEXT
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_bearings_freq
        ON bearings(freq_mhz)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_bearings_time
        ON bearings(timestamp)
    """)
    conn.commit()
    return conn


def init_csv(csv_path):
    """Initialize CSV log file with headers if it doesn't exist."""
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    if not Path(csv_path).exists():
        with open(csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                "timestamp_utc", "freq_mhz", "bearing_deg", "confidence",
                "power_db", "latitude", "longitude", "station_id", "session_id"
            ])


def poll_kraken(host, port, timeout=5):
    """Poll the KrakenSDR forwarder API for latest DOA data."""
    url = f"http://{host}:{port}/doa"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
            return data
    except urllib.error.URLError as e:
        return {"error": f"Connection failed: {e.reason}", "status": "unreachable"}
    except Exception as e:
        return {"error": str(e), "status": "error"}


def check_health(host, port, timeout=3):
    """Quick health check on the KrakenSDR forwarder."""
    url = f"http://{host}:{port}/health"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode()).get("ok", False)
    except Exception:
        return False


def log_bearing(conn, csv_path, bearing, config, session_id):
    """Log a single bearing to both SQLite and CSV."""
    ts = datetime.now(timezone.utc).isoformat()
    freq = bearing.get("freq_mhz", 0)
    deg = bearing.get("bearing_deg", 0)
    conf = bearing.get("confidence", 0)
    power = bearing.get("power_db")

    # SQLite
    conn.execute("""
        INSERT INTO bearings (timestamp, freq_mhz, bearing_deg, confidence,
                              power_db, latitude, longitude, station_id, session_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (ts, freq, deg, conf, power,
          config["latitude"], config["longitude"],
          config["station_id"], session_id))

    # CSV append
    with open(csv_path, "a", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            ts, freq, deg, conf, power,
            config["latitude"], config["longitude"],
            config["station_id"], session_id
        ])


def format_bearing(deg):
    """Convert degrees to compass direction."""
    dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    idx = round(deg / 22.5) % 16
    return dirs[idx]


def main():
    parser = argparse.ArgumentParser(description="KrakenSDR DOA Collector")
    parser.add_argument("--host", help="KrakenSDR Pi IP address")
    parser.add_argument("--port", type=int, help="API port (default 8081)")
    parser.add_argument("--config", help="Config JSON path")
    parser.add_argument("--db", help="SQLite database path")
    parser.add_argument("--csv", help="CSV log path")
    parser.add_argument("--lat", type=float, help="Observer latitude")
    parser.add_argument("--lon", type=float, help="Observer longitude")
    parser.add_argument("--station", help="Station identifier")
    parser.add_argument("--duration", type=int, help="Run for N seconds (default: indefinite)")
    parser.add_argument("--interval", type=float, help="Poll interval in seconds")
    parser.add_argument("--min-confidence", type=float, help="Minimum confidence to log")
    parser.add_argument("--quiet", action="store_true", help="Suppress per-bearing output")
    args = parser.parse_args()

    config = load_config(args.config)

    # CLI overrides
    if args.host: config["host"] = args.host
    if args.port: config["api_port"] = args.port
    if args.db: config["db_path"] = args.db
    if args.csv: config["csv_path"] = args.csv
    if args.lat is not None: config["latitude"] = args.lat
    if args.lon is not None: config["longitude"] = args.lon
    if args.station: config["station_id"] = args.station
    if args.interval: config["poll_interval_sec"] = args.interval
    if args.min_confidence is not None: config["min_confidence"] = args.min_confidence

    # Initialize storage
    conn = init_db(config["db_path"])
    init_csv(config["csv_path"])

    # Create session
    session_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    conn.execute("""
        INSERT INTO sessions (id, start_time, station_id, latitude, longitude)
        VALUES (?, ?, ?, ?, ?)
    """, (session_id, datetime.now(timezone.utc).isoformat(),
          config["station_id"], config["latitude"], config["longitude"]))
    conn.commit()

    print(f"═══════════════════════════════════════════════════════════")
    print(f"  KrakenSDR DOA Collector")
    print(f"  Target: {config['host']}:{config['api_port']}")
    print(f"  Station: {config['station_id']}")
    pos = f"({config['latitude']}, {config['longitude']})" if config["latitude"] else "(not set)"
    print(f"  Position: {pos}")
    print(f"  Interval: {config['poll_interval_sec']}s | Min confidence: {config['min_confidence']}")
    print(f"  DB: {config['db_path']}")
    print(f"  Session: {session_id}")
    if args.duration:
        print(f"  Duration: {args.duration}s")
    print(f"═══════════════════════════════════════════════════════════")

    # Health check
    print(f"\nConnecting to KrakenSDR Pi at {config['host']}...", end=" ", flush=True)
    if check_health(config["host"], config["api_port"]):
        print("OK")
    else:
        print("UNREACHABLE")
        print("  KrakenSDR Pi not responding. Collector will retry until connected.")
        print("  Make sure kraken-forwarder service is running on the Pi.")

    # Graceful shutdown
    running = True
    def handle_signal(sig, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    print("\nCollecting bearings (Ctrl+C to stop)...\n")

    start_time = time.time()
    total_bearings = 0
    consecutive_errors = 0
    freq_counts = {}

    while running:
        if args.duration and (time.time() - start_time) >= args.duration:
            break

        data = poll_kraken(config["host"], config["api_port"])

        if "error" in data:
            consecutive_errors += 1
            if consecutive_errors <= 3 or consecutive_errors % 30 == 0:
                print(f"  [{datetime.now().strftime('%H:%M:%S')}] {data['error']}")
            time.sleep(config["poll_interval_sec"])
            continue

        consecutive_errors = 0
        bearings = data.get("bearings", [])

        for b in bearings:
            conf = b.get("confidence", 0)
            if conf < config["min_confidence"]:
                continue

            log_bearing(conn, config["csv_path"], b, config, session_id)
            total_bearings += 1

            freq = b.get("freq_mhz", 0)
            freq_counts[freq] = freq_counts.get(freq, 0) + 1

            if not args.quiet:
                deg = b.get("bearing_deg", 0)
                compass = format_bearing(deg)
                power = b.get("power_db")
                power_str = f" | {power:.1f} dB" if power is not None else ""
                print(f"  [{datetime.now().strftime('%H:%M:%S')}] "
                      f"{freq:>10.4f} MHz → {deg:>5.1f}° {compass:<3s} "
                      f"(conf={conf:.2f}{power_str})")

        if total_bearings % 50 == 0 and total_bearings > 0:
            conn.commit()

        time.sleep(config["poll_interval_sec"])

    # Finalize
    conn.execute("""
        UPDATE sessions SET end_time = ?, bearing_count = ? WHERE id = ?
    """, (datetime.now(timezone.utc).isoformat(), total_bearings, session_id))
    conn.commit()
    conn.close()

    elapsed = time.time() - start_time
    print(f"\n═══════════════════════════════════════════════════════════")
    print(f"  Session {session_id} complete")
    print(f"  Duration: {int(elapsed)}s | Bearings logged: {total_bearings}")
    if freq_counts:
        print(f"  Per-frequency counts:")
        for freq, count in sorted(freq_counts.items(), key=lambda x: -x[1]):
            print(f"    {freq:>10.4f} MHz: {count} bearings")
    print(f"  Data: {config['db_path']}")
    print(f"═══════════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
