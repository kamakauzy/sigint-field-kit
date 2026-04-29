#!/usr/bin/env bash
# ============================================================================
#  SIGINT Course – DragonOS Student Laptop Setup Script
# ============================================================================
#  Installs all required software for the 4-day SIGINT course.
#  Target OS: DragonOS Focal / FocalX (Ubuntu 20.04/22.04 base)
#
#  Usage:
#    chmod +x install-sigint-course.sh
#    sudo ./install-sigint-course.sh [OPTIONS]
#
#  Options:
#    --student       Install student tools only (default)
#    --instructor    Install student tools + instructor TX tools
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
ROLE="student"
SKIP_UPDATE=false

for arg in "$@"; do
    case "$arg" in
        --instructor)  ROLE="instructor" ;;
        --student)     ROLE="student" ;;
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

banner "SIGINT Course – DragonOS Installer"
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
pip3 install sigmf 2>/dev/null && ok "SigMF" || warn "SigMF install failed"
track "SigMF tools"

# --- inspectrum (visual signal analysis) ---
info "Installing inspectrum..."
apt-get install -y -qq inspectrum 2>/dev/null && ok "inspectrum" || warn "inspectrum not available"
track "inspectrum"

# --- multimon-ng (decoder for POCSAG, FLEX, etc.) ---
info "Installing multimon-ng..."
apt-get install -y -qq multimon-ng 2>/dev/null && ok "multimon-ng" || warn "multimon-ng not available"
track "multimon-ng"

# ── 6. Meshtastic / LoRa Tools ────────────────────────────────────────────
banner "6/8  Meshtastic & LoRa Tools"

info "Installing Meshtastic CLI..."
pip3 install meshtastic 2>/dev/null && ok "Meshtastic CLI" || warn "Meshtastic CLI failed"
track "Meshtastic CLI"

info "Installing LoRa support packages..."
pip3 install pyLoRa 2>/dev/null && ok "pyLoRa" || warn "pyLoRa not available"
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

# ── 8. Instructor-only TX tools ───────────────────────────────────────────
if [[ "$ROLE" == "instructor" ]]; then
    banner "8/8  Instructor TX Tools (HackRF, etc.)"

    info "Installing HackRF tools..."
    apt-get install -y -qq hackrf libhackrf-dev 2>/dev/null && ok "HackRF tools" || warn "HackRF tools not available"
    track "HackRF tools (TX – instructor only)"

    info "Installing hackrf GNURadio blocks..."
    apt-get install -y -qq gr-hackrf 2>/dev/null || true
    track "gr-hackrf"
else
    banner "8/8  Instructor TX Tools – SKIPPED (student mode)"
    info "Run with --instructor to include HackRF TX tools"
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

if [[ "$ROLE" == "instructor" ]]; then
cat > /etc/udev/rules.d/20-hackrf.rules <<'EOF'
# HackRF One
SUBSYSTEM=="usb", ATTRS{idVendor}=="1d50", ATTRS{idProduct}=="6089", MODE="0666", GROUP="plugdev"
EOF
fi

udevadm control --reload-rules && udevadm trigger
ok "udev rules installed"

# Create course working directory
COURSE_DIR="$ACTUAL_HOME/SIGINT"
run_as_user mkdir -p "$COURSE_DIR"/{baselines,recordings,logs,intel-packages}
ok "Course directory structure created at $COURSE_DIR"

# Create a baseline capture helper script
cat > "$COURSE_DIR/capture-baseline.sh" <<'BASELINE_SCRIPT'
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

chmod +x "$COURSE_DIR/capture-baseline.sh"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$COURSE_DIR"
ok "Baseline capture script created"

# Disable WiFi and Bluetooth by default (EMCON posture)
cat > "$COURSE_DIR/emcon-on.sh" <<'EMCON'
#!/usr/bin/env bash
# EMCON ON – Kill WiFi & Bluetooth to reduce RF footprint
echo "[EMCON] Blocking WiFi and Bluetooth..."
sudo rfkill block wifi
sudo rfkill block bluetooth
echo "[EMCON] Status:"
rfkill list
echo "[EMCON] WiFi and Bluetooth DISABLED. Run emcon-off.sh to restore."
EMCON

cat > "$COURSE_DIR/emcon-off.sh" <<'EMCON_OFF'
#!/usr/bin/env bash
# EMCON OFF – Restore WiFi & Bluetooth
echo "[EMCON] Unblocking WiFi and Bluetooth..."
sudo rfkill unblock wifi
sudo rfkill unblock bluetooth
echo "[EMCON] Status:"
rfkill list
echo "[EMCON] WiFi and Bluetooth RESTORED."
EMCON_OFF

chmod +x "$COURSE_DIR/emcon-on.sh" "$COURSE_DIR/emcon-off.sh"
chown "$ACTUAL_USER:$ACTUAL_USER" "$COURSE_DIR/emcon-on.sh" "$COURSE_DIR/emcon-off.sh"
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
    if python3 -c "import $pkg" 2>/dev/null || pipx list 2>/dev/null | grep -q "$pkg"; then
        ok "Python: $pkg"
        PASS=$((PASS + 1))
    else
        fail "Python: $pkg"
    fi
done

# Instructor-specific checks
if [[ "$ROLE" == "instructor" ]]; then
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
echo -e "Course directory:  ${BOLD}$COURSE_DIR${NC}"
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

if [[ $PASS -lt $TOTAL ]]; then
    warn "Some tools did not install. Check the log: $LOG_FILE"
    warn "DragonOS may already include some tools – check the application menu."
fi

echo -e "${GREEN}${BOLD}Setup complete.${NC} Reboot recommended before class."
echo -e "After reboot: plug in RTL-SDR dongle and run ${BOLD}rtl_test${NC} to verify."
echo ""
