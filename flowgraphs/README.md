# Sample GNU Radio Flow Graphs

Starter `.grc` files for common SIGINT field tasks. Open in GNU Radio Companion (GRC).

All flow graphs require an **RTL-SDR dongle** connected via USB.

## Included Flow Graphs

| File | Purpose | Default Freq |
|------|---------|-------------|
| `fm_monitor.grc` | Wideband FM voice receiver with audio output | 146.52 MHz |
| `ism_scanner_433.grc` | ISM 433 MHz passive scanner (weather, sensors) | 433.92 MHz |
| `lora_watcher_915.grc` | LoRa / Meshtastic 915 MHz band watcher | 915.0 MHz |

## Usage

```bash
gnuradio-companion flowgraphs/fm_monitor.grc
```

Or run directly:
```bash
cd flowgraphs
python3 fm_monitor.py    # after generating from GRC
```

## Notes

- All flow graphs are **receive-only** (passive monitoring)
- Frequency, gain, and volume sliders are adjustable at runtime via the GUI
- Waterfall and FFT displays update in real-time
- Tested with GNU Radio 3.10.x on DragonOS Focal
