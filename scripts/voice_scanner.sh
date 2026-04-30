#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# SIGINT Voice Scanner — Scanning recorder with voice-band energy gating
#
# Cycles through target voice frequencies. Records demodulated FM audio
# on each dwell, then applies bandpass filter (300-3000 Hz) and energy
# detection to keep ONLY segments with actual human voice — rejecting
# idle carriers, CTCSS tones, and noise.
#
# Usage:  ./voice_scanner.sh [duration_hours]
# Default: 8 hours
#
# Requirements: rtl_fm, sox, bc, RTL-SDR dongle
#══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────
DURATION_HOURS="${1:-8}"
DWELL_SEC=6              # Time to listen on each freq
SAMPLE_RATE=24000        # Audio sample rate
GAIN=38                  # RTL-SDR gain (dB)
OUTPUT_DIR="/var/lib/recon-raven/recordings"
LOG_FILE="/var/lib/recon-raven/logs/voice_scanner_$(date +%Y%m%d-%H%M%S).log"
PID_FILE="/tmp/voice_scanner.pid"

# Voice detection: bandpass 300-3000 Hz then amplitude gate
# Idle carrier + CTCSS has ~8% energy in voice band
# Human voice has 20%+ energy in voice band
VOICE_THRESHOLD="10%"    # Above idle carrier after bandpass
MIN_VOICE_SEC="0.4"      # Minimum voice duration to keep

# ── Target Frequencies ───────────────────────────────────────────────────
# Format: FREQ_HZ:MODE:LABEL
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
    pkill -P $$ rtl_fm 2>/dev/null || true
    rm -f "$PID_FILE" /tmp/scanner_*.raw /tmp/scanner_*.wav /tmp/scanner_*_vbf.wav
    local count=$(find "$OUTPUT_DIR" -name '*.wav' -newer "$LOG_FILE" 2>/dev/null | wc -l)
    log "Scanner stopped. Voice recordings this session: $count"
    exit 0
}
trap cleanup EXIT INT TERM

log "═══════════════════════════════════════════════════════════════"
log "VOICE SCANNER STARTING"
log "Duration: ${DURATION_HOURS}h | Dwell: ${DWELL_SEC}s"
log "Voice gate: bandpass 300-3000Hz → ${VOICE_THRESHOLD} threshold"
log "Min voice: ${MIN_VOICE_SEC}s | Channels: ${#CHANNELS[@]}"
log "Output: $OUTPUT_DIR"
log "End time: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')"
log "═══════════════════════════════════════════════════════════════"

# ── Main Scan Loop ───────────────────────────────────────────────────────
cycle=0
captures=0
scans=0
while [ $(date +%s) -lt $END_TIME ]; do
    cycle=$((cycle + 1))

    for entry in "${CHANNELS[@]}"; do
        [ $(date +%s) -ge $END_TIME ] && break

        IFS=':' read -r freq mode label <<< "$entry"
        scans=$((scans + 1))

        ts=$(date +%Y%m%d-%H%M%S)
        raw_file="/tmp/scanner_${label}_${ts}.raw"
        tmp_wav="/tmp/scanner_${label}_${ts}.wav"
        vbf_wav="/tmp/scanner_${label}_${ts}_vbf.wav"
        final_wav="${OUTPUT_DIR}/${label}_${ts}.wav"

        # Record for DWELL_SEC (no RF squelch)
        timeout "${DWELL_SEC}" rtl_fm \
            -f "$freq" \
            -M "$mode" \
            -s "$SAMPLE_RATE" \
            -g "$GAIN" \
            -p 0 \
            "$raw_file" 2>/dev/null || true

        # Skip empty
        [ ! -f "$raw_file" ] && continue
        [ $(stat -c%s "$raw_file" 2>/dev/null || echo 0) -lt 4800 ] && { rm -f "$raw_file"; continue; }

        # Convert to WAV
        sox -t raw -r "$SAMPLE_RATE" -e signed -b 16 -c 1 "$raw_file" "$tmp_wav" 2>/dev/null || { rm -f "$raw_file"; continue; }
        rm -f "$raw_file"

        # Bandpass filter: keep only 300-3000 Hz (voice band)
        # This removes CTCSS (67-254 Hz) and high-freq noise
        sox "$tmp_wav" "$vbf_wav" sinc 300-3000 2>/dev/null || { rm -f "$tmp_wav"; continue; }

        # Voice gate: strip silence from filtered audio
        sox "$vbf_wav" "$final_wav" \
            silence 1 0.1 "$VOICE_THRESHOLD" \
            reverse silence 1 0.1 "$VOICE_THRESHOLD" reverse \
            2>/dev/null || { rm -f "$tmp_wav" "$vbf_wav"; continue; }

        rm -f "$tmp_wav" "$vbf_wav"

        # Check duration — must have MIN_VOICE_SEC of actual voice
        if [ -f "$final_wav" ] && [ $(stat -c%s "$final_wav" 2>/dev/null || echo 0) -gt 44 ]; then
            duration=$(sox "$final_wav" -n stat 2>&1 | grep "Length" | awk '{print $NF}')
            if [ -n "$duration" ] && [ "$(echo "$duration >= $MIN_VOICE_SEC" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
                captures=$((captures + 1))
                freq_mhz=$(echo "scale=3; $freq/1000000" | bc)
                log "VOICE: ${label} @ ${freq_mhz} MHz | ${duration}s | $final_wav"
            else
                rm -f "$final_wav"
            fi
        else
            rm -f "$final_wav"
        fi
    done

    # Progress every 10 cycles (~10 min)
    if [ $((cycle % 10)) -eq 0 ]; then
        elapsed=$(( $(date +%s) - (END_TIME - DURATION_HOURS * 3600) ))
        log "Cycle $cycle | ${elapsed}s elapsed | Scans: $scans | Voice: $captures"
    fi
done

log "Complete. Cycles: $cycle | Scans: $scans | Voice captures: $captures"
