#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# Squelch-Triggered Recorder — Parks on active frequencies and records
# whenever transmissions are detected.
#
# Unlike the adaptive collector (sweep → target), this script DWELLS on
# known-active frequencies and captures whatever comes through. Much more
# effective for bursty PTT radio.
#
# Usage:
#   ./squelch_recorder.sh                    # Default freqs, 8h
#   ./squelch_recorder.sh 4                  # Run for 4 hours
#   ./squelch_recorder.sh 8 463.000,145.500  # Custom freq list (MHz)
#
# Requirements: rtl_fm, sox, RTL-SDR
#══════════════════════════════════════════════════════════════════════════

set -euo pipefail

DURATION_HOURS="${1:-8}"
FREQ_LIST="${2:-462.5625,462.5875,462.6125,462.6375,462.6625,462.6875,462.7125,151.820,151.880,151.940,154.570,154.600,156.800,145.500,153.643}"

# Tuning
GAIN=38
DEVICE=0
SAMPLE_RATE=24000
SQUELCH_LEVEL=0           # rtl_fm squelch OFF (signals too weak for HW squelch)
DWELL_SEC="${DWELL:-30}"  # Seconds to park on each frequency (env override: DWELL=N)
MIN_AUDIO_SEC="0.5"       # Minimum recording length to keep (seconds)
SILENCE_THRESH="1%"       # Sox silence detection threshold (low = more sensitive)
SILENCE_DUR="1.5"         # Seconds of silence before split/trim
NOISE_RMS="0.015"         # Minimum RMS to consider a segment "real audio"
MIN_VARIANCE="0.003"      # Minimum RMS stddev across 1s windows (voice vs carrier)

BASE_DIR="/var/lib/recon-raven"
RECORDINGS_DIR="$BASE_DIR/recordings"
LOG_FILE="$BASE_DIR/logs/squelch_$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$RECORDINGS_DIR" "$(dirname "$LOG_FILE")"

END_TIME=$(( $(date +%s) + DURATION_HOURS * 3600 ))

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Squelch recorder stopping"
    pkill -P $$ rtl_fm 2>/dev/null || true
    rm -f /tmp/sqrec_*.raw /tmp/sqrec_*.wav /tmp/sqrec_split_*
    local count=$(find "$RECORDINGS_DIR" -name 'sqrec_*.wav' -newer "$LOG_FILE" 2>/dev/null | wc -l)
    log "Session total: $count recordings saved"
    exit 0
}
trap cleanup EXIT INT TERM

# Parse freq list into array
IFS=',' read -ra FREQS <<< "$FREQ_LIST"

# Determine modulation per frequency
get_modulation() {
    local freq_mhz="$1"
    # NOAA satellites (137 MHz) use wide FM APT
    if (( $(echo "$freq_mhz >= 136.0 && $freq_mhz <= 138.0" | bc -l) )); then
        echo "fm"
    else
        # Everything else in VHF/UHF land comms: narrowband FM
        echo "fm"
    fi
}

