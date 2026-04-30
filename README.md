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
| `baseline_diff.py` | ANALYZE | Compares two rtl_433 baselines — reports new/missing/changed signals |
| `intel_packager.py` | DISSEMINATE | Generates one-page markdown intel summary from all logs |

See [`scripts/README.md`](scripts/README.md) for full usage documentation.

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
