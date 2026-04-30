# Automation Scripts — SIGINT Field Kit

Headless Python scripts for unattended signal collection and analysis. Each script maps to a phase of the F3EAD intelligence cycle and is designed to chain with others.

**Requires:** RTL-SDR dongle, GNU Radio + gr-osmosdr (for squelch_recorder & burst_detector), rtl_power (for power_logger & signal_alerter)

---

## Pipeline Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         F3EAD SIGINT Pipeline                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  FIND        squelch_recorder.py ─── IQ captures (.cf32)                │
│              burst_detector.py ────── burst log (CSV)                    │
│              power_logger.py ──────── power heatmap (CSV)               │
│              signal_alerter.py ────── threshold alerts (CSV)            │
│              sigint_sweep.sh ──────── multi-band spectrum survey (CSV)  │
│              voice_scanner.sh ─────── squelch-gated WAV recordings      │
│                                           │                             │
│  FIX         burst_detector.py ────── pattern-of-life timing            │
│              signal_alerter.py ────── frequency watch                    │
│              voice_scanner.sh ─────── voice capture for ID/content      │
│              sigint_adaptive.sh ───── baseline anomaly detection         │
│                                           │                             │
│  FINISH      sigint_adaptive.sh ───── targeted collection on anomalies  │
│                                           │                             │
│  ANALYZE     baseline_diff.py ─────── new/missing/changed signals       │
│              freq_identify.py ─────── signal ID from frequency database  │
│                                           │                             │
│  DISSEMINATE intel_packager.py ────── one-page intel summary (.md)      │
│              freq_identify.py ─────── annotate report with signal names  │
│                                                                         │
│  MAINTAIN    build_freq_db.py ─────── build/update frequency database   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## squelch_recorder.py — Squelch-Triggered IQ Recorder

Monitors a frequency and automatically records IQ samples to timestamped `.cf32` files when signal power exceeds the squelch threshold. Walk away, come back to captures.

**Dependencies:** GNU Radio, gr-osmosdr, RTL-SDR

```bash
# Basic — ISM 433 MHz, default squelch
./squelch_recorder.py

# VHF voice, tighter squelch
./squelch_recorder.py -f 146.52 -s -35

# LoRa band, custom output directory
./squelch_recorder.py -f 915 -s -50 -o /tmp/captures

# Headless LP/OP deployment
./squelch_recorder.py -f 433.92 --headless
```

| Flag | Default | Description |
|------|---------|-------------|
| `-f` | 433.92 | Center frequency (MHz) |
| `-s` | -40 | Squelch threshold (dB) |
| `-g` | 38 | RF gain |
| `-r` | 2.4 | Sample rate (Msps) |
| `-o` | ~/SIGINT/recordings | Output directory |
| `--min` | 1.0 | Minimum capture duration (s) — shorter = noise, deleted |
| `--max` | 300 | Max capture before file split (s) |
| `--headless` | off | No GUI, pure console output |

**Output:** `capture_<freq>MHz_<timestamp>_<rate>sps.cf32`

Open captures in URH, inspectrum, or GNU Radio for protocol analysis.

---

## burst_detector.py — Burst Detector

Detects short RF bursts (LoRa packets, FSK data, sensor transmissions), timestamps them, and logs peak power + duration. Establishes pattern-of-life.

**Dependencies:** GNU Radio, gr-osmosdr, RTL-SDR

```bash
# ISM 433 MHz burst detection
./burst_detector.py -f 433.92

# LoRa band + save IQ per burst
./burst_detector.py -f 915 -s -45 --record

# Custom log file
./burst_detector.py -f 433.92 --log ~/SIGINT/logs/ism_bursts.csv

# Catch very short bursts (10ms+)
./burst_detector.py -f 462.5625 --min-burst 0.01
```

| Flag | Default | Description |
|------|---------|-------------|
| `-f` | 433.92 | Center frequency (MHz) |
| `-s` | -40 | Squelch threshold (dB) |
| `-g` | 38 | RF gain |
| `-r` | 2.4 | Sample rate (Msps) |
| `-o` | ~/SIGINT/recordings | IQ output directory |
| `--record` | off | Save IQ data for each burst |
| `--log` | ~/SIGINT/logs/bursts.csv | Append burst log to CSV |
| `--min-burst` | 0.02 | Minimum burst duration (s) |

