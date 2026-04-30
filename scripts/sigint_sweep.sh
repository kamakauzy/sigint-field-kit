#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# SIGINT Spectrum Sweep — Multi-band power survey via rtl_power
#
# Cycles through 3 priority SIGINT bands (VHF, UHF, 800 MHz) collecting
# power-level CSV data. Designed for unattended overnight/extended
# collection to build pattern-of-life and identify active frequencies.
#
# Output: CSV files compatible with heatmap.py, baseline_diff.py, and
#         intel_packager.py for downstream analysis.
#
# Usage:
#   ./sigint_sweep.sh              # 8 hours, default output dir
#   ./sigint_sweep.sh 12           # 12 hours
#   ./sigint_sweep.sh 4 /tmp/out   # 4 hours, custom output dir
#
# Requirements: rtl_power (from rtl-sdr package), RTL-SDR dongle
# Cycle time: ~33 seconds per full rotation (all 3 bands)
#══════════════════════════════════════════════════════════════════════════

set -euo pipefail

HOURS=${1:-8}
OUTDIR=${2:-/var/lib/recon-raven/logs}
GAIN=38
DEVICE=0
END_TIME=$(($(date +%s) + HOURS * 3600))
STAMP=$(date +%Y%m%d-%H%M%S)

VHF_FILE="$OUTDIR/sigint_vhf_136-174MHz_${STAMP}.csv"
UHF_FILE="$OUTDIR/sigint_uhf_400-470MHz_${STAMP}.csv"
P25_FILE="$OUTDIR/sigint_p25_806-870MHz_${STAMP}.csv"
TMP="/tmp/rtl_sweep_tmp.csv"

mkdir -p "$OUTDIR"

echo "[$(date)] SIGINT sweep starting — ${HOURS}h"
echo "  VHF: $VHF_FILE"
echo "  UHF: $UHF_FILE"
echo "  P25: $P25_FILE"

touch "$VHF_FILE" "$UHF_FILE" "$P25_FILE"
CYCLE=0

while [ $(date +%s) -lt $END_TIME ]; do
    CYCLE=$((CYCLE + 1))

    # VHF (136-174) — Baofengs, MURS, marine, public safety, ham 2m
    rtl_power -f 136M:174M:25k -i 10 -1 -g $GAIN -d $DEVICE -p 0 "$TMP" 2>/dev/null
    cat "$TMP" >> "$VHF_FILE"

    # UHF (400-470) — Baofengs, business, GMRS/FRS, ISM 433
    rtl_power -f 400M:470M:50k -i 10 -1 -g $GAIN -d $DEVICE -p 0 "$TMP" 2>/dev/null
    cat "$TMP" >> "$UHF_FILE"

    # P25/800 (806-870) — trunked public safety, security
    rtl_power -f 806M:870M:50k -i 10 -1 -g $GAIN -d $DEVICE -p 0 "$TMP" 2>/dev/null
    cat "$TMP" >> "$P25_FILE"

    if [ $((CYCLE % 10)) -eq 0 ]; then
        echo "[$(date)] Cycle $CYCLE | VHF=$(wc -l < "$VHF_FILE") UHF=$(wc -l < "$UHF_FILE") P25=$(wc -l < "$P25_FILE")"
    fi
done

rm -f "$TMP"
echo "[$(date)] SIGINT sweep complete — $CYCLE cycles"
echo "VHF: $(wc -l < "$VHF_FILE") lines"
echo "UHF: $(wc -l < "$UHF_FILE") lines"
echo "P25: $(wc -l < "$P25_FILE") lines"
