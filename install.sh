#!/usr/bin/env bash
# ============================================================================
#  sigint-field-kit – DragonOS SIGINT Toolkit Installer
# ============================================================================
#  Installs SDR receivers, signal analysis tools, and field utilities
#  on DragonOS Focal / FocalX (Ubuntu 20.04/22.04 base).
#
#  Usage:
#    chmod +x install.sh
#    sudo ./install.sh [OPTIONS]
#
#  Options:
#    --rx-only       Install receive-only tools (default)
#    --tx            Include transmit-capable tools (HackRF)
#    --skip-update   Skip apt update/upgrade (faster re-runs)
#    --help          Show this help message
# ============================================================================
set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
banner(){ echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"; }

# ── Argument parsing ───────────────────────────────────────────────────────
ROLE="rx"
SKIP_UPDATE=false

for arg in "$@"; do
    case "$arg" in
        --tx)          ROLE="tx" ;;
        --rx-only)     ROLE="rx" ;;
        --skip-update) SKIP_UPDATE=true ;;
        --help|-h)
            head -17 "$0" | tail -14
            exit 0
            ;;
        *) warn "Unknown option: $arg (ignored)" ;;
    esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (sudo)."
    exit 1
fi

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
LOG_FILE="/tmp/sigint-install-$(date +%Y%m%d-%H%M%S).log"

banner "sigint-field-kit – DragonOS Installer"
info "Role:     $ROLE"
info "User:     $ACTUAL_USER"
info "Home:     $ACTUAL_HOME"
info "Log file: $LOG_FILE"
echo ""

# Helper: run a command as the actual (non-root) user
run_as_user() {
    sudo -u "$ACTUAL_USER" -- "$@"
}

# Helper: track installed items for the summary
declare -a INSTALLED_ITEMS=()
track() { INSTALLED_ITEMS+=("$1"); }

# Redirect all stdout/stderr to log while still printing to terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# ── 1. System update & base dependencies ──────────────────────────────────
banner "1/8  System Update & Base Dependencies"

if [[ "$SKIP_UPDATE" == false ]]; then
    info "Updating package lists..."
    apt-get update -qq
    info "Upgrading existing packages..."
    apt-get upgrade -y -qq
    ok "System updated"
else
    warn "Skipping apt update/upgrade (--skip-update)"
fi

info "Installing base dependencies..."
apt-get install -y -qq \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python3-numpy \
    python3-scipy \
    pipx \
    libusb-1.0-0-dev \
    librtlsdr-dev \
    libfftw3-dev \
    libboost-all-dev \
    pkg-config \
    swig \
    usbutils \
    rfkill \
    net-tools \
    jq \
    unzip \
    sox \
    libsox-fmt-all \
    pv \
    bc \
    2>/dev/null

# Ensure pipx path is set up for the user
run_as_user pipx ensurepath 2>/dev/null || true
ok "Base dependencies installed"
track "Base build tools & dependencies"

# ── 2. RTL-SDR drivers & tools ────────────────────────────────────────────
banner "2/8  RTL-SDR Drivers & Tools"

# Blacklist the DVB-T kernel module so it doesn't grab the dongle
info "Blacklisting dvb_usb_rtl28xxu kernel module..."
cat > /etc/modprobe.d/blacklist-rtlsdr.conf <<'EOF'
# Prevent kernel DVB driver from claiming RTL-SDR dongles
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

# Install rtl-sdr from apt first (baseline)
apt-get install -y -qq rtl-sdr librtlsdr0 2>/dev/null || true
ok "RTL-SDR base drivers"
track "RTL-SDR drivers (rtl-sdr, librtlsdr)"

# ── 3. Core SDR Applications ──────────────────────────────────────────────
banner "3/8  Core SDR Applications"

# --- GQRX ---
info "Installing GQRX..."
apt-get install -y -qq gqrx-sdr 2>/dev/null && ok "GQRX" || warn "GQRX not in repos – install manually or via DragonOS menu"
track "GQRX"

# --- SDR++ ---
info "Checking for SDR++..."
if command -v sdrpp &>/dev/null; then
    ok "SDR++ already installed"