**Output CSV columns:** `timestamp_utc, freq_mhz, duration_ms, peak_power_db, iq_file`

Feed CSV into `baseline_diff.py` or `intel_packager.py` for analysis.

---

## power_logger.py — Continuous Power Logger

Wraps `rtl_power` to produce time-series spectral data over a frequency range. Generates heatmap-ready CSV for spectrum occupancy studies and pattern-of-life.

**Dependencies:** rtl_power (part of rtl-sdr package), optionally numpy+matplotlib for heatmaps

```bash
# ISM 433 band (400-450 MHz)
./power_logger.py

# VHF band, fine resolution
./power_logger.py -l 144 -u 148 -b 25k

# LoRa band, 2 hours, generate spectrogram
./power_logger.py -l 900 -u 930 --duration 7200 --heatmap

# UHF FRS/GMRS
./power_logger.py -l 460 -u 470 -i 5
```

| Flag | Default | Description |
|------|---------|-------------|
| `-l` | 400 | Lower frequency bound (MHz) |
| `-u` | 450 | Upper frequency bound (MHz) |
| `-b` | 100k | Frequency bin size |
| `-i` | 10 | Sweep interval (seconds) |
| `-g` | 38 | RF gain |
| `-p` | 0 | PPM frequency correction |
| `-d` | 0 (infinite) | Total duration (seconds) |
| `-o` | ~/SIGINT/logs | Output directory |
| `--heatmap` | off | Generate spectrogram PNG at end |

**Output:** rtl_power-format CSV + optional `.png` heatmap

---

## signal_alerter.py — Signal Alerter

Monitors a frequency and fires multi-channel alerts when signal activity is detected. Desktop notifications, audible beeps, CSV logging, and custom command execution.

**Dependencies:** rtl_power (part of rtl-sdr package), optionally notify-send (desktop alerts)

```bash
# Alert on FRS Channel 1 activity
./signal_alerter.py -f 462.5625

# VHF voice + audible beep
./signal_alerter.py -f 146.52 -s -35 --beep

# ISM band, max 1 alert per minute
./signal_alerter.py -f 433.92 --cooldown 60

# Trigger external script on LoRa activity
./signal_alerter.py -f 915 --command "./start_recording.sh"

# Quiet mode — only print alerts
./signal_alerter.py -f 433.92 -q
```

| Flag | Default | Description |
|------|---------|-------------|
| `-f` | (required) | Target frequency (MHz) |
| `-s` | -40 | Alert threshold (dB) |
| `-g` | 38 | RF gain |
| `-i` | 5 | Scan interval (seconds) |
| `--cooldown` | 30 | Min seconds between alerts |
| `--beep` | off | Play audible alert sound |
| `--command` | none | Shell command on alert (gets env vars) |
| `--log` | ~/SIGINT/logs/alerts.csv | Alert log path |
| `-q` | off | Quiet — suppress routine scan output |

**Custom command environment variables:**
- `ALERT_FREQ` — frequency in MHz
- `ALERT_POWER` — detected power in dB
- `ALERT_NUM` — sequential alert number
- `ALERT_TIME` — UTC timestamp

**Output CSV columns:** `timestamp_utc, freq_mhz, power_db, threshold_db, alert_num`

---

## baseline_diff.py — Baseline Diff

Compares two `rtl_433` CSV baselines and reports changes: new signals, disappeared signals, power level shifts, and repetition rate changes.

**Dependencies:** Python 3 (stdlib only, no external packages)

```bash
# Compare two baselines
./baseline_diff.py baselines/day1.csv baselines/day2.csv

# Custom power threshold
./baseline_diff.py old.csv new.csv --threshold 5

# Save report to file
./baseline_diff.py old.csv new.csv -o ~/SIGINT/logs/diff_report.txt
```

