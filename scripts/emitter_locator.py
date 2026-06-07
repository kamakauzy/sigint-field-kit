#!/usr/bin/env python3
"""
Emitter Locator — Triangulates signal sources from KrakenSDR DOA bearings.

Reads bearing data from the kraken_doa.sqlite database and computes estimated
emitter locations using bearing intersection. Works in two modes:

  1. Multi-position: Multiple observation points with different lat/lon
     (mobile collection or distributed stations). Uses least-squares
     intersection of bearing lines.

  2. Single-position: All bearings from one fixed location. Can only give
     bearing (direction), not distance. Reports bearing clusters with
     consistency scores.

Outputs human-readable summary + GeoJSON for mapping.

Usage:
    ./emitter_locator.py                          # all bearings in DB
    ./emitter_locator.py --freq 462.7125          # single frequency
    ./emitter_locator.py --session 20260607-143022 # specific session
    ./emitter_locator.py --since 1h               # last hour only
    ./emitter_locator.py --geojson emitters.json   # output GeoJSON

Dependencies: Python 3 (stdlib only — sqlite3, math, json)
"""
import argparse
import json
import math
import os
import re
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_DB = PROJECT_DIR / "data" / "kraken_doa.sqlite"

# Earth radius in meters
EARTH_R = 6371000


def haversine_distance(lat1, lon1, lat2, lon2):
    """Distance in meters between two lat/lon points."""
    lat1, lon1, lat2, lon2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat/2)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon/2)**2
    return EARTH_R * 2 * math.asin(math.sqrt(a))


def bearing_to_point(lat, lon, bearing_deg, distance_m):
    """Project a point from lat/lon along a bearing at given distance."""
    lat1 = math.radians(lat)
    lon1 = math.radians(lon)
    brng = math.radians(bearing_deg)
    d = distance_m / EARTH_R

    lat2 = math.asin(math.sin(lat1) * math.cos(d) +
                     math.cos(lat1) * math.sin(d) * math.cos(brng))
    lon2 = lon1 + math.atan2(math.sin(brng) * math.sin(d) * math.cos(lat1),
                              math.cos(d) - math.sin(lat1) * math.sin(lat2))

    return math.degrees(lat2), math.degrees(lon2)


def intersect_bearings(observations):
    """
    Find the point that minimizes distance to all bearing lines.

    observations: list of (lat, lon, bearing_deg)
    Returns: (lat, lon, error_m) or None if insufficient data.

    Uses Stansfield's method (least-squares bearing intersection).
    """
    if len(observations) < 2:
        return None

    # Check that we have at least 2 distinct positions
    positions = set()
    for lat, lon, _ in observations:
        positions.add((round(lat, 5), round(lon, 5)))

    if len(positions) < 2:
        return None

    # Convert to local ENU coordinates centered on first observation
    ref_lat = observations[0][0]
    ref_lon = observations[0][1]

    points = []
    angles = []
    for lat, lon, brg in observations:
        # Local x (east), y (north) in meters
        x = (lon - ref_lon) * math.cos(math.radians(ref_lat)) * 111320
        y = (lat - ref_lat) * 111320
        points.append((x, y))
        # Convert compass bearing to math angle (counterclockwise from east)
        theta = math.radians(90 - brg)
        angles.append(theta)

    # Stansfield least-squares intersection
    # Each bearing gives a line: y - yi = tan(θi) * (x - xi)
    # Rearrange: -sin(θ)*x + cos(θ)*y = -sin(θ)*xi + cos(θ)*yi
    # Solve Ax = b via normal equations
    A = []
    b = []
    for (xi, yi), theta in zip(points, angles):
        s = math.sin(theta)
        c = math.cos(theta)
        A.append([-s, c])
        b.append(-s * xi + c * yi)

    # Normal equations: (A^T A) x = A^T b
    n = len(A)
    ata00 = sum(A[i][0]**2 for i in range(n))
    ata01 = sum(A[i][0] * A[i][1] for i in range(n))
    ata11 = sum(A[i][1]**2 for i in range(n))
    atb0 = sum(A[i][0] * b[i] for i in range(n))
    atb1 = sum(A[i][1] * b[i] for i in range(n))

    det = ata00 * ata11 - ata01 * ata01
    if abs(det) < 1e-10:
        return None

    x_est = (ata11 * atb0 - ata01 * atb1) / det
    y_est = (ata00 * atb1 - ata01 * atb0) / det

    # Convert back to lat/lon
    est_lat = ref_lat + y_est / 111320
    est_lon = ref_lon + x_est / (111320 * math.cos(math.radians(ref_lat)))

    # Estimate error (RMS distance from estimated point to each bearing line)
    errors = []
    for (xi, yi), theta in zip(points, angles):
        s = math.sin(theta)
        c = math.cos(theta)
        # Distance from point to line
        d = abs(-s * x_est + c * y_est - (-s * xi + c * yi))
        errors.append(d)

    rms_error = math.sqrt(sum(e**2 for e in errors) / len(errors)) if errors else 0

    return est_lat, est_lon, rms_error