else
    # SDR++ may be pre-installed on DragonOS; try apt first
    apt-get install -y -qq sdrpp 2>/dev/null && ok "SDR++ (apt)" || {
        info "SDR++ not in repos – attempting build from source..."
        SDRPP_DIR="/opt/sdrpp-build"
        if [[ ! -d "$SDRPP_DIR" ]]; then
            git clone --depth 1 https://github.com/AlexandreRouworWorma/SDRPlusPlus.git "$SDRPP_DIR" 2>/dev/null || \
            git clone --depth 1 https://github.com/AlexandreRouma/SDRPlusPlus.git "$SDRPP_DIR"
        fi
        apt-get install -y -qq libglfw3-dev libglew-dev libvolk2-dev 2>/dev/null || true
        mkdir -p "$SDRPP_DIR/build" && cd "$SDRPP_DIR/build"
        cmake .. -DOPT_BUILD_RTL_SDR_SOURCE=ON 2>/dev/null && make -j"$(nproc)" && make install && ok "SDR++ (built from source)" || warn "SDR++ build failed – install from DragonOS Software Center"
        cd /
    }
fi
track "SDR++"

# --- SigDigger ---
info "Checking for SigDigger..."
if command -v SigDigger &>/dev/null; then
    ok "SigDigger already installed"
else
    # Try AppImage first (fastest), fall back to blsd build script
    SIGDIGGER_DIR="/opt/sigdigger"
    mkdir -p "$SIGDIGGER_DIR"
    APPIMAGE_URL="https://github.com/BatchDrake/SigDigger/releases/download/latest/SigDigger-latest-x86_64.AppImage"
    if wget -q "$APPIMAGE_URL" -O "$SIGDIGGER_DIR/SigDigger.AppImage" 2>/dev/null; then
        chmod +x "$SIGDIGGER_DIR/SigDigger.AppImage"
        ln -sf "$SIGDIGGER_DIR/SigDigger.AppImage" /usr/local/bin/SigDigger
        ok "SigDigger (AppImage)"
    else
        info "AppImage download failed – building via blsd..."
        apt-get install -y -qq libsoapysdr-dev libvolk2-dev libfftw3-dev \
            qtbase5-dev qt5-qmake libxml2-dev portaudio19-dev 2>/dev/null || true
        cd "$SIGDIGGER_DIR"
        wget -q https://actinid.org/blsd -O blsd && chmod +x blsd
        ./blsd AmateurDSN APTPlugin 2>/dev/null && ok "SigDigger (built via blsd)" || warn "SigDigger build failed – install manually from https://github.com/BatchDrake/SigDigger"
        cd /
    fi
fi
track "SigDigger"

# --- CubicSDR ---
info "Installing CubicSDR..."
apt-get install -y -qq cubicsdr 2>/dev/null && ok "CubicSDR" || warn "CubicSDR not in repos"
track "CubicSDR"

# --- SoapySDR ---
info "Installing SoapySDR..."
apt-get install -y -qq \
    soapysdr-tools \
    soapysdr-module-rtlsdr \
    libsoapysdr-dev \
    python3-soapysdr \
    2>/dev/null && ok "SoapySDR" || warn "SoapySDR partial install"
track "SoapySDR"

# ── 4. GNU Radio Ecosystem ────────────────────────────────────────────────
banner "4/8  GNU Radio Ecosystem"

info "Installing GNU Radio & Companion..."
apt-get install -y -qq \
    gnuradio \
    gr-osmosdr \
    gr-fosphor \
    2>/dev/null && ok "GNU Radio + GRC" || {
        # Fallback: try the PPA
        warn "Trying GNU Radio PPA..."
        add-apt-repository -y ppa:gnuradio/gnuradio-releases 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq gnuradio 2>/dev/null && ok "GNU Radio (PPA)" || warn "GNU Radio install incomplete"
    }
track "GNU Radio + GRC"

# ── 5. Signal Analysis & Decoding Tools ───────────────────────────────────
banner "5/8  Signal Analysis & Decoding Tools"

# --- rtl_433 ---
info "Installing rtl_433..."
if command -v rtl_433 &>/dev/null; then
    ok "rtl_433 already installed"