| Flag | Default | Description |
|------|---------|-------------|
| (positional 1) | (required) | Old/reference baseline CSV |
| (positional 2) | (required) | New baseline CSV to compare |
| `-t` | 6 | Power change threshold (dB) |
| `-o` | stdout | Write report to file |

**Anomaly types reported:**
- **NEW SIGNALS** — Not in old baseline. Potential threat. Investigate.
- **DISAPPEARED** — Was present, now gone. Source moved or powered off.
- **POWER CHANGES** — Same source, significant strength change.
- **RATE CHANGES** — Same source, transmitting more/less often.

Generate baselines with: `rtl_433 -f 433.92M -R all -F csv:baseline.csv`

---

## intel_packager.py — Intel Packager

Ingests all collection logs and produces a formatted one-page markdown intelligence summary. The final F3EAD DISSEMINATE step.

**Dependencies:** Python 3 (stdlib only)

```bash
# From burst data
./intel_packager.py --bursts ~/SIGINT/logs/bursts.csv

# Full data stack
./intel_packager.py --bursts bursts.csv --alerts alerts.csv --bearings df.csv -o report.md

# Auto-discover all logs in a directory
./intel_packager.py --all ~/SIGINT/logs/ --title "OP WATCHDOG" --location "Grid EN82"

# Include baseline diff
./intel_packager.py --bursts b.csv --baseline-diff diff.txt -o intel.md
```

| Flag | Default | Description |
|------|---------|-------------|
| `--bursts` | none | Burst detector CSV |
| `--alerts` | none | Signal alerter CSV |
| `--bearings` | none | DF bearings CSV (timestamp,freq,bearing_deg,confidence) |
| `--baseline-diff` | none | baseline_diff.py text report |
| `--all` | none | Auto-discover all logs in directory |
| `-o` | stdout | Output file path |
| `--title` | none | Operation name for header |
| `--location` | none | Collection location |

**Report sections:**
1. Executive Summary (total events, top frequencies, time span)
2. Burst Activity (per-frequency stats, hourly pattern-of-life)
3. Threshold Alerts (table of last 20)
4. DF Bearings + triangulation candidates
5. Baseline Comparison (embedded diff)
6. Analyst Recommendations (auto-generated action items)

---

## build_freq_db.py — Frequency Database Builder

Pulls from multiple public sources and builds a local SQLite frequency identification database. Run once to seed, re-run anytime to update with latest device lists.

**Dependencies:** Python 3 (stdlib only — uses urllib, sqlite3, json, re)

```bash
# Full build (fetches rtl_433 + Artemis from GitHub)
./build_freq_db.py

# Offline mode (seed data only, no network)
./build_freq_db.py --offline

# Custom output path
./build_freq_db.py --db /var/lib/recon-raven/databases/freq_db.sqlite
```

| Flag | Default | Description |
|------|---------|-------------|
| `--db` | `data/freq_db.sqlite` | Output SQLite path |
| `--offline` | off | Skip network fetches, use seed only |

**Data sources:**
1. **Seed allocations** (86 entries) — US/EU band plan: VHF, UHF, 800 MHz, ISM, airband, marine, ham, public safety, satellite
2. **rtl_433 devices** (313+ entries) — Every protocol rtl_433 can decode (weather stations, TPMS, keyfobs, sensors)
3. **Artemis signal DB** (500+ entries when available) — Community-maintained RF signal encyclopedia

**Output:** `data/freq_db.sqlite` (~108 KB)

The DB is committed to the repo so it works offline immediately. `install.sh` re-builds it on install/update to pull the latest device lists.

---

## freq_identify.py — Frequency Identification Tool

Looks up frequencies against the local database. Identifies what service/protocol operates at a given MHz value. Can annotate intel reports in-place.

**Dependencies:** Python 3 (stdlib only), `data/freq_db.sqlite`

