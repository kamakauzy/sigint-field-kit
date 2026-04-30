#!/usr/bin/env python3
"""
freq_identify.py — Identify signals by frequency from the local database.

Usage:
    ./freq_identify.py 463.000              # Single lookup
    ./freq_identify.py 433.92 145.5 857.5   # Multiple frequencies
    ./freq_identify.py --csv alerts.csv     # From CSV (reads freq_mhz column)
    ./freq_identify.py --annotate report.md # Annotate MHz values in report

Pipeline integration:
    Designed to enrich output from sigint_adaptive.sh and intel_packager.py.
    Use --annotate to add protocol names to generated intel reports.
"""
import argparse
import csv
import json
import re
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "freq_db.sqlite"


def get_db(db_path=None):
    """Open database connection, exit with helpful error if missing."""
    path = Path(db_path) if db_path else DB_PATH
    if not path.exists():
        print(f"[ERROR] Database not found: {path}", file=sys.stderr)
        print(f"[ERROR] Run: python3 scripts/build_freq_db.py", file=sys.stderr)
        sys.exit(1)
    return sqlite3.connect(str(path))


def lookup_freq(conn, freq_mhz, limit=5):
    """Return matches for a frequency, ordered by priority then specificity."""
    cur = conn.execute(
        """SELECT name, freq_low_mhz, freq_high_mhz, modulation, category,
                  region, notes, source, priority
           FROM allocations
           WHERE freq_low_mhz <= ? AND freq_high_mhz >= ?
           ORDER BY priority DESC, (freq_high_mhz - freq_low_mhz) ASC
           LIMIT ?""",
        (freq_mhz, freq_mhz, limit)
    )
    return cur.fetchall()


def best_name(conn, freq_mhz):
    """Return the single best short name for a frequency."""
    matches = lookup_freq(conn, freq_mhz, limit=1)
    if matches:
        return matches[0][0]
    return None


def format_match(row):
    """Format a single DB row for terminal display."""
    name, f_low, f_high, mod, cat, region, notes, source, priority = row
    parts = [f"  {name}"]
    details = []
    if f_low != f_high:
        details.append(f"{f_low:.3f}–{f_high:.3f} MHz")
    if mod:
        details.append(mod)
    if cat:
        details.append(cat)
    if region and region not in ("US", "Global"):
        details.append(region)
    if details:
        parts.append(f" ({', '.join(details)})")
    if notes:
        parts.append(f"\n    └─ {notes}")
    return "".join(parts)


def identify_single(conn, freq_mhz):
    """Print identification for a single frequency."""
    matches = lookup_freq(conn, freq_mhz)
    if not matches:
        print(f"{freq_mhz:.3f} MHz: Unknown — not in database")
        return
    print(f"{freq_mhz:.3f} MHz:")
    for row in matches:
        print(format_match(row))
    print()


def identify_csv(conn, csv_path):
    """Identify unique frequencies from a CSV file."""
    seen = set()
    freqs = []
    with open(csv_path, "r", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f)
        for row in reader:
            freq_str = row.get("freq_mhz", row.get("freq", ""))
            try:
                freq = float(freq_str)
            except (ValueError, TypeError):
                continue
            if freq not in seen:
                seen.add(freq)
                freqs.append(freq)

    for freq in sorted(freqs):
        identify_single(conn, freq)


def annotate_report(conn, report_path):
    """Annotate MHz values in a markdown report with identifications."""
    with open(report_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Match patterns like "463.000 MHz" that aren't already annotated with parens
    def replacer(m):
        freq_str = m.group(1)
        try:
            freq = float(freq_str)
        except ValueError:
            return m.group(0)
        name = best_name(conn, freq)
        if name:
            return f"{freq_str} MHz ({name})"
        return m.group(0)

    annotated = re.sub(r'(\d+\.\d+)\s*MHz(?!\s*\()', replacer, content)

    with open(report_path, "w", encoding="utf-8") as f:
        f.write(annotated)

    print(f"[OK] Annotated {report_path}", file=sys.stderr)


def output_json(conn, frequencies):
    """Output lookup results as JSON."""
    results = {}
    for freq in frequencies:
        matches = lookup_freq(conn, freq)
        results[str(freq)] = [
            {
                "name": r[0],
                "freq_low_mhz": r[1],
                "freq_high_mhz": r[2],
                "modulation": r[3],
                "category": r[4],
                "region": r[5],
                "notes": r[6],
            }
            for r in matches
        ]
    print(json.dumps(results, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description="Identify signals by frequency from local database",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s 463.000 145.500 433.920
  %(prog)s --csv /var/lib/recon-raven/logs/alerts.csv
  %(prog)s --annotate intel_report.md
  %(prog)s 857.478 --json
"""
    )
    parser.add_argument("frequencies", nargs="*", type=float,
                        help="Frequency/frequencies in MHz to identify")
    parser.add_argument("--csv", type=str,
                        help="CSV file with freq_mhz column to identify")
    parser.add_argument("--annotate", type=str,
                        help="Annotate a markdown report in-place with signal IDs")
    parser.add_argument("--json", action="store_true",
                        help="Output results as JSON")
    parser.add_argument("--db", type=str, default=None,
                        help="Path to freq_db.sqlite (default: data/freq_db.sqlite)")
    args = parser.parse_args()

    conn = get_db(args.db)

    if args.annotate:
        annotate_report(conn, args.annotate)
    elif args.csv:
        identify_csv(conn, args.csv)
    elif args.frequencies:
        if args.json:
            output_json(conn, args.frequencies)
        else:
            for freq in args.frequencies:
                identify_single(conn, freq)
    else:
        parser.print_help()

    conn.close()


if __name__ == "__main__":
    main()
