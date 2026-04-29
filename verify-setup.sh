#!/usr/bin/env bash
# ============================================================================
#  SIGINT Course – Post-Install Verification
# ============================================================================
#  Run this WITHOUT sudo to verify all course tools are accessible.
#  Optionally tests RTL-SDR dongle connectivity.
#
#  Usage:  ./verify-setup.sh [--dongle]
# ============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
hdr()  { echo -e "\n${BOLD}── $* ──${NC}"; }

TEST_DONGLE=false
[[ "${1:-}" == "--dongle" ]] && TEST_DONGLE=true

PASS=0; FAIL=0; WARN_COUNT=0

check_binary() {
    local label="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        ok "$label"
        PASS=$((PASS+1))
    else
        fail "$label  (command: $cmd)"
        FAIL=$((FAIL+1))
    fi
}

check_python() {
    local pkg="$1"
    if python3 -c "import $pkg" 2>/dev/null; then
        ok "Python: $pkg"
        PASS=$((PASS+1))
    elif pipx list 2>/dev/null | grep -q "$pkg"; then
        ok "Python: $pkg (pipx)"
        PASS=$((PASS+1))
    else
        fail "Python: $pkg"
        FAIL=$((FAIL+1))
    fi
}

echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  SIGINT Course – Setup Verification                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

# ── SDR receivers ──────────────────────────────────────────────────────────
hdr "SDR Receivers"
check_binary "GQRX" "gqrx"
check_binary "SDR++" "sdrpp"
check_binary "CubicSDR" "CubicSDR"

# ── GNU Radio ──────────────────────────────────────────────────────────────
hdr "GNU Radio"
check_binary "GNU Radio Companion" "gnuradio-companion"
check_python "gnuradio"

# ── RTL-SDR tools ─────────────────────────────────────────────────────────
hdr "RTL-SDR Tools"
check_binary "rtl_test" "rtl_test"
check_binary "rtl_fm" "rtl_fm"
check_binary "rtl_power" "rtl_power"

# ── Signal analysis / decoding ────────────────────────────────────────────
hdr "Signal Analysis & Decoding"
check_binary "rtl_433" "rtl_433"
check_binary "inspectrum" "inspectrum"
check_binary "multimon-ng" "multimon-ng"
check_binary "sox" "sox"
check_python "urh"
check_python "sigmf"

# ── SoapySDR ──────────────────────────────────────────────────────────────
hdr "SoapySDR"
check_binary "SoapySDRUtil" "SoapySDRUtil"
if command -v SoapySDRUtil &>/dev/null; then
    info_out=$(SoapySDRUtil --info 2>/dev/null | head -5)
    echo -e "     ${CYAN}$info_out${NC}"
fi

# ── Meshtastic / LoRa ─────────────────────────────────────────────────────
hdr "Meshtastic & LoRa"
check_python "meshtastic"

# ── FISSURE / KrakenSDR ───────────────────────────────────────────────────
hdr "Advanced Tools"
if [[ -d "$HOME/Tools/FISSURE" ]]; then
    ok "FISSURE (cloned at ~/Tools/FISSURE)"
    PASS=$((PASS+1))
else
    warn "FISSURE not found at ~/Tools/FISSURE"
    WARN_COUNT=$((WARN_COUNT+1))
fi

if [[ -d "$HOME/Tools/krakensdr_doa" ]]; then
    ok "KrakenSDR DOA (cloned at ~/Tools/krakensdr_doa)"
    PASS=$((PASS+1))
else
    warn "KrakenSDR DOA not found at ~/Tools/krakensdr_doa"
    WARN_COUNT=$((WARN_COUNT+1))
fi

# ── Instructor tools (only if present) ────────────────────────────────────
if command -v hackrf_transfer &>/dev/null; then
    hdr "Instructor TX Tools"
    check_binary "hackrf_transfer" "hackrf_transfer"
    check_binary "hackrf_info" "hackrf_info"
fi

# ── Course directory ───────────────────────────────────────────────────────
hdr "Course Directory Structure"
for dir in baselines recordings logs intel-packages; do
    if [[ -d "$HOME/SIGINT/$dir" ]]; then
        ok "~/SIGINT/$dir/"
        PASS=$((PASS+1))
    else
        fail "~/SIGINT/$dir/  – missing"
        FAIL=$((FAIL+1))
    fi
done

for script in capture-baseline.sh emcon-on.sh emcon-off.sh; do
    if [[ -x "$HOME/SIGINT/$script" ]]; then
        ok "~/SIGINT/$script (executable)"
        PASS=$((PASS+1))
    else
        fail "~/SIGINT/$script  – missing or not executable"
        FAIL=$((FAIL+1))
    fi
done

# ── USB group membership ──────────────────────────────────────────────────
hdr "USB Permissions"
if groups | grep -q plugdev; then
    ok "User is in 'plugdev' group"
    PASS=$((PASS+1))
else
    fail "User NOT in 'plugdev' group – run: sudo usermod -aG plugdev \$USER"
    FAIL=$((FAIL+1))
fi

# ── Kernel module blacklist ────────────────────────────────────────────────
hdr "Kernel Config"
if [[ -f /etc/modprobe.d/blacklist-rtlsdr.conf ]]; then
    ok "RTL-SDR DVB blacklist in place"
    PASS=$((PASS+1))
else
    warn "DVB blacklist not found – RTL-SDR may not work until blacklisted"
    WARN_COUNT=$((WARN_COUNT+1))
fi

# ── Dongle test (optional) ────────────────────────────────────────────────
if [[ "$TEST_DONGLE" == true ]]; then
    hdr "RTL-SDR Dongle Test"
    if lsusb 2>/dev/null | grep -qi "realtek\|rtl28"; then
        ok "RTL-SDR USB device detected"
        PASS=$((PASS+1))
        info "Running rtl_test for 3 seconds..."
        timeout 3 rtl_test -t 2>&1 | head -10 || true
    else
        fail "No RTL-SDR USB device found – plug in dongle and retry"
        FAIL=$((FAIL+1))
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed:${NC}   $PASS"
echo -e "  ${RED}Failed:${NC}   $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN_COUNT"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"

if [[ $FAIL -eq 0 ]]; then
    echo -e "\n  ${GREEN}${BOLD}All checks passed. Laptop is ready for class.${NC}\n"
    exit 0
else
    echo -e "\n  ${YELLOW}${BOLD}$FAIL item(s) need attention before class.${NC}\n"
    exit 1
fi
