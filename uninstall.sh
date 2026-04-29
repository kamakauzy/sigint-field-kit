#!/usr/bin/env bash
# ============================================================================
#  sigint-field-kit – Uninstall Script
# ============================================================================
#  Removes packages and files installed by install.sh.
#  Does NOT remove base system packages (build-essential, git, curl, etc.)
#  to avoid breaking other software.
#
#  Usage:  sudo ./uninstall.sh [--purge]
#
#  Options:
#    --purge    Also remove ~/SIGINT working directory and ~/Tools clones
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
banner(){ echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"; }

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (sudo)."
    exit 1
fi

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")

banner "sigint-field-kit – Uninstaller"
info "Purge mode: $PURGE"
echo ""

# ── SDR applications ──────────────────────────────────────────────────────
banner "Removing SDR Applications"

SDR_PACKAGES=(
    gqrx-sdr
    cubicsdr
    sdrpp
    soapysdr-tools
    soapysdr-module-rtlsdr
    libsoapysdr-dev
    python3-soapysdr
    inspectrum
    multimon-ng
)

for pkg in "${SDR_PACKAGES[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        apt-get remove -y -qq "$pkg" 2>/dev/null && ok "Removed $pkg" || warn "Could not remove $pkg"
    fi
done

# ── GNU Radio ──────────────────────────────────────────────────────────────
banner "Removing GNU Radio"

GNURADIO_PACKAGES=(
    gnuradio
    gr-osmosdr
    gr-fosphor
    gr-hackrf
)

for pkg in "${GNURADIO_PACKAGES[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        apt-get remove -y -qq "$pkg" 2>/dev/null && ok "Removed $pkg" || warn "Could not remove $pkg"
    fi
done

# ── HackRF ─────────────────────────────────────────────────────────────────
if dpkg -l hackrf &>/dev/null 2>&1; then
    info "Removing HackRF tools..."
    apt-get remove -y -qq hackrf libhackrf-dev 2>/dev/null && ok "Removed HackRF" || true
    rm -f /etc/udev/rules.d/20-hackrf.rules
fi

# ── Python packages ────────────────────────────────────────────────────────
banner "Removing Python Packages"

for pkg in urh sigmf meshtastic pyLoRa; do
    if sudo -u "$ACTUAL_USER" pipx list 2>/dev/null | grep -q "$pkg"; then
        sudo -u "$ACTUAL_USER" pipx uninstall "$pkg" 2>/dev/null && ok "Removed $pkg (pipx)" || true
    elif pip3 show "$pkg" &>/dev/null; then
        pip3 uninstall -y "$pkg" 2>/dev/null && ok "Removed $pkg (pip3)" || true
    fi
done

# ── RTL-SDR (keep drivers but remove blacklist if desired) ────────────────
banner "Cleaning RTL-SDR Config"

info "Removing udev rules..."
rm -f /etc/udev/rules.d/20-rtlsdr.rules
ok "Removed RTL-SDR udev rules"

info "Removing DVB kernel blacklist..."
rm -f /etc/modprobe.d/blacklist-rtlsdr.conf
ok "Removed DVB blacklist (RTL-SDR dongles will use DVB driver again after reboot)"

udevadm control --reload-rules && udevadm trigger

# ── Built-from-source tools ────────────────────────────────────────────────
banner "Removing Source Builds"

if [[ -d /opt/rtl_433-build ]]; then
    info "Removing rtl_433 build..."
    cd /opt/rtl_433-build/build 2>/dev/null && make uninstall 2>/dev/null || true
    rm -rf /opt/rtl_433-build
    ok "Removed rtl_433"
fi

if [[ -d /opt/sdrpp-build ]]; then
    info "Removing SDR++ build..."
    rm -rf /opt/sdrpp-build
    ok "Removed SDR++ build directory"
fi

# ── Purge working directories ─────────────────────────────────────────────
if [[ "$PURGE" == true ]]; then
    banner "Purging Working Directories"

    if [[ -d "$ACTUAL_HOME/SIGINT" ]]; then
        warn "Removing $ACTUAL_HOME/SIGINT/ (all baselines, recordings, logs)..."
        rm -rf "$ACTUAL_HOME/SIGINT"
        ok "Removed ~/SIGINT"
    fi

    if [[ -d "$ACTUAL_HOME/Tools/FISSURE" ]]; then
        rm -rf "$ACTUAL_HOME/Tools/FISSURE"
        ok "Removed ~/Tools/FISSURE"
    fi

    if [[ -d "$ACTUAL_HOME/Tools/krakensdr_doa" ]]; then
        rm -rf "$ACTUAL_HOME/Tools/krakensdr_doa"
        ok "Removed ~/Tools/krakensdr_doa"
    fi
else
    info "Skipping ~/SIGINT and ~/Tools removal (use --purge to include)"
fi

# ── Cleanup ────────────────────────────────────────────────────────────────
banner "Final Cleanup"

apt-get autoremove -y -qq 2>/dev/null
ok "Removed orphaned packages"

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC} Reboot recommended."
if [[ "$PURGE" == false ]]; then
    echo -e "Your data in ${BOLD}~/SIGINT/${NC} was preserved. Run with ${BOLD}--purge${NC} to remove it."
fi
echo ""