else
    # Try apt first, then build from source
    apt-get install -y -qq rtl-433 2>/dev/null && ok "rtl_433 (apt)" || {
        info "Building rtl_433 from source..."
        RTL433_DIR="/opt/rtl_433-build"
        [[ -d "$RTL433_DIR" ]] && rm -rf "$RTL433_DIR"
        git clone --depth 1 https://github.com/merbanan/rtl_433.git "$RTL433_DIR"
        mkdir -p "$RTL433_DIR/build" && cd "$RTL433_DIR/build"
        cmake .. && make -j"$(nproc)" && make install
        ok "rtl_433 (built from source)"
        cd /
    }
fi
track "rtl_433"

# --- Universal Radio Hacker (URH) ---
info "Installing Universal Radio Hacker (URH)..."
run_as_user pipx install urh 2>/dev/null && ok "URH (pipx)" || {
    pip3 install urh 2>/dev/null && ok "URH (pip3)" || warn "URH install failed – try: pipx install urh"
}
track "URH (Universal Radio Hacker)"

# --- SigMF tools ---
info "Installing SigMF tools..."
pip3 install --break-system-packages sigmf 2>/dev/null && ok "SigMF" || {
    pip3 install sigmf 2>/dev/null && ok "SigMF (pip3)" || warn "SigMF install failed"
}
track "SigMF tools"

# --- inspectrum (visual signal analysis) ---
info "Installing inspectrum..."
apt-get install -y -qq inspectrum 2>/dev/null && ok "inspectrum" || warn "inspectrum not available"
track "inspectrum"

# --- multimon-ng (decoder for POCSAG, FLEX, etc.) ---
info "Installing multimon-ng..."
apt-get install -y -qq multimon-ng 2>/dev/null && ok "multimon-ng" || warn "multimon-ng not available"
track "multimon-ng"

# --- dump1090 (ADS-B aircraft tracking on 1090 MHz) ---
info "Installing dump1090..."
if command -v dump1090-mutability &>/dev/null || command -v dump1090-fa &>/dev/null || command -v dump1090 &>/dev/null; then
    ok "dump1090 already installed"
else
    apt-get install -y -qq dump1090-mutability 2>/dev/null && ok "dump1090 (apt)" || {
        info "Building dump1090 from source..."
        DUMP1090_DIR="/opt/dump1090-build"
        [[ -d "$DUMP1090_DIR" ]] && rm -rf "$DUMP1090_DIR"
        git clone --depth 1 https://github.com/flightaware/dump1090.git "$DUMP1090_DIR"
        apt-get install -y -qq libbladerf-dev libhackrf-dev liblimesuite-dev 2>/dev/null || true
        cd "$DUMP1090_DIR" && make -j"$(nproc)" && cp dump1090 /usr/local/bin/ && ok "dump1090 (built)" || warn "dump1090 build failed"
        cd /
    }
fi
track "dump1090 (ADS-B)"

# --- trunk-recorder (P25/trunked radio recorder) ---
info "Installing trunk-recorder..."
if command -v trunk-recorder &>/dev/null; then
    ok "trunk-recorder already installed"
else
    TRUNK_DIR="/opt/trunk-recorder-build"
    if [[ ! -d "$TRUNK_DIR" ]]; then
        git clone --depth 1 https://github.com/robotastic/trunk-recorder.git "$TRUNK_DIR"
    fi
    apt-get install -y -qq libboost-all-dev libcurl4-openssl-dev libssl-dev \
        libgmp-dev libsndfile1-dev 2>/dev/null || true
    mkdir -p "$TRUNK_DIR/build" && cd "$TRUNK_DIR/build"
    cmake .. && make -j"$(nproc)" && make install && ok "trunk-recorder (built)" || warn "trunk-recorder build failed – needs GNU Radio + deps"
    cd /
fi
track "trunk-recorder (P25/trunked)"

# --- gr-satellites (satellite signal decoder) ---
info "Installing gr-satellites..."
if python3 -c "import gr_satellites" 2>/dev/null; then
    ok "gr-satellites already installed"
