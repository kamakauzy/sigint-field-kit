# SIGINT Course – DragonOS Setup

Automated installer for the 4-day SIGINT course laptop environment.  
Targets **DragonOS Focal / FocalX** (Ubuntu-based).

## What Gets Installed

| Category | Tools |
|----------|-------|
| **SDR Receivers** | GQRX, SDR++, CubicSDR, SoapySDR |
| **Signal Processing** | GNU Radio + GRC, gr-osmosdr |
| **Decoding / Analysis** | rtl_433, URH, SigMF, inspectrum, multimon-ng, sox |
| **Meshtastic / LoRa** | Meshtastic CLI, pyLoRa |
| **Advanced (cloned)** | FISSURE, KrakenSDR DOA |
| **Instructor-only** | HackRF tools, gr-hackrf (with `--instructor` flag) |
| **RTL-SDR** | Drivers, udev rules, DVB kernel blacklist |

Also creates:
- `~/SIGINT/` directory with `baselines/`, `recordings/`, `logs/`, `intel-packages/`
- `capture-baseline.sh` — 30-min rtl_433 multi-frequency baseline capture
- `emcon-on.sh` / `emcon-off.sh` — WiFi/Bluetooth kill switches

## Quick Start

### Student laptop
```bash
chmod +x install-sigint-course.sh
sudo ./install-sigint-course.sh
```

### Instructor laptop
```bash
sudo ./install-sigint-course.sh --instructor
```

### Skip apt update (faster re-run)
```bash
sudo ./install-sigint-course.sh --skip-update
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
4. Run `~/SIGINT/capture-baseline.sh` to test a 30-min baseline capture
5. FISSURE requires a separate install step: `cd ~/Tools/FISSURE && ./install`

## Course Directory Structure

```
~/SIGINT/
├── baselines/          # rtl_433 CSV/JSON exports
├── recordings/         # URH / GQRX signal recordings
├── logs/               # Signal log templates, field notes
├── intel-packages/     # F3EAD deliverables
├── capture-baseline.sh # Quick baseline helper
├── emcon-on.sh         # Kill WiFi/BT
└── emcon-off.sh        # Restore WiFi/BT
```

## Notes

- Students are **RX-only** — HackRF TX tools are instructor-only (`--instructor`)
- DragonOS may already include some tools; the script skips what's already present
- Full install log saved to `/tmp/sigint-install-*.log`
- FISSURE and KrakenSDR are cloned but require their own install steps for full functionality
