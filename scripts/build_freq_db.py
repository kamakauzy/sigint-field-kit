#!/usr/bin/env python3
"""
build_freq_db.py — Build local frequency identification database.

Sources:
  1. Embedded US/global band allocations (comprehensive seed data)
  2. Artemis signal DB (AresValley/Artemis GitHub JSON)
  3. rtl_433 device protocols (merbanan/rtl_433 README)

Usage:
    ./build_freq_db.py                 # Build/rebuild from all sources
    ./build_freq_db.py --offline       # Skip network fetches, use seed only
    ./build_freq_db.py --db /path/db   # Custom output path

Output: data/freq_db.sqlite (committed to repo, updated by install.sh)
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import urllib.request
from pathlib import Path

DB_DIR = Path(__file__).resolve().parent.parent / "data"
DB_PATH = DB_DIR / "freq_db.sqlite"

# ─── Schema ─────────────────────────────────────────────────────────────────
SCHEMA = """
CREATE TABLE IF NOT EXISTS allocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    freq_low_mhz REAL NOT NULL,
    freq_high_mhz REAL NOT NULL,
    name TEXT NOT NULL,
    modulation TEXT,
    bandwidth_khz REAL,
    region TEXT DEFAULT 'US',
    category TEXT,
    notes TEXT,
    source TEXT NOT NULL,
    priority INTEGER DEFAULT 5
);

CREATE INDEX IF NOT EXISTS idx_freq_range ON allocations(freq_low_mhz, freq_high_mhz);
CREATE INDEX IF NOT EXISTS idx_name ON allocations(name);

CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""