else
    pip3 install --break-system-packages gr-satellites 2>/dev/null && ok "gr-satellites (pip3)" || {
        apt-get install -y -qq gr-satellites 2>/dev/null && ok "gr-satellites (apt)" || {
            info "Building gr-satellites from source..."
            GR_SAT_DIR="/opt/gr-satellites-build"
            [[ -d "$GR_SAT_DIR" ]] && rm -rf "$GR_SAT_DIR"
            git clone --depth 1 https://github.com/daniestevez/gr-satellites.git "$GR_SAT_DIR"
            mkdir -p "$GR_SAT_DIR/build" && cd "$GR_SAT_DIR/build"
            cmake .. && make -j"$(nproc)" && make install && ldconfig && ok "gr-satellites (built)" || warn "gr-satellites build failed"
            cd /
        }
    }
fi
track "gr-satellites"

# --- direwolf (APRS / packet radio decoder) ---
info "Installing direwolf..."
if command -v direwolf &>/dev/null; then
    ok "direwolf already installed"
else
    apt-get install -y -qq direwolf 2>/dev/null && ok "direwolf (apt)" || {
        info "Building direwolf from source..."
        DIRE_DIR="/opt/direwolf-build"
        [[ -d "$DIRE_DIR" ]] && rm -rf "$DIRE_DIR"
        git clone --depth 1 https://github.com/wb2osz/direwolf.git "$DIRE_DIR"
        apt-get install -y -qq libasound2-dev libgps-dev 2>/dev/null || true
        mkdir -p "$DIRE_DIR/build" && cd "$DIRE_DIR/build"
        cmake .. && make -j"$(nproc)" && make install && ok "direwolf (built)" || warn "direwolf build failed"
        cd /
    }
fi
track "direwolf (APRS)"

# ── 6. Meshtastic / LoRa Tools ────────────────────────────────────────────
banner "6/8  Meshtastic & LoRa Tools"

info "Installing Meshtastic CLI..."
run_as_user pipx install meshtastic 2>/dev/null && ok "Meshtastic CLI (pipx)" || {
    pip3 install --break-system-packages meshtastic 2>/dev/null && ok "Meshtastic CLI (pip3)" || warn "Meshtastic CLI failed"
}
track "Meshtastic CLI"

info "Installing LoRa support packages..."
pip3 install --break-system-packages pyLoRa 2>/dev/null && ok "pyLoRa" || {
    pip3 install pyLoRa 2>/dev/null && ok "pyLoRa (pip3)" || warn "pyLoRa not available"
}
track "LoRa tools"

# ── 7. FISSURE & KrakenSDR (optional advanced) ────────────────────────────
banner "7/8  Advanced Tools (FISSURE & KrakenSDR)"

# --- FISSURE ---
FISSURE_DIR="$ACTUAL_HOME/Tools/FISSURE"
info "Setting up FISSURE..."
if [[ -d "$FISSURE_DIR" ]]; then
    ok "FISSURE directory already exists at $FISSURE_DIR"
else
    run_as_user mkdir -p "$ACTUAL_HOME/Tools"
    run_as_user git clone --depth 1 https://github.com/ainfosec/FISSURE.git "$FISSURE_DIR" && \
        ok "FISSURE cloned to $FISSURE_DIR" || warn "FISSURE clone failed"
    info "NOTE: Run FISSURE installer separately: cd $FISSURE_DIR && ./install"
fi
track "FISSURE (cloned – run ./install separately)"

# --- KrakenSDR ---
KRAKEN_DIR="$ACTUAL_HOME/Tools/krakensdr_doa"
info "Setting up KrakenSDR DOA tools..."
if [[ -d "$KRAKEN_DIR" ]]; then
    ok "KrakenSDR directory already exists"
else
    run_as_user mkdir -p "$ACTUAL_HOME/Tools"
    run_as_user git clone --depth 1 https://github.com/krakenrf/krakensdr_doa.git "$KRAKEN_DIR" && \
        ok "KrakenSDR DOA cloned" || warn "KrakenSDR clone failed"
fi
track "KrakenSDR DOA (cloned)"

# ── 8. TX tools (opt-in) ──────────────────────────────────────────────────
if [[ "$ROLE" == "tx" ]]; then
    banner "8/8  TX-Capable Tools (HackRF, etc.)"

    info "Installing HackRF tools..."
    apt-get install -y -qq hackrf libhackrf-dev 2>/dev/null && ok "HackRF tools" || warn "HackRF tools not available"
    track "HackRF tools (TX)"

    info "Installing hackrf GNURadio blocks..."
    apt-get install -y -qq gr-hackrf 2>/dev/null || true
    track "gr-hackrf"