```bash
# Identify single frequency
./freq_identify.py 463.000

# Multiple frequencies
./freq_identify.py 463.000 145.500 433.920 857.478

# Identify all frequencies in a CSV (reads freq_mhz column)
./freq_identify.py --csv /var/lib/recon-raven/logs/alerts.csv

# Annotate an intel report in-place (adds signal names after MHz values)
./freq_identify.py --annotate intel_report.md

# JSON output for scripting
./freq_identify.py 463.000 --json
```

| Flag | Default | Description |
|------|---------|-------------|
| (positional) | — | Frequency/frequencies in MHz |
| `--csv` | — | CSV file with `freq_mhz` column |
| `--annotate` | — | Markdown file to annotate in-place |
| `--json` | off | Output as JSON (for piping) |
| `--db` | `data/freq_db.sqlite` | Database path |

**Example output:**
```
463.000 MHz:
  GMRS/UHF Business (463.000–463.200 MHz, NFM, commercial)
    └─ GMRS repeater outputs / UHF business
  UHF Business/Public Safety (462.000–470.000 MHz, NFM, commercial)
    └─ Mixed commercial/PS

857.478 MHz:
  P25 Trunked (common) (857.000–860.000 MHz, P25, public_safety)
    └─ Common P25 trunked allocation
```

**Annotation mode** transforms this in a report:
- Before: `463.000 MHz — 66 event(s)`
- After: `463.000 MHz (GMRS/UHF Business) — 66 event(s)`

---

## sigint_adaptive.sh — Adaptive SIGINT Collector

The crown jewel. Implements the full automated F3EAD loop:

1. **FIND** — Quick 3-band spectrum sweep (~30s)
2. **FIX** — Compare against stored baseline, identify anomalies (+8 dB)
3. **FINISH** — Target each anomalous frequency with 10s voice capture

Only records when something **deviates from normal**. No wasted dwell time on dead channels. When a new transmitter appears or an existing one spikes, it automatically focuses collection on that frequency.

**Dependencies:** rtl_power, rtl_fm, sox, bc, python3, RTL-SDR dongle

```bash
# First run — builds baseline (3 averaged sweeps), then monitors
./sigint_adaptive.sh 8 build

# Subsequent runs — uses existing baseline
./sigint_adaptive.sh 8

# 12-hour overnight
./sigint_adaptive.sh 12

# Force baseline rebuild (e.g., moved to new location)
./sigint_adaptive.sh 8 build
```

| Arg | Default | Description |
|-----|---------|-------------|
| `$1` | 8 | Duration in hours |
| `$2` | run | Mode: `run` (use existing baseline) or `build` (rebuild first) |

**Configuration (edit in script):**

| Variable | Default | Description |
|----------|---------|-------------|
| `ANOMALY_DB` | 8 | dB above baseline to trigger targeting |
| `VOICE_DWELL` | 10 | Seconds to record when targeting anomaly |
| `VOICE_THRESHOLD` | 10% | Voice-band energy gate (after 300-3000Hz bandpass) |
| `MIN_VOICE_SEC` | 1.5 | Minimum voice duration to keep (rejects PTT blips) |
| `SWEEP_INTERVAL` | 120 | Seconds between spectrum checks |

**Voice detection pipeline:**
1. Record raw FM audio (no RF squelch — carriers always present)
2. Bandpass filter 300-3000 Hz (removes CTCSS tones at 67-254 Hz)
3. Sox silence detection at 10% threshold (idle carrier = ~8% energy)
4. Duration check ≥ 1.5s (rejects PTT key-ups without speech)

**Bands monitored:**

| Band | Range | Resolution |
|------|-------|-----------|
| VHF | 136–174 MHz | 50 kHz bins |
| UHF | 400–470 MHz | 100 kHz bins |
| 800 MHz | 806–870 MHz | 100 kHz bins |

**Output:**
- Baseline: `/var/lib/recon-raven/baselines/spectrum_baseline.json`
- Voice captures: `/var/lib/recon-raven/recordings/target_<freq>MHz_<timestamp>.wav`
- Log: `/var/lib/recon-raven/logs/adaptive_<timestamp>.log`