# ─── Record one dwell session on a single frequency ──────────────────────
record_dwell() {
    local freq_mhz="$1"
    local freq_hz=$(echo "$freq_mhz * 1000000" | bc | cut -d. -f1)
    local ts=$(date +%Y%m%d-%H%M%S)
    local raw_file="/tmp/sqrec_${freq_mhz}_${ts}.raw"
    local wav_file="/tmp/sqrec_${freq_mhz}_${ts}.wav"
    local vbf_file="/tmp/sqrec_${freq_mhz}_${ts}_vbf.wav"
    local mod=$(get_modulation "$freq_mhz")

    # Record full dwell — NO squelch (signals too weak for HW squelch).
    # We'll detect voice in post-processing instead.
    timeout "$DWELL_SEC" rtl_fm \
        -f "${freq_hz}" \
        -M "$mod" \
        -s "$SAMPLE_RATE" \
        -g "$GAIN" \
        -l "$SQUELCH_LEVEL" \
        -p 0 \
        -d "$DEVICE" \
        "$raw_file" 2>/dev/null || true

    # Check if we got anything
    if [ ! -f "$raw_file" ]; then
        return 0
    fi
    local raw_size=$(stat -c%s "$raw_file" 2>/dev/null || echo 0)
    if [ "$raw_size" -lt 4800 ]; then
        rm -f "$raw_file"
        return 0
    fi

    # Convert raw to wav
    sox -t raw -r "$SAMPLE_RATE" -e signed -b 16 -c 1 "$raw_file" "$wav_file" 2>/dev/null
    rm -f "$raw_file"

    if [ ! -f "$wav_file" ]; then
        return 0
    fi

    # Bandpass voice frequencies FIRST (300-3400 Hz) to remove out-of-band noise
    sox "$wav_file" "$vbf_file" sinc 300-3400 2>/dev/null || { rm -f "$wav_file"; return 0; }
    rm -f "$wav_file"

    # Check overall RMS of bandpassed audio — if below noise floor, skip entirely
    local rms=$(sox "$vbf_file" -n stat 2>&1 | grep "RMS.*amplitude" | awk '{print $NF}')
    local above_noise=$(echo "${rms:-0} > $NOISE_RMS" | bc -l 2>/dev/null || echo "0")
    if [ "$above_noise" != "1" ]; then
        log "  - ${freq_mhz} MHz: RMS=${rms:-0} (below noise floor, skipping)"
        rm -f "$vbf_file"
        return 0
    fi

    # VARIANCE CHECK: Measure RMS in 1-second windows. Constant carriers have
    # flat RMS (low stddev). Actual voice has peaks and valleys (high stddev).
    local variance_info
    variance_info=$(python3 -c "
import struct, wave, math

with wave.open('$vbf_file', 'rb') as wf:
    rate = wf.getframerate()
    frames = wf.readframes(wf.getnframes())
    samples = struct.unpack('<' + 'h' * (len(frames) // 2), frames)

# RMS per 1-second window
window = rate
rms_vals = []
for i in range(0, len(samples) - window, window):
    chunk = samples[i:i+window]
    ms = sum(s*s for s in chunk) / len(chunk)
    rms_vals.append(math.sqrt(ms) / 32768.0)

if len(rms_vals) < 3:
    print('SKIP 0 0')
else:
    mean_rms = sum(rms_vals) / len(rms_vals)
    variance = math.sqrt(sum((r - mean_rms)**2 for r in rms_vals) / len(rms_vals))
    peak = max(rms_vals)
    trough = min(rms_vals)
    print(f'{variance:.6f} {peak:.6f} {trough:.6f}')
" 2>/dev/null || echo "SKIP 0 0")

    local var_val=$(echo "$variance_info" | awk '{print $1}')
    
    if [ "$var_val" = "SKIP" ]; then
        log "  - ${freq_mhz} MHz: too short for variance check, skipping"
        rm -f "$vbf_file"
        return 0
    fi

    local has_voice=$(echo "$var_val > $MIN_VARIANCE" | bc -l 2>/dev/null || echo "0")
    if [ "$has_voice" != "1" ]; then
        log "  - ${freq_mhz} MHz: RMS=${rms} var=${var_val} (flat carrier, skipping)"
        rm -f "$vbf_file"
        return 0
    fi

    log "  + ${freq_mhz} MHz: RMS=${rms} var=${var_val} (voice detected!)"

    # Split on silence: creates individual transmission segments
    # Output files: /tmp/sqrec_split_NNN.wav
    rm -f /tmp/sqrec_split_*.wav
    sox "$vbf_file" /tmp/sqrec_split_.wav \
        silence 1 0.1 "$SILENCE_THRESH" 1 "$SILENCE_DUR" "$SILENCE_THRESH" \
        : newfile : restart 2>/dev/null || true
    rm -f "$vbf_file"

    # Process each split segment
    local saved=0
    for segment in /tmp/sqrec_split_*.wav; do
        [ -f "$segment" ] || continue

        # Check duration
        local dur=$(soxi -D "$segment" 2>/dev/null || echo "0")
        local long_enough=$(echo "$dur >= $MIN_AUDIO_SEC" | bc -l 2>/dev/null || echo "0")

        if [ "$long_enough" = "1" ]; then
            # Check segment RMS too (reject quiet filler segments)
            local seg_rms=$(sox "$segment" -n stat 2>&1 | grep "RMS.*amplitude" | awk '{print $NF}')
            local seg_ok=$(echo "${seg_rms:-0} > $NOISE_RMS" | bc -l 2>/dev/null || echo "0")
            
            if [ "$seg_ok" = "1" ]; then
                local final_name="sqrec_${freq_mhz}MHz_${ts}_$(printf '%02d' $saved).wav"
                local final_path="${RECORDINGS_DIR}/${final_name}"

                # Normalize and save
                sox "$segment" "$final_path" norm -1 2>/dev/null || { rm -f "$segment"; continue; }

                local final_dur=$(soxi -D "$final_path" 2>/dev/null || echo "0")
                log "  ✓ SAVED: ${final_name} | ${final_dur}s | RMS=${seg_rms}"
                saved=$((saved + 1))
            fi
        fi
        rm -f "$segment"
    done

    # Store count in global for caller
    LAST_SAVED=$saved
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════

log "═══════════════════════════════════════════════════════════════"
log "SQUELCH-TRIGGERED RECORDER"
log "Duration: ${DURATION_HOURS}h | Dwell: ${DWELL_SEC}s/freq"
log "Frequencies: ${FREQ_LIST}"
log "Squelch: ${SQUELCH_LEVEL} | Min audio: ${MIN_AUDIO_SEC}s"
log "End time: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')"
log "═══════════════════════════════════════════════════════════════"

cycle=0
total_saved=0

while [ $(date +%s) -lt $END_TIME ]; do
    cycle=$((cycle + 1))

    for freq_mhz in "${FREQS[@]}"; do
        [ $(date +%s) -ge $END_TIME ] && break

        log "Cycle $cycle | Monitoring ${freq_mhz} MHz for ${DWELL_SEC}s..."
        LAST_SAVED=0
        record_dwell "$freq_mhz"
        if [ $LAST_SAVED -gt 0 ]; then
            total_saved=$((total_saved + LAST_SAVED))
        fi
    done

    log "Cycle $cycle complete | Total saved: $total_saved"
done

log "═══════════════════════════════════════════════════════════════"
log "FINISHED — $total_saved recordings captured over $cycle cycles"
log "═══════════════════════════════════════════════════════════════"