# ─── Seed Data (US-focused, covers our collection bands) ────────────────────
SEED_DATA = [
    # VHF (136-174 MHz)
    (136.000, 137.000, "Weather Satellite (NOAA APT)", "FM", 34, "US", "satellite", "NOAA 15/18/19 APT downlink"),
    (137.000, 138.000, "Weather Satellite (NOAA/Meteor)", "FM", 34, "US", "satellite", "NOAA HRPT, Meteor-M2"),
    (137.100, 137.100, "NOAA 19 APT", "FM", 34, "US", "satellite", "137.100 MHz APT image downlink"),
    (137.620, 137.620, "NOAA 15 APT", "FM", 34, "US", "satellite", "137.620 MHz APT image downlink"),
    (137.912, 137.912, "NOAA 18 APT", "FM", 34, "US", "satellite", "137.9125 MHz APT image downlink"),
    (138.000, 144.000, "Military/Federal Land Mobile", "NFM", 12.5, "US", "military", "DoD tactical, federal agencies"),
    (144.000, 148.000, "Amateur Radio 2m Band", "NFM/SSB", 12.5, "US", "ham", "2m ham band"),
    (144.200, 144.200, "2m SSB Calling Frequency", "SSB", 2.7, "US", "ham", "Weak signal SSB calling"),
    (145.500, 145.500, "2m FM Simplex Calling", "NFM", 12.5, "US", "ham", "National simplex calling frequency"),
    (146.520, 146.520, "2m National Calling Frequency", "NFM", 12.5, "US", "ham", "Primary 2m FM simplex"),
    (146.940, 146.940, "2m Repeater (common)", "NFM", 12.5, "US", "ham", "Common 2m repeater output"),
    (147.000, 147.390, "2m Repeater Outputs (+)", "NFM", 12.5, "US", "ham", "Standard 2m repeater outputs"),
    (148.000, 150.800, "Federal Government VHF", "NFM", 12.5, "US", "military", "DoD, federal agencies"),
    (148.125, 148.125, "CAP (Civil Air Patrol)", "NFM", 12.5, "US", "public_safety", "Civil Air Patrol"),
    (150.775, 154.000, "VHF Business Band", "NFM", 12.5, "US", "commercial", "Industrial/business, paging"),
    (151.625, 151.625, "Itinerant Business", "NFM", 12.5, "US", "commercial", "Nationwide itinerant freq"),
    (151.820, 151.940, "MURS Channel 1-3", "NFM", 11.25, "US", "commercial", "Multi-Use Radio, license-free 2W"),
    (154.570, 154.600, "MURS Channel 4-5", "NFM", 20, "US", "commercial", "MURS wideband channels"),
    (152.000, 152.840, "VHF Paging/Mobile Telephone", "NFM", 12.5, "US", "commercial", "Paging systems"),
    (153.740, 156.250, "VHF Business/Industrial", "NFM", 12.5, "US", "commercial", "Business band continued"),
    (155.000, 156.000, "Public Safety VHF-High", "NFM", 12.5, "US", "public_safety", "Police/fire VHF-High"),
    (155.475, 155.475, "NCIC/Law Enforcement", "NFM", 12.5, "US", "public_safety", "Common LE mutual aid"),
    (156.050, 157.425, "Marine VHF Band", "NFM", 25, "US", "commercial", "Marine ch 1-28"),
    (156.800, 156.800, "Marine Channel 16 (Distress)", "NFM", 25, "US", "commercial", "International distress/calling"),
    (157.450, 161.575, "Marine VHF (continued)", "NFM", 25, "US", "commercial", "Marine channels continued"),
    (155.160, 155.160, "Search & Rescue", "NFM", 12.5, "US", "public_safety", "SAR coordination"),
    (156.750, 156.750, "Marine Channel 15 (Harbor)", "NFM", 25, "US", "commercial", "Harbor operations"),
    (161.650, 161.775, "AIS (Automatic ID System)", "GMSK", 25, "US", "commercial", "Ship tracking 161.975/162.025"),
    (162.400, 162.550, "NOAA Weather Radio", "NFM", 12.5, "US", "broadcast", "WX1-WX7 continuous broadcast"),
    (162.000, 174.000, "Federal/Public Safety VHF", "NFM", 12.5, "US", "public_safety", "Federal agencies"),
    (169.445, 169.505, "FLEX Paging", "FSK", 12.5, "US", "commercial", "Nationwide paging"),

    # UHF (400-470 MHz)
    (400.150, 401.000, "Weather Radiosonde", "NFM/Digital", 12.5, "US", "satellite", "NWS weather balloons"),
    (401.000, 406.000, "Federal Government UHF", "NFM", 12.5, "US", "military", "Federal land mobile"),
    (406.000, 406.100, "EPIRB/COSPAS-SARSAT", "Digital", 3, "US", "satellite", "Emergency distress beacons"),
    (406.100, 410.000, "Federal Government", "NFM", 12.5, "US", "military", "Federal agencies"),
    (409.750, 410.000, "PMR446 (EU)", "NFM", 12.5, "EU", "commercial", "License-free Europe"),
    (410.000, 420.000, "Federal Government/Land Mobile", "NFM", 12.5, "US", "military", "Federal agencies"),
    (420.000, 450.000, "Amateur Radio 70cm Band", "NFM/FM/SSB", 12.5, "US", "ham", "70cm ham band"),
    (432.100, 432.100, "70cm SSB Calling", "SSB", 2.7, "US", "ham", "National SSB calling"),
    (433.050, 434.790, "ISM 433 MHz Band", "Various", 600, "EU/AS", "ism", "ISM: weather stations, keyfobs, LoRa, sensors"),
    (433.920, 433.920, "ISM 433.92 Center", "OOK/FSK", 200, "EU/AS", "ism", "Primary ISM: remotes, sensors, tire pressure"),
    (440.000, 445.000, "70cm Repeater Outputs", "NFM", 12.5, "US", "ham", "Standard 70cm repeater outputs"),
    (443.400, 443.400, "70cm Repeater (common)", "NFM", 12.5, "US", "ham", "Common repeater pair"),
    (445.000, 450.000, "70cm Repeater Inputs", "NFM", 12.5, "US", "ham", "Standard 70cm repeater inputs"),
    (446.000, 446.200, "FRS Channels 1-7", "NFM", 12.5, "US", "commercial", "Family Radio Service 2W"),
    (446.500, 446.500, "National Simplex (70cm)", "NFM", 12.5, "US", "ham", "70cm national simplex calling"),
    (450.000, 454.000, "UHF Business Band (Base TX)", "NFM", 12.5, "US", "commercial", "Business/industrial base stations"),
    (454.000, 455.000, "UHF Business (continued)", "NFM", 12.5, "US", "commercial", "More business channels"),
    (455.000, 456.000, "UHF Business/Remote Pickup", "NFM", 12.5, "US", "commercial", "Remote broadcast links"),
    (460.000, 462.000, "Public Safety UHF", "NFM", 12.5, "US", "public_safety", "Police/fire/EMS UHF"),
    (460.525, 460.525, "Public Safety Mutual Aid", "NFM", 12.5, "US", "public_safety", "Nationwide mutual aid"),
    (462.5625, 462.7125, "FRS/GMRS Channels 1-7", "NFM", 12.5, "US", "commercial", "Shared FRS/GMRS 2W/5W"),
    (462.5500, 462.7250, "GMRS Repeater Output", "NFM", 12.5, "US", "commercial", "GMRS 50W repeaters"),
    (463.000, 463.200, "GMRS/UHF Business", "NFM", 12.5, "US", "commercial", "GMRS repeater outputs / UHF business"),
    (467.5625, 467.7125, "FRS Channels 8-14", "NFM", 12.5, "US", "commercial", "FRS low-power 0.5W"),
    (467.7500, 467.9250, "GMRS Repeater Input", "NFM", 12.5, "US", "commercial", "GMRS repeater inputs"),
    (462.000, 470.000, "UHF Business/Public Safety", "NFM", 12.5, "US", "commercial", "Mixed commercial/PS"),

    # ISM 900 MHz
    (902.000, 928.000, "ISM 900 MHz Band", "Various", 500, "US", "ism", "LoRa, Zigbee, cordless phones, smart meters"),
    (915.000, 915.000, "ISM 915 Center", "LoRa/FSK", 500, "US", "ism", "Primary ISM 900: smart meters, LoRa"),

    # 800 MHz / P25 (806-870 MHz)
    (806.000, 824.000, "Public Safety 800 (Mobile TX)", "P25/NFM", 12.5, "US", "public_safety", "800 MHz trunked mobile transmit"),
    (824.000, 849.000, "Cellular A/B (Mobile TX)", "Digital", 200, "US", "commercial", "Legacy cellular uplink"),
    (849.000, 851.000, "Air-Ground Radiotelephone", "Digital", 200, "US", "commercial", "In-flight phone (discontinued)"),
    (851.000, 866.000, "Public Safety 800 (Base TX)", "P25/NFM", 12.5, "US", "public_safety", "800 MHz trunked base stations"),
    (857.000, 860.000, "P25 Trunked (common)", "P25", 12.5, "US", "public_safety", "Common P25 trunked allocation"),
    (866.000, 869.000, "800 MHz SMR/Commercial", "Digital", 12.5, "US", "commercial", "Specialized Mobile Radio"),
    (869.000, 894.000, "Cellular (Base TX)", "Digital", 200, "US", "commercial", "Legacy cellular downlink"),

    # ISM 868 MHz (EU)
    (868.000, 868.600, "ISM 868 MHz (EU)", "LoRa/FSK", 125, "EU", "ism", "EU ISM: LoRaWAN, IoT sensors"),
    (868.600, 869.650, "ISM 868 MHz (EU cont.)", "Various", 125, "EU", "ism", "EU ISM continued"),

    # Other notable
    (27.000, 27.410, "CB Radio", "AM/SSB", 10, "US", "commercial", "Citizens Band 40 channels"),
    (30.000, 50.000, "VHF Low Band", "NFM", 20, "US", "public_safety", "Business, public safety, federal"),
    (49.830, 49.890, "Baby Monitors/Cordless", "NFM", 10, "US", "ism", "49 MHz baby monitors, walkie-talkies"),
    (72.000, 76.000, "RC Models/Astronomy", "Various", 20, "US", "ism", "Radio control models"),
    (88.000, 108.000, "FM Broadcast", "WFM", 200, "US", "broadcast", "Commercial FM radio"),
    (108.000, 118.000, "VOR/ILS Navigation", "AM", 50, "US", "commercial", "Aeronautical navigation aids"),
    (118.000, 136.975, "Aircraft VHF (Airband)", "AM", 8.33, "US", "commercial", "ATC, ATIS, ACARS, air-to-air"),
    (121.500, 121.500, "Aviation Emergency", "AM", 8.33, "US", "commercial", "Guard frequency - emergency"),
    (123.100, 123.100, "SAR Aviation (Scene)", "AM", 8.33, "US", "public_safety", "Search and rescue scene"),
    (315.000, 315.000, "ISM 315 MHz (US)", "OOK/ASK", 200, "US", "ism", "Car keyfobs, garage doors, TPMS (US)"),
    (390.000, 390.000, "ISM 390 MHz (US)", "OOK", 200, "US", "ism", "Some car keyfobs (US)"),
    (978.000, 978.000, "ADS-B UAT", "Digital", 1000, "US", "commercial", "Universal Access Transceiver"),
    (1090.000, 1090.000, "ADS-B Mode S", "PPM", 1000, "US", "commercial", "Aircraft transponder downlink"),
    (1575.420, 1575.420, "GPS L1", "CDMA", 2000, "US", "satellite", "GPS civil signal"),
    (1227.600, 1227.600, "GPS L2", "CDMA", 2000, "US", "satellite", "GPS precision signal"),
    (1176.450, 1176.450, "GPS L5", "CDMA", 2000, "US", "satellite", "GPS safety-of-life signal"),
    (2400.000, 2483.500, "ISM 2.4 GHz (WiFi/BT)", "Various", 22000, "US", "ism", "WiFi, Bluetooth, Zigbee, microwave ovens"),
    (5725.000, 5875.000, "ISM 5.8 GHz (WiFi)", "Various", 20000, "US", "ism", "WiFi 5GHz, radar detectors"),
]


