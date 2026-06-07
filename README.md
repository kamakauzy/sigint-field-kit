# sigint-field-kit

One-script installer for a SIGINT / SDR field environment on **DragonOS Focal / FocalX** (Ubuntu-based).

## What Gets Installed

| Category | Tools |
|----------|-------|
| **SDR Receivers** | GQRX, SDR++, CubicSDR, SoapySDR |
| **Signal Processing** | GNU Radio + GRC, gr-osmosdr |
| **Decoding / Analysis** | rtl_433, URH, SigMF, inspectrum, multimon-ng, sox |
| **Meshtastic / LoRa** | Meshtastic CLI, pyLoRa |
| **Advanced (cloned)** | FISSURE, KrakenSDR DOA |
| **TX tools** | HackRF tools, gr-hackrf (opt-in with `--tx`) |
| **RTL-SDR** | Drivers, udev rules, DVB kernel blacklist |

Also creates:
- `~/SIGINT/` working directory with `baselines/`, `recordings/`, `logs/`, `intel-packages/`
- `capture-baseline.sh` — 30-min rtl_433 multi-frequency baseline capture
- `emcon-on.sh` / `emcon-off.sh` — WiFi/Bluetooth kill switches

## Quick Start

```bash
git clone https://github.com/kamakauzy/sigint-field-kit.git
cd sigint-field-kit
chmod +x install.sh verify-setup.sh
```

### RX-only (default)
```bash
sudo ./install.sh
```

### Include TX tools (HackRF)
```bash
sudo ./install.sh --tx
```

### Skip apt update (faster re-run)
```bash
sudo ./install.sh --skip-update
```

### Verify installation
```bash
chmod +x verify-setup.sh
./verify-setup.sh            # software checks only
./verify-setup.sh --dongle   # also tests RTL-SDR USB device
```

## Post-Install Checklist

1. **Reboot** after install (udev rules + group membership take effect)
2. Plug in RTL-SDR dongle → run `rtl_test` to confirm detection
3. Run `./verify-setup.sh --dongle` to validate everything
4. Run `~/SIGINT/capture-baseline.sh` to test a baseline capture
5. FISSURE requires a separate install step: `cd ~/Tools/FISSURE && ./install`

## Working Directory

```
~/SIGINT/
├── baselines/          # rtl_433 CSV/JSON exports
├── recordings/         # URH / GQRX signal recordings
├── logs/               # Signal logs and field notes
├── intel-packages/     # F3EAD intelligence products
├── capture-baseline.sh # Quick baseline helper
├── emcon-on.sh         # Kill WiFi/BT
└── emcon-off.sh        # Restore WiFi/BT
```

## Notes

- Default mode is **receive-only**; transmit tools require `--tx`
- DragonOS may already include some tools; the script skips what's already present
- Full install log saved to `/tmp/sigint-install-*.log`
- FISSURE and KrakenSDR are cloned but require their own install steps for full functionality

## Uninstall

```bash
sudo ./uninstall.sh           # remove packages, keep ~/SIGINT data
sudo ./uninstall.sh --purge   # remove everything including ~/SIGINT and ~/Tools clones
```

## Included Resources

### Reference Cards (`reference/`)
- **F3EAD Cycle** — Find → Fix → Finish → Exploit → Analyze → Disseminate quick reference
- **Signal Types** — Identification table for voice, data, digital, beacon, and WiFi signals
- **Direction Finding** — Body-block, Yagi sweep, cross-bearing, and KrakenSDR techniques
- **Field Checklist** — Step-by-step execution checklist for signal collection operations

### Templates (`templates/`)
- **Signal Log** — Per-session log with classification key and threat levels

### Flow Graphs (`flowgraphs/`)
- **fm_monitor.grc** — Wideband FM voice receiver (146.52 MHz default)
- **ism_scanner_433.grc** — ISM 433 MHz passive scanner for weather/sensor devices
- **lora_watcher_915.grc** — LoRa / Meshtastic 915 MHz band watcher
- **nbfm_scanner.grc** — FRS/GMRS/MURS channel scanner with squelch + audio (10 presets)
- **quad_band_monitor.grc** — 4-dongle simultaneous VHF/ISM/UHF/LoRa tactical display