else
    banner "8/8  TX Tools – SKIPPED (rx-only mode)"
    info "Run with --tx to include HackRF transmit tools"
fi

# ── Post-install configuration ─────────────────────────────────────────────
banner "Post-Install Configuration"

# Ensure user is in the plugdev group for USB SDR access
info "Adding $ACTUAL_USER to plugdev group..."
usermod -aG plugdev "$ACTUAL_USER" 2>/dev/null && ok "User added to plugdev" || warn "Could not add to plugdev"

# udev rules for RTL-SDR & HackRF
info "Writing udev rules for SDR devices..."
cat > /etc/udev/rules.d/20-rtlsdr.rules <<'EOF'
# RTL-SDR
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", MODE="0666", GROUP="plugdev"
EOF

if [[ "$ROLE" == "tx" ]]; then
cat > /etc/udev/rules.d/20-hackrf.rules <<'EOF'
# HackRF One
SUBSYSTEM=="usb", ATTRS{idVendor}=="1d50", ATTRS{idProduct}=="6089", MODE="0666", GROUP="plugdev"
EOF
fi

udevadm control --reload-rules && udevadm trigger
ok "udev rules installed"

# Create working directory
WORK_DIR="$ACTUAL_HOME/SIGINT"
run_as_user mkdir -p "$WORK_DIR"/{baselines,recordings,logs,intel-packages}
ok "Working directory created at $WORK_DIR"

# Create a baseline capture helper script
cat > "$WORK_DIR/capture-baseline.sh" <<'BASELINE_SCRIPT'
#!/usr/bin/env bash
# Quick 30-minute baseline capture using rtl_433
# Usage: ./capture-baseline.sh [duration_minutes] [output_name]

DURATION=${1:-30}
OUTPUT=${2:-"baseline-$(date +%Y%m%d-%H%M)"}
OUTDIR="$HOME/SIGINT/baselines"
mkdir -p "$OUTDIR"

echo "╔══════════════════════════════════════════════════╗"
echo "║  SIGINT Baseline Capture                        ║"
echo "║  Duration: ${DURATION} minutes                          ║"
echo "║  Output:   ${OUTDIR}/${OUTPUT}.csv    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Press Ctrl+C to stop early."
echo ""

timeout "${DURATION}m" rtl_433 \
    -f 433.92M \
    -f 315M \
    -f 868M \
    -f 915M \
    -M time -M level \
    -F csv:"${OUTDIR}/${OUTPUT}.csv" \
    -F json:"${OUTDIR}/${OUTPUT}.json"

echo ""
echo "Baseline capture complete: ${OUTDIR}/${OUTPUT}.csv"
echo "Lines captured: $(wc -l < "${OUTDIR}/${OUTPUT}.csv" 2>/dev/null || echo 0)"
BASELINE_SCRIPT

chmod +x "$WORK_DIR/capture-baseline.sh"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WORK_DIR"
ok "Baseline capture script created"

# Disable WiFi and Bluetooth by default (EMCON posture)
cat > "$WORK_DIR/emcon-on.sh" <<'EMCON'
#!/usr/bin/env bash
# EMCON ON – Kill WiFi & Bluetooth to reduce RF footprint
echo "[EMCON] Blocking WiFi and Bluetooth..."
sudo rfkill block wifi
sudo rfkill block bluetooth
echo "[EMCON] Status:"
rfkill list
echo "[EMCON] WiFi and Bluetooth DISABLED. Run emcon-off.sh to restore."
EMCON

cat > "$WORK_DIR/emcon-off.sh" <<'EMCON_OFF'
#!/usr/bin/env bash
# EMCON OFF – Restore WiFi & Bluetooth
echo "[EMCON] Unblocking WiFi and Bluetooth..."
sudo rfkill unblock wifi
sudo rfkill unblock bluetooth
echo "[EMCON] Status:"
rfkill list
echo "[EMCON] WiFi and Bluetooth RESTORED."
EMCON_OFF