**Why this works better than the scanning approach:**
- Scanning voice recorder: 10 channels × 6s = 70s cycle, 8.5% duty per channel
- Adaptive collector: only targets active anomalies, 10s dwell on what matters
- Result: catches transmissions you'd otherwise miss

---

## sigint_sweep.sh — Multi-Band Spectrum Sweep

Long-duration unattended spectrum survey across VHF, UHF, and 800 MHz P25 bands. Uses `rtl_power` to cycle through all 3 bands, building a temporal heatmap of activity. Designed for overnight pattern-of-life collection.

**Dependencies:** rtl_power (part of rtl-sdr package), RTL-SDR dongle

```bash
# Default — 8 hours
./sigint_sweep.sh

# 12-hour collection
./sigint_sweep.sh 12

# Custom output directory
./sigint_sweep.sh 8 /tmp/sweep_data
```

| Arg | Default | Description |
|-----|---------|-------------|
| `$1` | 8 | Duration in hours |
| `$2` | /var/lib/recon-raven/logs | Output directory |

**Bands collected:**

| Band | Range | Bin Size | Targets |
|------|-------|----------|---------|
| VHF | 136–174 MHz | 25 kHz | Baofengs, MURS, marine, ham 2m, public safety |
| UHF | 400–470 MHz | 50 kHz | GMRS/FRS, business, ISM 433 |
| 800 MHz | 806–870 MHz | 50 kHz | P25 trunked, public safety, security |

**Cycle time:** ~33 seconds for all 3 bands  
**Output:** 3 CSV files (rtl_power format) — one per band, timestamped

Feed output into `baseline_diff.py` or `intel_packager.py` for analysis, or visualize with `heatmap.py`.

---

## voice_scanner.sh — Scanning Voice Recorder

Cycles through known active voice frequencies with squelch-gated recording. When signal breaks squelch during the dwell window, records audio to WAV. The "poor man's scanner" for a single RTL-SDR.

**Dependencies:** rtl_fm (part of rtl-sdr package), sox, RTL-SDR dongle

```bash
# Default — 8 hours
./voice_scanner.sh

# 12-hour overnight recording
./voice_scanner.sh 12
```

| Arg | Default | Description |
|-----|---------|-------------|
| `$1` | 8 | Duration in hours |

**Configuration (edit in script):**

| Variable | Default | Description |
|----------|---------|-------------|
| `DWELL_SEC` | 4 | Seconds to listen per channel |
| `SQUELCH_LEVEL` | 40 | rtl_fm squelch (higher = tighter) |
| `CHANNELS` | 10 presets | Freq:mode:label array |
| `OUTPUT_DIR` | /var/lib/recon-raven/recordings | WAV output path |

**Default channel list (edit for your locale):**
- 153.64 MHz — VHF Business
- 159.07 MHz — VHF Public Safety
- 145.50 MHz — 2m Ham Repeater
- 443.40 MHz — 70cm Ham Voice
- 446.20 MHz — FRS Channel 1
- 454.60 MHz — UHF Business
- 463.00 MHz — GMRS Repeater
- 465.80 MHz — UHF Business
- 468.60 MHz — GMRS/Business
- 857.48 MHz — P25 Voice

**Cycle time:** ~40 seconds (10 channels × 4s dwell)  
**Output:** Timestamped WAV files + activity log

**Limitations:** Single SDR can only monitor one frequency at a time. Transmissions on non-current channels are missed. Low-traffic overnight windows minimize this. For full coverage, use multiple SDRs.

---

## Pipeline: How One Script Feeds the Next