See [`flowgraphs/README.md`](flowgraphs/README.md) for detailed per-graph instructions.

### Automation Scripts (`scripts/`)

Python scripts for unattended/headless signal collection, aligned to the F3EAD cycle:

| Script | F3EAD Phase | Purpose |
|--------|-------------|---------|
| `squelch_recorder.py` | FIND | Auto-records IQ when signal exceeds squelch threshold |
| `burst_detector.py` | FIND/FIX | Detects, timestamps, and logs short RF bursts |
| `power_logger.py` | FIND | Continuous wideband power measurement via rtl_power |
| `signal_alerter.py` | FIND/FIX | Desktop/audible/webhook alerts on frequency activity |
| `sigint_sweep.sh` | FIND | Multi-band spectrum sweep (VHF/UHF/800) for pattern-of-life |
| `voice_scanner.sh` | FIND/FIX | Scanning voice recorder — squelch-gated WAV capture across channels |
| `sigint_adaptive.sh` | FIND/FIX/FINISH | Adaptive collector — baseline→detect anomaly→target with voice capture |
| `baseline_diff.py` | ANALYZE | Compares two rtl_433 baselines — reports new/missing/changed signals |
| `freq_identify.py` | ANALYZE | Identifies signals by frequency from local database (399+ entries) |
| `build_freq_db.py` | MAINTAIN | Builds/updates frequency DB from rtl_433 + Artemis + seed data |
| `intel_packager.py` | DISSEMINATE | Generates one-page markdown intel summary from all logs |
| `kraken_doa_collector.py` | FIND/FIX | Polls KrakenSDR Pi for DOA bearings, logs to SQLite + CSV |
| `emitter_locator.py` | FIX | Triangulates emitter locations from DOA bearing database |
| `kraken_hunter.sh` | FIND/FIX | Fox hunt mode — DOA bearing + RTL-SDR voice recording |
| `kraken_test_harness.py` | TEST | Generates synthetic DOA data for pipeline testing |
| `antenna_calculator.py` | PLAN | Computes optimal antenna array sizing for target bands |

See [`scripts/README.md`](scripts/README.md) for full usage documentation.

---

## KrakenSDR Integration — Direction Finding & Triangulation

5-channel coherent receiver integration for DOA (Direction of Arrival) bearing estimation and emitter geolocation. The KrakenSDR runs on a dedicated Raspberry Pi; potato orchestrates collection and analysis.

### Architecture

```
KrakenSDR (5ch coherent) ──USB──→ Raspberry Pi 4 ("kraken-pi")
                                    ├─ Heimdall DAQ (raw IQ + calibration)
                                    ├─ krakensdr_doa (MUSIC algorithm → bearings)
                                    └─ kraken_forwarder.py (:8081 JSON API)
                                          │
                                     LAN (192.168.1.120)
                                          │
                              potato (DragonOS) ◄── RTL-SDR V4 (voice recording)
                                ├─ kraken_doa_collector.py  → SQLite + CSV
                                ├─ emitter_locator.py       → triangulation + GeoJSON
                                ├─ kraken_hunter.sh         → bearing + voice recording
                                ├─ intel_packager.py        → reports with bearings
                                └─ tools/doa_map.html       → interactive map viewer
```

### Hardware Required

| Item | Purpose | Notes |
|------|---------|-------|
| KrakenSDR | 5-channel coherent SDR | Must update firmware via USB before first use |
| Raspberry Pi 4 (4GB+) | KrakenSDR host | Dedicated — runs DAQ + DOA full-time |
| 32GB+ microSD | Pi OS | Use Raspberry Pi OS Lite (64-bit) |
| USB-C power supply | Pi power | 5V/3A minimum |
| 5× VHF/UHF whip antennas | Circular array | Match to target band (see antenna_calculator.py) |
| Ground plane / mount | Array geometry | Must maintain precise element spacing |
| Ethernet cable | Pi ↔ potato | Static IP 192.168.1.120 |
| GPS dongle (optional) | Position + time | For mobile collection / triangulation |

### KrakenSDR Firmware Update (Do This First)

Before the Pi setup, update the KrakenSDR firmware from a desktop:

1. Download the firmware updater from [KrakenRF GitHub](https://github.com/krakenrf/krakensdr_firmware)
2. Connect KrakenSDR via USB to your desktop (not the Pi)
3. Run the updater — follow their instructions
4. Verify all 5 channels are detected

### Pi Setup Workflow

```bash
# 1. Flash Raspberry Pi OS Lite (64-bit) to SD card
# 2. Prep the SD card for headless boot:
sudo bash kraken/prep_pi_sdcard.sh /mnt/boot /mnt/rootfs

# 3. Insert SD, boot Pi, then SSH in:
ssh pi@192.168.1.120

# 4. Clone this repo and run the Pi installer:
git clone https://github.com/kamakauzy/sigint-field-kit.git
cd sigint-field-kit
sudo bash kraken/install_kraken_pi.sh

# 5. Reboot — services start automatically
sudo reboot
```

### Collection Workflow

```bash
# On potato — start collecting bearings:
python3 scripts/kraken_doa_collector.py --lat 35.4676 --lon -97.5164

# Fox hunt — bearing + voice recording per frequency:
bash scripts/kraken_hunter.sh

# Analyze / triangulate:
python3 scripts/emitter_locator.py --since 1h --geojson data/emitters.json

# Generate intel report with DOA data:
python3 scripts/intel_packager.py --kraken-db data/kraken_doa.sqlite -o report.md

# View results on map:
# Open tools/doa_map.html in browser, load the GeoJSON file
```

### Antenna Array Sizing

The default config uses 12.7cm radius, optimized for ~430–590 MHz (UHF/FRS/GMRS). Use the calculator to check other bands:

```bash
python3 scripts/antenna_calculator.py                  # default array info
python3 scripts/antenna_calculator.py --freq 462.7125  # optimal for FRS
python3 scripts/antenna_calculator.py --freq 146 462   # compromise VHF+UHF
python3 scripts/antenna_calculator.py --all-bands       # full coverage table
```

**Key insight:** You can't cover both VHF and UHF well with one array size. Build two ground planes or optimize for your primary target band.

### Testing Without Hardware

Generate synthetic DOA data to dry-run the full pipeline:

```bash
python3 scripts/kraken_test_harness.py
python3 scripts/emitter_locator.py --db data/kraken_test.sqlite --geojson data/test_emitters.json
python3 scripts/intel_packager.py --kraken-db data/kraken_test.sqlite -o data/test_report.md
# Open tools/doa_map.html → load data/test_emitters.json
```

### KrakenSDR Scripts Reference

| Script | Location | Purpose |
|--------|----------|---------|
| `install_kraken_pi.sh` | `kraken/` | Complete Pi setup (DAQ + DOA + API + systemd) |
| `prep_pi_sdcard.sh` | `kraken/` | SD card prep (static IP, SSH, USB current) |
| `kraken_defaults.json` | `kraken/config/` | Central config (Pi IP, antenna, frequencies) |
| `kraken_doa_collector.py` | `scripts/` | Continuous bearing collection → SQLite/CSV |
| `emitter_locator.py` | `scripts/` | Bearing clustering + Stansfield triangulation → GeoJSON |
| `kraken_hunter.sh` | `scripts/` | Fox hunt: DOA bearing + RTL-SDR voice recording |
| `kraken_test_harness.py` | `scripts/` | Synthetic data generator for pipeline testing |
| `antenna_calculator.py` | `scripts/` | Array sizing calculator for target bands |
| `doa_map.html` | `tools/` | Leaflet.js map viewer for GeoJSON output |

---

## Tested On

| OS | Base | Status |
|----|------|--------|
| DragonOS FocalX R7+ | Ubuntu 22.04 | Primary target |
| DragonOS Focal | Ubuntu 20.04 | Supported |
| Ubuntu 22.04 LTS | — | Works (no pre-installed SDR tools) |
| Ubuntu 20.04 LTS | — | Works (no pre-installed SDR tools) |

Contributions welcome — open an issue if you test on another distro.

## Docker (test only)

Build and test the installer in a clean container without hardware:

```bash
docker build -t sigint-field-kit .
docker run -it sigint-field-kit ./verify-setup.sh
```

> Note: GUI apps and USB SDR access require host passthrough and are not available inside the container. This is for validating the install logic only.

## License

[The Unlicense](LICENSE) — public domain. Do whatever you want with it.