chmod +x "$WORK_DIR/emcon-on.sh" "$WORK_DIR/emcon-off.sh"
chown "$ACTUAL_USER:$ACTUAL_USER" "$WORK_DIR/emcon-on.sh" "$WORK_DIR/emcon-off.sh"
ok "EMCON toggle scripts created"

# ── Verification ───────────────────────────────────────────────────────────
banner "Installation Verification"

check_cmd() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        ok "$name  →  $(command -v "$cmd")"
        return 0
    else
        fail "$name  →  NOT FOUND"
        return 1
    fi
}

PASS=0; TOTAL=0

for pair in \
    "GQRX:gqrx" \
    "GNU Radio Companion:gnuradio-companion" \
    "rtl_433:rtl_433" \
    "rtl_test:rtl_test" \
    "rtl_fm:rtl_fm" \
    "rtl_power:rtl_power" \
    "SoapySDRUtil:SoapySDRUtil" \
    "CubicSDR:CubicSDR" \
    "sox:sox" \
    "inspectrum:inspectrum" \
    "multimon-ng:multimon-ng" \
    "rfkill:rfkill" \
; do
    name="${pair%%:*}"
    cmd="${pair##*:}"
    TOTAL=$((TOTAL + 1))
    check_cmd "$name" "$cmd" && PASS=$((PASS + 1))
done

# Check Python packages
info "Checking Python packages..."
for pkg in urh sigmf meshtastic; do
    TOTAL=$((TOTAL + 1))
    if python3 -c "import $pkg" 2>/dev/null || run_as_user pipx list 2>/dev/null | grep -q "$pkg"; then
        ok "Python: $pkg"
        PASS=$((PASS + 1))
    else
        fail "Python: $pkg"
    fi
done

# TX-mode checks
if [[ "$ROLE" == "tx" ]]; then
    for pair in "hackrf_transfer:hackrf_transfer" "hackrf_info:hackrf_info"; do
        name="${pair%%:*}"
        cmd="${pair##*:}"
        TOTAL=$((TOTAL + 1))
        check_cmd "$name" "$cmd" && PASS=$((PASS + 1))
    done
fi

# ── Summary ────────────────────────────────────────────────────────────────
banner "Installation Summary"

echo -e "Role:          ${BOLD}$ROLE${NC}"
echo -e "Passed:        ${GREEN}${PASS}${NC} / ${TOTAL}"
echo -e "Log:           $LOG_FILE"
echo ""
echo "Installed components:"
for item in "${INSTALLED_ITEMS[@]}"; do
    echo "  • $item"
done

echo ""
echo -e "Working directory:  ${BOLD}$WORK_DIR${NC}"
echo "  baselines/       – rtl_433 CSV/JSON baseline exports"
echo "  recordings/      – URH / GQRX signal recordings"
echo "  logs/            – Signal log templates and notes"
echo "  intel-packages/  – F3EAD intelligence deliverables"
echo ""
echo "Helper scripts:"
echo "  capture-baseline.sh  – Quick 30-min baseline (rtl_433)"
echo "  emcon-on.sh          – Kill WiFi/BT for emission control"
echo "  emcon-off.sh         – Restore WiFi/BT"
echo ""

# ── Frequency Identification Database ─────────────────────────────────────
banner "Frequency Identification Database"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FREQ_DB="$SCRIPT_DIR/data/freq_db.sqlite"

info "Building/updating frequency identification database..."
if run_as_user python3 "$SCRIPT_DIR/scripts/build_freq_db.py" --db "$FREQ_DB" 2>&1; then
    ok "Frequency DB updated at $FREQ_DB"
else
    warn "Online sources unavailable, building offline seed DB..."
    run_as_user python3 "$SCRIPT_DIR/scripts/build_freq_db.py" --db "$FREQ_DB" --offline 2>&1
    ok "Frequency DB (seed only) at $FREQ_DB"
fi
track "Frequency identification database"

if [[ $PASS -lt $TOTAL ]]; then
    warn "Some tools did not install. Check the log: $LOG_FILE"
    warn "DragonOS may already include some tools – check the application menu."
fi

echo -e "${GREEN}${BOLD}Setup complete.${NC} Reboot recommended before first use."
echo -e "After reboot: plug in RTL-SDR dongle and run ${BOLD}rtl_test${NC} to verify."
echo ""