def cluster_bearings(bearings, tolerance_deg=10):
    """
    Cluster bearing angles that are within tolerance of each other.
    Returns list of (mean_bearing, count, stddev, bearings_in_cluster).
    """
    if not bearings:
        return []

    sorted_b = sorted(bearings, key=lambda x: x["bearing_deg"])
    clusters = []
    current = [sorted_b[0]]

    for i in range(1, len(sorted_b)):
        # Handle 360/0 wraparound
        diff = abs(sorted_b[i]["bearing_deg"] - current[-1]["bearing_deg"])
        if diff > 180:
            diff = 360 - diff
        if diff <= tolerance_deg:
            current.append(sorted_b[i])
        else:
            clusters.append(current)
            current = [sorted_b[i]]
    clusters.append(current)

    results = []
    for cluster in clusters:
        angles = [b["bearing_deg"] for b in cluster]
        # Circular mean
        sin_sum = sum(math.sin(math.radians(a)) for a in angles)
        cos_sum = sum(math.cos(math.radians(a)) for a in angles)
        mean_deg = math.degrees(math.atan2(sin_sum, cos_sum)) % 360

        # Circular standard deviation
        R = math.sqrt(sin_sum**2 + cos_sum**2) / len(angles)
        std_deg = math.degrees(math.sqrt(-2 * math.log(max(R, 1e-10)))) if R < 1 else 0

        results.append({
            "mean_bearing": round(mean_deg, 1),
            "count": len(cluster),
            "std_dev": round(std_deg, 1),
            "bearings": cluster,
        })

    return sorted(results, key=lambda x: -x["count"])


def format_compass(deg):
    """Degrees to compass direction."""
    dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return dirs[round(deg / 22.5) % 16]


def parse_duration(s):
    """Parse '1h', '30m', '2d' into timedelta."""
    m = re.match(r'^(\d+)([smhd])$', s.strip())
    if not m:
        raise ValueError(f"Invalid duration: {s}")
    val = int(m.group(1))
    unit = m.group(2)
    if unit == 's': return timedelta(seconds=val)
    if unit == 'm': return timedelta(minutes=val)
    if unit == 'h': return timedelta(hours=val)
    if unit == 'd': return timedelta(days=val)


