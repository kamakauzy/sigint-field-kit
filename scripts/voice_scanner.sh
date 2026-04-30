#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# SIGINT Voice Scanner — Scanning recorder for multiple voice channels
#
# Cycles through known active voice frequencies, dwells on each with
# squelch. When signal breaks squelch, records audio to WAV file.
# Each recording is timestamped with frequency in filename.
#
# This is the "poor man's scanner" — one RTL-SDR cycling through freqs.
# Gaps occur when transmissions happen on non-current freq. Overnight
# low-traffic periods minimize missed captures.
#
# Usage:
#   ./voice_scanner.sh          # 8 hours (default)
#   ./voice_scanner.sh 12       # 12 hours
#
# Requirements: rtl_fm, sox, RTL-SDR dongle
# Cycle time: ~40 seconds per full rotation (10 channels × 4s dwell)
#
# Edit CHANNELS array below to target your local frequencies.
#══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────
DURATION_HOURS="${1:-8}"
DWELL_SEC=4              # Time to listen on each freq before rotating
SQUELCH_LEVEL=20         # rtl_fm squelch (0-100+, higher = tighter)
SAMPLE_RATE=24000        # Audio sample rate (24k for NFM voice)
GAIN=38                  # RTL-SDR gain (dB)
OUTPUT_DIR="/var/lib/recon-raven/recordings"
LOG_FILE="/var/lib/recon-raven/logs/voice_scanner_$(date +%Y%m%d-%H%M%S).log"
PID_FILE="/tmp/voice_scanner.pid"

# ── Target Frequencies (from SIGINT collection report) ───────────────────
# Format: FREQ_HZ:MODE:LABEL
# Modes: fm = NFM voice, wfm = WFM, am = AM
CHANNELS=(
    "153640000:fm:VHF_Business"
    "159070000:fm:VHF_PublicSafety"
    "145500000:fm:2m_Ham_Repeater"
    "443400000:fm:70cm_Ham_Voice"
    "446200000:fm:FRS_Ch1"
    "454600000:fm:UHF_Business1"
    "463000000:fm:GMRS_Repeater"
    "465800000:fm:UHF_Business2"
    "468600000:fm:GMRS_Business"
    "857480000:fm:P25_Voice"
)

# ── Setup ────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR" "$(dirname "$LOG_FILE")"
echo $$ > "$PID_FILE"

END_TIME=$(( $(date +%s) + DURATION_HOURS * 3600 ))

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Shutting down voice scanner (PID $$)"
    # Kill any child rtl_fm
    pkill -P $$ rtl_fm 2>/dev/null || true
    rm -f "$PID_FILE"
    log "Scanner stopped. Recordings in: $OUTPUT_DIR"
    log "Total recordings: $(find "$OUTPUT_DIR" -name '*.wav' -newer "$LOG_FILE" | wc -l)"
    exit 0
}
trap cleanup EXIT INT TERM

log "═══════════════════════════════════════════════════════════════"
log "VOICE SCANNER STARTING"
log "Duration: ${DURATION_HOURS}h | Dwell: ${DWELL_SEC}s | Squelch: ${SQUELCH_LEVEL}"
log "Channels: ${#CHANNELS[@]} | Output: $OUTPUT_DIR"
log "End time: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')"
log "═══════════════════════════════════════════════════════════════"

# ── Main Scan Loop ───────────────────────────────────────────────────────
cycle=0
while [ $(date +%s) -lt $END_TIME ]; do
    cycle=$((cycle + 1))

    for entry in "${CHANNELS[@]}"; do
        # Check time
        [ $(date +%s) -ge $END_TIME ] && break

        IFS=':' read -r freq mode label <<< "$entry"

        # Generate output filename
        ts=$(date +%Y%m%d-%H%M%S)
        raw_file="/tmp/scanner_${label}_${ts}.raw"
        wav_file="${OUTPUT_DIR}/${label}_${ts}.wav"

        # Run rtl_fm with squelch for DWELL_SEC seconds
        # -l = squelch level; audio only output when signal present
        timeout "${DWELL_SEC}" rtl_fm \
            -f "$freq" \
            -M "$mode" \
            -s "$SAMPLE_RATE" \
            -g "$GAIN" \
            -l "$SQUELCH_LEVEL" \
            -p 0 \
            "$raw_file" 2>/dev/null || true

        # Check if we got audio (file exists and > 1KB = signal was present)
        if [ -f "$raw_file" ] && [ $(stat -c%s "$raw_file" 2>/dev/null || echo 0) -gt 1024 ]; then
            # Convert raw PCM to WAV
            sox -t raw -r "$SAMPLE_RATE" -e signed -b 16 -c 1 "$raw_file" "$wav_file" 2>/dev/null

            size=$(stat -c%s "$wav_file" 2>/dev/null || echo 0)
            dur_sec=$(( size / (SAMPLE_RATE * 2) ))  # 16-bit mono
            log "CAPTURE: ${label} @ $(echo "scale=3; $freq/1000000" | bc) MHz | ${dur_sec}s | $wav_file"
        fi

        # Clean up raw
        rm -f "$raw_file"
    done

    # Log cycle progress every 10 cycles
    if [ $((cycle % 10)) -eq 0 ]; then
        elapsed=$(( $(date +%s) - (END_TIME - DURATION_HOURS * 3600) ))
        recordings=$(find "$OUTPUT_DIR" -name '*.wav' -newer "$LOG_FILE" | wc -l)
        log "Cycle $cycle | Elapsed: ${elapsed}s | Recordings: $recordings"
    fi
done

log "Duration complete. Final cycle: $cycle"