The scripts form a pipeline where each tool's output becomes the next tool's input.
Here's the **complete data flow** with real filenames from an actual 31-hour collection:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  COLLECT           ANALYZE              REPORT                               │
│                                                                              │
│  sigint_sweep.sh ──→ sigint_vhf_136-174MHz_20260429-113905.csv              │
│                   ──→ sigint_uhf_400-470MHz_20260429-113905.csv              │
│                   ──→ sigint_p25_806-870MHz_20260429-113905.csv              │
│                        │                                                     │
│                        ▼                                                     │
│              sigint_adaptive.sh (reads sweep → builds baseline)              │
│                        │                                                     │
│                        ├──→ spectrum_baseline.json                           │
│                        ├──→ adaptive_20260430-101009.log (anomalies)         │
│                        └──→ target_137.357MHz_20260430-104251.wav            │
│                                                                              │
│  burst_detector.py ──→ bursts_68b237dc_20260429-135535.csv                  │
│                                                                              │
│  voice_scanner.sh ───→ 70cm_Ham_Voice_20260430-081435.wav                   │
│                   ───→ voice_scanner_20260429-212635.log                     │
│                                                                              │
│  baseline_diff.py ──→ diff_report.txt (new/missing/changed signals)         │
│                                                                              │
│  intel_packager.py ─← (all of the above)                                    │
│                   ──→ intel_report_20260430.md                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Step 1: Spectrum Survey (FIND)

Collect raw spectrum data across all bands. Run overnight unattended.

```bash
# 12-hour sweep → produces 3 CSV files per band
./sigint_sweep.sh 12

# Output files (rtl_power CSV format):
#   /var/lib/recon-raven/logs/sigint_vhf_136-174MHz_20260429-113905.csv  (5.5 MB)
#   /var/lib/recon-raven/logs/sigint_uhf_400-470MHz_20260429-113905.csv  (5.3 MB)
#   /var/lib/recon-raven/logs/sigint_p25_806-870MHz_20260429-113905.csv  (4.8 MB)
```

### Step 2: Build Baseline & Detect Anomalies (FIX)

The adaptive collector reads sweep data, averages it into a baseline, then loops
comparing new sweeps against that baseline. Anything +8 dB over baseline triggers
targeted collection.

```bash
# First run — build baseline from 3 averaged sweeps, then monitor 8 hours
./sigint_adaptive.sh 8 build

# Output:
#   /var/lib/recon-raven/baselines/spectrum_baseline.json   (62 frequencies)
#   /var/lib/recon-raven/logs/adaptive_20260430-101009.log  (anomaly detections)
#   /var/lib/recon-raven/recordings/target_137.357MHz_20260430-104251.wav
```

**Sample log output** (real data from Apr 30):
```
[2026-04-30 11:41:53] Cycle 93 | ANOMALIES DETECTED:
[2026-04-30 11:41:53]   → 153.643 MHz | power: 13.48 dB | +35.68 dB over baseline
[2026-04-30 11:42:03]   → 156.357 MHz | power: 5.95 dB | +27.05 dB over baseline
[2026-04-30 11:42:13]   → 463.000 MHz | power: 3.25 dB | +18.05 dB over baseline
[2026-04-30 11:49:36] Cycle 100 | No anomalies | Captures: 1
```

### Step 3: Burst Detection (parallel FIND)

Run alongside the adaptive collector to catch short data bursts (LoRa, FSK, ISM).

```bash
# ISM 433 MHz burst detection — runs in background
./burst_detector.py -f 433.92 --record --log ~/SIGINT/logs/bursts.csv &

# Output CSV (real data):
#   bursts_68b237dc_20260429-135535.csv
#   Contents:
#     timestamp_utc,freq_mhz,duration_ms,peak_power_db,iq_file
#     2026-04-29 13:56:36.785,433.9200,60018.1,-16.2,
#     2026-04-29 13:56:48.231,433.9200,11425.4,-16.6,
```

### Step 4: Voice Recording (parallel FIND)

Cycle through known voice frequencies for human intelligence.

```bash
# 8-hour overnight voice scan
./voice_scanner.sh 8

# Output:
#   /var/lib/recon-raven/recordings/70cm_Ham_Voice_20260430-081435.wav
#   /var/lib/recon-raven/logs/voice_scanner_20260429-212635.log
```

### Step 5: Baseline Comparison (ANALYZE)

Compare yesterday's spectrum snapshot to today's.

```bash
# Compare two rtl_433 baselines
./baseline_diff.py baselines/day1.csv baselines/day2.csv -o ~/SIGINT/logs/diff_report.txt

# Output: text report listing NEW, DISAPPEARED, POWER_CHANGED, RATE_CHANGED signals
```