def query_bearings(db_path, freq=None, session=None, since=None):
    """Query bearing records from the database."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    sql = "SELECT * FROM bearings WHERE 1=1"
    params = []

    if freq:
        sql += " AND abs(freq_mhz - ?) < 0.01"
        params.append(freq)
    if session:
        sql += " AND session_id = ?"
        params.append(session)
    if since:
        cutoff = (datetime.now(timezone.utc) - since).isoformat()
        sql += " AND timestamp >= ?"
        params.append(cutoff)

    sql += " ORDER BY timestamp"
    rows = conn.execute(sql, params).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def analyze_frequency(freq_mhz, bearings):
    """Analyze bearings for a single frequency. Returns analysis dict."""
    result = {
        "freq_mhz": freq_mhz,
        "bearing_count": len(bearings),
        "time_span": None,
        "clusters": [],
        "triangulation": None,
    }

    if not bearings:
        return result

    # Time span
    times = [b["timestamp"] for b in bearings]
    result["time_span"] = {"first": min(times), "last": max(times)}

    # Cluster bearings
    result["clusters"] = cluster_bearings(bearings)

    # Attempt triangulation if we have multiple positions
    observations = []
    for b in bearings:
        if b.get("latitude") is not None and b.get("longitude") is not None:
            observations.append((b["latitude"], b["longitude"], b["bearing_deg"]))

    if len(observations) >= 2:
        tri = intersect_bearings(observations)
        if tri:
            result["triangulation"] = {
                "latitude": round(tri[0], 6),
                "longitude": round(tri[1], 6),
                "error_m": round(tri[2], 1),
                "observation_count": len(observations),
            }

    return result


def print_analysis(analyses):
    """Print human-readable analysis."""
    print("═══════════════════════════════════════════════════════════")
    print("  EMITTER LOCATION ANALYSIS")
    print("═══════════════════════════════════════════════════════════\n")

    for a in analyses:
        freq = a["freq_mhz"]
        print(f"── {freq:.4f} MHz ({a['bearing_count']} bearings) ──")

        if a["time_span"]:
            print(f"   Time: {a['time_span']['first']} → {a['time_span']['last']}")

        if a["clusters"]:
            print(f"   Bearing clusters:")
            for c in a["clusters"][:5]:  # top 5
                compass = format_compass(c["mean_bearing"])
                print(f"     {c['mean_bearing']:>5.1f}° {compass:<3s}  "
                      f"({c['count']} bearings, σ={c['std_dev']:.1f}°)")

        if a["triangulation"]:
            t = a["triangulation"]
            print(f"   ★ TRIANGULATED POSITION:")
            print(f"     Lat: {t['latitude']:.6f}  Lon: {t['longitude']:.6f}")
            print(f"     Error estimate: ~{t['error_m']:.0f}m "
                  f"({t['observation_count']} observations)")
        elif a["bearing_count"] > 0 and not a["triangulation"]:
            if a["clusters"]:
                best = a["clusters"][0]
                print(f"   → Best bearing: {best['mean_bearing']:.1f}° "
                      f"{format_compass(best['mean_bearing'])} "
                      f"(need multiple positions to triangulate)")

        print()


def generate_geojson(analyses, station_lat=None, station_lon=None):
    """Generate GeoJSON FeatureCollection from analysis results."""
    features = []

    # Station marker
    if station_lat is not None and station_lon is not None:
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [station_lon, station_lat]},
            "properties": {
                "name": "Observer",
                "marker-symbol": "star",
                "marker-color": "#00ff00",
            }
        })

    for a in analyses:
        # Triangulated position
        if a["triangulation"]:
            t = a["triangulation"]
            features.append({
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [t["longitude"], t["latitude"]]},
                "properties": {
                    "name": f"{a['freq_mhz']:.4f} MHz (triangulated)",
                    "freq_mhz": a["freq_mhz"],
                    "error_m": t["error_m"],
                    "bearing_count": a["bearing_count"],
                    "marker-symbol": "danger",
                    "marker-color": "#ff0000",
                }
            })

        # Bearing lines from station
        if station_lat is not None and station_lon is not None and a["clusters"]:
            for c in a["clusters"][:3]:
                # Draw a 10km line along the bearing
                end_lat, end_lon = bearing_to_point(
                    station_lat, station_lon, c["mean_bearing"], 10000
                )
                features.append({
                    "type": "Feature",
                    "geometry": {
                        "type": "LineString",
                        "coordinates": [
                            [station_lon, station_lat],
                            [end_lon, end_lat]
                        ]
                    },
                    "properties": {
                        "name": f"{a['freq_mhz']:.4f} MHz → {c['mean_bearing']:.1f}°",
                        "freq_mhz": a["freq_mhz"],
                        "bearing_deg": c["mean_bearing"],
                        "count": c["count"],
                        "stroke": "#ff4444" if c == a["clusters"][0] else "#ffaa44",
                        "stroke-width": 2,
                    }
                })

    return {"type": "FeatureCollection", "features": features}


def main():
    parser = argparse.ArgumentParser(description="Emitter Locator — KrakenSDR bearing triangulation")
    parser.add_argument("--db", default=str(DEFAULT_DB), help="Bearing database path")
    parser.add_argument("--freq", type=float, help="Analyze single frequency (MHz)")
    parser.add_argument("--session", help="Filter by session ID")
    parser.add_argument("--since", help="Time window (e.g. 1h, 30m, 2d)")
    parser.add_argument("--geojson", help="Output GeoJSON file path")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    if not Path(args.db).exists():
        print(f"No bearing database at {args.db}", file=sys.stderr)
        print("Run kraken_doa_collector.py first to collect bearing data.", file=sys.stderr)
        sys.exit(1)

    since = parse_duration(args.since) if args.since else None
    bearings = query_bearings(args.db, freq=args.freq, session=args.session, since=since)

    if not bearings:
        print("No bearings found matching criteria.")
        sys.exit(0)

    # Group by frequency
    by_freq = defaultdict(list)
    for b in bearings:
        by_freq[b["freq_mhz"]].append(b)

    # Analyze each frequency
    analyses = []
    for freq in sorted(by_freq.keys()):
        analyses.append(analyze_frequency(freq, by_freq[freq]))

    if args.json:
        print(json.dumps([a for a in analyses], indent=2, default=str))
    else:
        print_analysis(analyses)

    # GeoJSON output
    if args.geojson:
        # Get station position from first bearing with coordinates
        slat = slon = None
        for b in bearings:
            if b.get("latitude") and b.get("longitude"):
                slat, slon = b["latitude"], b["longitude"]
                break

        geojson = generate_geojson(analyses, slat, slon)
        with open(args.geojson, "w") as f:
            json.dump(geojson, f, indent=2)
        print(f"GeoJSON written to {args.geojson}")


if __name__ == "__main__":
    main()
