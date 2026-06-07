#!/usr/bin/env bash
# ============================================================================
#  KrakenSDR Raspberry Pi Setup Script
# ============================================================================
#  Sets up a Raspberry Pi 4 as a dedicated KrakenSDR DOA processing node.
#  Run this on the Pi after a fresh Raspberry Pi OS (64-bit) install.
#
#  Prerequisites:
#    - Raspberry Pi 4 (4GB+ RAM recommended)
#    - Raspberry Pi OS 64-bit (Bookworm or Bullseye)
#    - KrakenSDR connected via USB
#    - Network connectivity to potato (192.168.1.111)
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/kamakauzy/sigint-field-kit/master/kraken/install_kraken_pi.sh | sudo bash
#    # or
#    sudo ./install_kraken_pi.sh
#
#  After install:
#    - KrakenSDR DOA web UI: http://<pi-ip>:8080
#    - DOA data API: http://<pi-ip>:8081/doa
#    - Services auto-start on boot
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
banner(){ echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && fail "Run as root: sudo $0"
[[ $(uname -m) != "aarch64" ]] && warn "Not aarch64 — this script targets Raspberry Pi 4 (64-bit)"

INSTALL_DIR="/opt/kraken"
ACTUAL_USER="${SUDO_USER:-pi}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

run_as_user() { sudo -u "$ACTUAL_USER" "$@"; }

mkdir -p "$INSTALL_DIR"

# ── 1. System dependencies ────────────────────────────────────────────────
banner "1/5  System Dependencies"

apt-get update -qq
apt-get install -y -qq \
    build-essential cmake git python3 python3-pip python3-venv \
    python3-numpy python3-scipy python3-requests \
    libusb-1.0-0-dev libfftw3-dev libatlas-base-dev \
    gpsd gpsd-clients python3-gps \
    nginx \
    2>/dev/null
ok "System dependencies"

# Disable kernel DVB modules that conflict with RTL-SDR / KrakenSDR
cat > /etc/modprobe.d/kraken-blacklist.conf << 'EOF'
blacklist dvb_usb_rtl28xxu
blacklist dvb_usb_rtl2832u
blacklist rtl2832
blacklist rtl2830
blacklist dvb_usb_v2
blacklist dvb_core
EOF
ok "DVB kernel modules blacklisted"

# ── 2. Heimdall DAQ Firmware ──────────────────────────────────────────────
banner "2/5  Heimdall DAQ Firmware"

HEIMDALL_DIR="$INSTALL_DIR/heimdall_daq_fw"
if [[ -d "$HEIMDALL_DIR" ]]; then
    info "Heimdall already cloned, pulling latest..."
    cd "$HEIMDALL_DIR" && git pull --ff-only 2>/dev/null || true
else
    git clone https://github.com/krakenrf/heimdall_daq_fw.git "$HEIMDALL_DIR"
fi

# Build the Heimdall DAQ
cd "$HEIMDALL_DIR/Firmware"
if [[ -f "daq_chain_config.ini" ]]; then
    ok "Heimdall DAQ config exists"
else
    cp daq_chain_config.ini.DEFAULT daq_chain_config.ini 2>/dev/null || true
fi

# Build C components
if [[ -d "_daq_core" ]]; then
    cd _daq_core
    mkdir -p build && cd build
    cmake .. && make -j"$(nproc)" && ok "Heimdall DAQ core built" || warn "Heimdall build issue — may need manual fix"
    cd "$HEIMDALL_DIR/Firmware"
fi

ok "Heimdall DAQ firmware ready"

# ── 3. KrakenSDR DOA App ─────────────────────────────────────────────────
banner "3/5  KrakenSDR DOA Application"

DOA_DIR="$INSTALL_DIR/krakensdr_doa"
if [[ -d "$DOA_DIR" ]]; then
    info "KrakenSDR DOA already cloned, pulling latest..."
    cd "$DOA_DIR" && git pull --ff-only 2>/dev/null || true
else
    git clone https://github.com/krakenrf/krakensdr_doa.git "$DOA_DIR"
fi

# Create Python venv and install deps
cd "$DOA_DIR"
if [[ ! -d "venv" ]]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install -q -r requirements.txt 2>/dev/null || {
    pip install dash dash-bootstrap-components plotly numpy scipy requests orjson 2>/dev/null || true
}
deactivate
ok "KrakenSDR DOA application ready"

# Link Heimdall into DOA
ln -sf "$HEIMDALL_DIR/Firmware" "$DOA_DIR/heimdall_daq_fw" 2>/dev/null || true

# ── 4. DOA Data Forwarder (API for potato) ────────────────────────────────
banner "4/5  DOA Data Forwarder"

# This lightweight HTTP server runs alongside the DOA app and exposes
# a clean JSON API for the collector on potato to poll.
cat > "$INSTALL_DIR/kraken_forwarder.py" << 'PYEOF'
#!/usr/bin/env python3
"""
KrakenSDR DOA Data Forwarder — Lightweight HTTP API

Reads DOA results from the KrakenSDR DOA application's output and serves
them as JSON on port 8081. Designed to be polled by kraken_doa_collector.py
running on the main workstation.

Endpoints:
  GET /doa          → latest DOA bearings (JSON)
  GET /status       → system status + uptime
  GET /health       → simple health check
"""
import http.server
import json
import os
import re
import time
import threading
from datetime import datetime, timezone
from pathlib import Path

PORT = 8081
DOA_LOG_DIR = "/opt/kraken/krakensdr_doa"
POLL_INTERVAL = 1.0  # seconds between DOA output reads

# Shared state
latest_doa = {
    "timestamp": None,
    "bearings": [],
    "status": "starting"
}
lock = threading.Lock()


def find_doa_output():
    """Find the most recent DOA output file/shared memory."""
    # KrakenSDR DOA writes results to several possible locations
    candidates = [
        Path(DOA_LOG_DIR) / "_UI" / "_web_interface" / "DOA_value.html",
        Path(DOA_LOG_DIR) / "DOA_value.html",
        Path("/run/shm/kraken_doa"),
        Path("/tmp/kraken_doa_output.json"),
    ]
    for c in candidates:
        if c.exists():
            return c
    return None


def parse_doa_output(filepath):
    """Parse DOA results from KrakenSDR output file."""
    bearings = []
    try:
        content = filepath.read_text().strip()

        # Try JSON format first
        try:
            data = json.loads(content)
            if isinstance(data, list):
                return data
            if "bearings" in data:
                return data["bearings"]
        except json.JSONDecodeError:
            pass

        # Try HTML/text format (DOA_value.html)
        # Format varies but typically: freq, bearing, confidence, power
        for line in content.split("\n"):
            line = line.strip()
            if not line or line.startswith("<") or line.startswith("#"):
                continue
            parts = re.split(r'[,\s\t]+', line)
            if len(parts) >= 2:
                try:
                    bearing = {
                        "freq_mhz": float(parts[0]) if len(parts) > 2 else 0,
                        "bearing_deg": float(parts[-2]) if len(parts) > 2 else float(parts[0]),
                        "confidence": float(parts[-1]) if len(parts) > 1 else 0,
                    }
                    if 0 <= bearing["bearing_deg"] <= 360:
                        bearings.append(bearing)
                except (ValueError, IndexError):
                    continue
    except Exception:
        pass
    return bearings


def doa_reader_thread():
    """Background thread that reads DOA output periodically."""
    global latest_doa
    while True:
        try:
            doa_file = find_doa_output()
            if doa_file:
                bearings = parse_doa_output(doa_file)
                with lock:
                    latest_doa = {
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "bearings": bearings,
                        "status": "active",
                        "source": str(doa_file)
                    }
            else:
                with lock:
                    latest_doa["status"] = "no_doa_output"
        except Exception as e:
            with lock:
                latest_doa["status"] = f"error: {e}"
        time.sleep(POLL_INTERVAL)


START_TIME = time.time()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # suppress request logging

    def _json_response(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/doa":
            with lock:
                self._json_response(latest_doa)
        elif self.path == "/status":
            with lock:
                self._json_response({
                    "uptime_sec": round(time.time() - START_TIME),
                    "doa_status": latest_doa["status"],
                    "last_update": latest_doa["timestamp"],
                    "bearing_count": len(latest_doa.get("bearings", [])),
                })
        elif self.path == "/health":
            self._json_response({"ok": True})
        else:
            self._json_response({"error": "not found"}, 404)


if __name__ == "__main__":
    reader = threading.Thread(target=doa_reader_thread, daemon=True)
    reader.start()
    print(f"KrakenSDR DOA forwarder listening on :{PORT}")
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
PYEOF
chmod +x "$INSTALL_DIR/kraken_forwarder.py"
ok "DOA data forwarder installed"

# ── 5. Systemd Services ──────────────────────────────────────────────────
banner "5/5  Systemd Services"

# KrakenSDR DOA service
cat > /etc/systemd/system/kraken-doa.service << EOF
[Unit]
Description=KrakenSDR DOA Direction Finding
After=network.target
Wants=kraken-forwarder.service

[Service]
Type=simple
WorkingDirectory=$DOA_DIR
ExecStart=$DOA_DIR/venv/bin/python3 $DOA_DIR/_UI/_web_interface/kraken_web_interface.py
Restart=on-failure
RestartSec=5
User=$ACTUAL_USER
Environment=PATH=$DOA_DIR/venv/bin:/usr/local/bin:/usr/bin

[Install]
WantedBy=multi-user.target
EOF

# DOA data forwarder service
cat > /etc/systemd/system/kraken-forwarder.service << EOF
[Unit]
Description=KrakenSDR DOA Data Forwarder
After=kraken-doa.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/kraken_forwarder.py
Restart=on-failure
RestartSec=5
User=$ACTUAL_USER

[Install]
WantedBy=multi-user.target
EOF

# Heimdall DAQ service
cat > /etc/systemd/system/kraken-daq.service << EOF
[Unit]
Description=KrakenSDR Heimdall DAQ
Before=kraken-doa.service

[Service]
Type=simple
WorkingDirectory=$HEIMDALL_DIR/Firmware
ExecStart=$HEIMDALL_DIR/Firmware/daq_start_sm.sh
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kraken-daq kraken-doa kraken-forwarder
ok "Systemd services created and enabled"

# ── Summary ───────────────────────────────────────────────────────────────
banner "KrakenSDR Pi Setup Complete"

PI_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}Services:${NC}"
echo "  kraken-daq         Heimdall DAQ firmware"
echo "  kraken-doa         DOA web interface  → http://$PI_IP:8080"
echo "  kraken-forwarder   Data API           → http://$PI_IP:8081/doa"
echo ""
echo -e "${GREEN}Next steps:${NC}"
echo "  1. Connect KrakenSDR 5-element antenna array"
echo "  2. Connect KrakenSDR to Pi via USB"
echo "  3. Reboot: sudo reboot"
echo "  4. Open DOA web UI: http://$PI_IP:8080"
echo "  5. Set antenna configuration in web UI"
echo "  6. On potato, update kraken_defaults.json with Pi IP: $PI_IP"
echo "  7. Run: python3 scripts/kraken_doa_collector.py"
echo ""
echo -e "${YELLOW}Antenna array:${NC}"
echo "  Default: 5-element UCA, radius 12.7cm (~λ/4 at 590 MHz)"
echo "  For VHF (145-156 MHz): increase radius to ~50cm"
echo "  For UHF (462 MHz): radius ~16cm is ideal"
echo "  Mount outdoors/window with clear sky view for best results"