### Step 6: Generate Intelligence Report (DISSEMINATE)

Feed ALL collected data into `intel_packager.py` for a single-page summary.

```bash
# Option A: specify each file explicitly
./intel_packager.py \
  --bursts /var/lib/recon-raven/logs/bursts_68b237dc_20260429-135535.csv \
  --alerts /tmp/alerts.csv \
  --baseline-diff /var/lib/recon-raven/logs/diff_report.txt \
  --title "OP BASELINE" \
  --location "Home QTH / Grid EM73" \
  -o /var/lib/recon-raven/logs/intel_report_20260430.md

# Option B: auto-discover all logs in a directory
./intel_packager.py \
  --all /var/lib/recon-raven/logs/ \
  --title "OP BASELINE" \
  -o intel_report.md
```

**Sample output** (real data from 31-hour collection):
```markdown
# SIGINT Intelligence Summary

**Generated:** 2026-04-30 16:54:53 UTC
**Operation:** OP BASELINE
**Location:** Home QTH / Grid EM73

## Executive Summary
- **4** burst(s) detected across **16** frequency/frequencies
- **133** threshold alert(s) triggered
- Collection window: `2026-04-29 04:17:14` → `2026-04-30 11:54:23`

**Most active frequencies:**
  - 463.000 MHz — 66 event(s)
  - 145.500 MHz — 17 event(s)
  - 409.800 MHz — 14 event(s)
  - 857.478 MHz — 12 event(s)

## Analyst Recommendations
- [ ] Prioritize collection on **433.9200 MHz** (4 bursts)
- [ ] Consider tightening squelch threshold (high alert volume)
```

---

## Quick-Start: Full Unattended Session

```bash
# === Night before deployment ===

# 1. Build baseline (first time only, ~2 min)
./sigint_adaptive.sh 1 build

# 2. Start adaptive collector (runs 12 hours, backgrounds itself)
nohup ./sigint_adaptive.sh 12 > /dev/null 2>&1 &
echo "Adaptive PID: $!"

# === Next morning ===

# 3. Check what was collected
ls -la /var/lib/recon-raven/recordings/target_*.wav
tail -20 /var/lib/recon-raven/logs/adaptive_*.log

# 4. Generate report from everything collected
./intel_packager.py \
  --all /var/lib/recon-raven/logs/ \
  --title "Overnight Collection" \
  -o /var/lib/recon-raven/logs/intel_report.md

cat /var/lib/recon-raven/logs/intel_report.md
```

---

## Output File Locations

All scripts default to `/var/lib/recon-raven/` on the collection box:

```
/var/lib/recon-raven/
├── recordings/               ← voice captures + targeted anomaly recordings
│   ├── target_137.357MHz_20260430-104251.wav     (adaptive collector)
│   ├── 70cm_Ham_Voice_20260430-081435.wav        (voice scanner)
│   └── capture_433.92MHz_*.cf32                  (squelch recorder IQ)
├── logs/                     ← all CSV/log output
│   ├── adaptive_20260430-101009.log              (adaptive anomaly log)
│   ├── bursts_68b237dc_20260429-135535.csv       (burst detector)
│   ├── sigint_vhf_136-174MHz_20260429-113905.csv (spectrum sweep)
│   ├── sigint_uhf_400-470MHz_20260429-113905.csv
│   ├── sigint_p25_806-870MHz_20260429-113905.csv
│   ├── voice_scanner_20260429-212635.log         (voice scanner activity)
│   ├── intel_report_20260430.md                  (packaged intel report)
│   └── diff_report.txt                           (baseline comparison)
└── baselines/                ← spectrum fingerprints
    └── spectrum_baseline.json                    (62 freq averages)
```

For GNU Radio scripts (squelch_recorder, burst_detector), the default is `~/SIGINT/`:
```
~/SIGINT/
├── recordings/    ← IQ captures (.cf32)
├── logs/          ← burst CSVs, alert CSVs, power logger data
└── baselines/     ← rtl_433 baseline CSVs for diff comparison
```