def create_db(db_path):
    """Create empty database with schema."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(str(db_path))
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def seed_allocations(conn):
    """Insert the comprehensive seed data."""
    for row in SEED_DATA:
        conn.execute(
            "INSERT INTO allocations (freq_low_mhz, freq_high_mhz, name, modulation, "
            "bandwidth_khz, region, category, notes, source, priority) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'seed', 5)",
            row
        )
    conn.commit()
    print(f"[OK] Seeded {len(SEED_DATA)} band allocations", file=sys.stderr)


def fetch_artemis(conn):
    """Pull Artemis signal database from GitHub."""
    # Try the newer JSON format first, fall back to raw signal list
    urls = [
        "https://raw.githubusercontent.com/AresValley/Artemis/master/db/signals.json",
        "https://raw.githubusercontent.com/AresValley/Artemis/master/artemis_data/signal_db.json",
    ]
    data = None
    for url in urls:
        print(f"[INFO] Trying Artemis: {url}", file=sys.stderr)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "sigint-field-kit/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                data = json.loads(raw)
                break
        except Exception as e:
            print(f"[WARN]   Failed: {e}", file=sys.stderr)
            continue

    if data is None:
        print("[WARN] All Artemis URLs failed, skipping", file=sys.stderr)
        return 0

    count = 0
    # Handle both list-of-signals and dict-of-signals formats
    signals = data if isinstance(data, list) else data.get("signals", data.values() if isinstance(data, dict) else [])

    for sig in signals:
        if not isinstance(sig, dict):
            continue
        name = sig.get("name", sig.get("signal_name", sig.get("title", "")))
        if not name:
            continue

        # Extract frequency range
        freq_low = freq_high = 0
        freq_info = sig.get("frequency", sig.get("freq", sig.get("params", {}).get("frequency")))

        if isinstance(freq_info, dict):
            freq_low = float(freq_info.get("lower", freq_info.get("min", freq_info.get("low", 0))))
            freq_high = float(freq_info.get("upper", freq_info.get("max", freq_info.get("high", freq_low))))
        elif isinstance(freq_info, (int, float)):
            freq_low = freq_high = float(freq_info)
        elif isinstance(freq_info, list) and len(freq_info) >= 2:
            freq_low, freq_high = float(freq_info[0]), float(freq_info[-1])
        elif isinstance(freq_info, str):
            # Try to parse "100-200 MHz" format
            m = re.match(r'([\d.]+)\s*[-–]\s*([\d.]+)', freq_info)
            if m:
                freq_low, freq_high = float(m.group(1)), float(m.group(2))

        # Convert Hz to MHz if values are very large
        if freq_low > 100000:
            freq_low /= 1e6
            freq_high /= 1e6

        if freq_low <= 0:
            continue

        modulation = str(sig.get("modulation", sig.get("mode", "")))[:50]
        bandwidth = sig.get("bandwidth", None)
        if bandwidth:
            try:
                bandwidth = float(bandwidth)
                if bandwidth > 1e6:
                    bandwidth /= 1e3  # Hz to kHz
            except (ValueError, TypeError):
                bandwidth = None

        description = str(sig.get("description", sig.get("wiki", "")))[:200]
        category = str(sig.get("category", sig.get("type", "")))[:50]

        conn.execute(
            "INSERT INTO allocations (freq_low_mhz, freq_high_mhz, name, modulation, "
            "bandwidth_khz, region, category, notes, source, priority) "
            "VALUES (?, ?, ?, ?, ?, 'Global', ?, ?, 'artemis', 3)",
            (freq_low, freq_high, name[:100], modulation, bandwidth, category, description)
        )
        count += 1

    conn.commit()
    print(f"[OK] Imported {count} Artemis signals", file=sys.stderr)
    return count


def fetch_rtl433(conn):
    """Pull rtl_433 device list from GitHub README."""
    url = "https://raw.githubusercontent.com/merbanan/rtl_433/master/README.md"
    print("[INFO] Fetching rtl_433 device list...", file=sys.stderr)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "sigint-field-kit/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode("utf-8")
    except Exception as e:
        print(f"[WARN] rtl_433 fetch failed: {e}", file=sys.stderr)
        return 0

    count = 0
    # Parse device lines like: "  [01]  Silvercrest Remote Control"
    device_pattern = re.compile(r'\[\d+\]\s*\*?\s*(.+)')

    for line in text.split('\n'):
        m = device_pattern.search(line)
        if m:
            device_name = m.group(1).strip()
            if not device_name or device_name.startswith('---') or len(device_name) < 3:
                continue

            # Most rtl_433 devices on 433 ISM (some on 315/868/915)
            conn.execute(
                "INSERT INTO allocations (freq_low_mhz, freq_high_mhz, name, modulation, "
                "bandwidth_khz, region, category, notes, source, priority) "
                "VALUES (433.050, 434.790, ?, 'OOK/FSK', NULL, 'EU/AS/US', 'ism', "
                "'Decoded by rtl_433', 'rtl_433', 2)",
                (f"rtl_433: {device_name[:80]}",)
            )
            count += 1

    conn.commit()
    print(f"[OK] Imported {count} rtl_433 device types", file=sys.stderr)
    return count


def update_meta(conn):
    """Update metadata timestamps."""
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_updated', ?)", (now,))
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('version', '1.0')")

    cur = conn.execute("SELECT COUNT(*) FROM allocations")
    total = cur.fetchone()[0]
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('total_entries', ?)", (str(total),))
    conn.commit()
    return total


def main():
    parser = argparse.ArgumentParser(description="Build frequency identification database")
    parser.add_argument("--db", type=str, default=str(DB_PATH), help="Output SQLite path")
    parser.add_argument("--offline", action="store_true", help="Skip network fetches, seed only")
    args = parser.parse_args()

    db_path = Path(args.db)
    print(f"[INFO] Building freq DB at {db_path}", file=sys.stderr)

    conn = create_db(db_path)
    seed_allocations(conn)

    if not args.offline:
        fetch_artemis(conn)
        fetch_rtl433(conn)

    total = update_meta(conn)
    conn.close()

    print(f"[OK] Database complete: {total} entries in {db_path}", file=sys.stderr)
    print(f"[OK] Size: {db_path.stat().st_size / 1024:.1f} KB", file=sys.stderr)


if __name__ == "__main__":
    main()
