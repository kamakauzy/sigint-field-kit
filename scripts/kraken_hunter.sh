#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# KrakenSDR Fox Hunt — Bearing-guided signal recording
#
# Combines KrakenSDR DOA with RTL-SDR voice recording. For each target
# frequency: gets a bearing from the KrakenSDR, then records audio with
# the RTL-SDR. Logs bearing + recording together so you know WHERE a
# signal came from and WHAT was said.
#
# Architecture:
#   KrakenSDR (Pi) → DOA bearings → this script → RTL-SDR (potato) → audio
#
# Usage:
#   ./kraken_hunter.sh                              # defaults from config
#   ./kraken_hunter.sh 462.7125,154.570             # specific frequencies
#   ./kraken_hunter.sh 462.7125 --duration 3600     # 1 hour on single freq
#
# Requirements:
#   - KrakenSDR Pi running with forwarder on port 8081
#   - RTL-SDR connected to potato for recording
#   - sox, rtl_fm, python3, bc
#══════════════════════════════════════════════════════════════════════════

set -euo pipefail

FREQ_LIST="${1:-462.7125,154.570,154.600,146.940}"
DURATION_HOURS="${2:-8}"

# KrakenSDR Pi
KRAKEN_HOST="192.168.1.120"
KRAKEN_PORT=8081

# RTL-SDR recording
GAIN=38
DEVICE=0
SAMPLE_RATE=24000
DWELL_SEC=30
VARIANCE_THRESHOLD="0.003"
NOISE_RMS="0.015"

BASE_DIR="/var/lib/recon-raven"
RECORDINGS_DIR="$BASE_DIR/recordings/hunts"
LOG_FILE="$BASE_DIR/logs/hunt_$(date +%Y%m%d-%H%M%S).log"
HUNT_LOG="$BASE_DIR/logs/hunt_bearings_$(date +%Y%m%d-%H%M%S).csv"

mkdir -p "$RECORDINGS_DIR" "$(dirname "$LOG_FILE")"

END_TIME=$(( $(date +%s) + DURATION_HOURS * 3600 ))

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Fox hunt stopping"
    pkill -P $$ rtl_fm 2>/dev/null || true
    rm -f /tmp/hunt_*.raw /tmp/hunt_*.wav
    local count=$(find "$RECORDINGS_DIR" -name 'hunt_*.wav' -newer "$LOG_FILE" 2>/dev/null | wc -l)
    log "Session total: $count recordings with bearings"
    exit 0
}
trap cleanup EXIT INT TERM

IFS=',' read -ra FREQS <<< "$FREQ_LIST"

# Initialize hunt bearing log
echo "timestamp_utc,freq_mhz,bearing_deg,confidence,has_voice,recording_file" > "$HUNT_LOG"

# ─── Get bearing from KrakenSDR ──────────────────────────────────────────
get_bearing() {
    local freq_mhz="$1"
    # Query the forwarder API
    local result
    result=$(python3 -c "
import urllib.request, json, sys
try:
    with urllib.request.urlopen('http://$KRAKEN_HOST:$KRAKEN_PORT/doa', timeout=3) as r:
        data = json.loads(r.read())
        bearings = data.get('bearings', [])
        # Find bearing closest to our frequency
        best = None
        best_diff = 999
        for b in bearings:
            diff = abs(float(b.get('freq_mhz', 0)) - $freq_mhz)
            if diff < best_diff:
                best_diff = diff
                best = b
        if best and best_diff < 1.0:
            print(f\"{best.get('bearing_deg', -1)}:{best.get('confidence', 0)}\")
        else:
            print('-1:0')
except:
    print('-1:0')
" 2>/dev/null || echo "-1:0")

    echo "$result"
}

# ─── Record + analyze one frequency ──────────────────────────────────────
hunt_freq() {
    local freq_mhz="$1"
    local freq_hz=$(echo "$freq_mhz * 1000000" | bc | cut -d. -f1)
    local ts=$(date +%Y%m%d-%H%M%S)
    local ts_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local raw_file="/tmp/hunt_${freq_mhz}_${ts}.raw"
    local wav_file="/tmp/hunt_${freq_mhz}_${ts}.wav"
    local vbf_file="/tmp/hunt_${freq_mhz}_${ts}_vbf.wav"

    # Step 1: Get bearing from KrakenSDR
    local bearing_data
    bearing_data=$(get_bearing "$freq_mhz")
    local bearing_deg=$(echo "$bearing_data" | cut -d: -f1)
    local confidence=$(echo "$bearing_data" | cut -d: -f2)

    local bearing_str="NO_BEARING"
    if [ "$bearing_deg" != "-1" ]; then
        bearing_str="${bearing_deg}°"
    fi

    # Step 2: Record with RTL-SDR
    timeout "$DWELL_SEC" rtl_fm \
        -f "$freq_hz" -M fm -s "$SAMPLE_RATE" -g "$GAIN" \
        -l 0 -p 0 -d "$DEVICE" \
        "$raw_file" 2>/dev/null || true

    if [ ! -f "$raw_file" ] || [ $(stat -c%s "$raw_file" 2>/dev/null || echo 0) -lt 4800 ]; then
        log "  - ${freq_mhz} MHz [${bearing_str}]: no audio"
        echo "$ts_utc,$freq_mhz,$bearing_deg,$confidence,false," >> "$HUNT_LOG"
        rm -f "$raw_file"
        return
    fi

    # Step 3: Bandpass + variance check (lessons learned: catches voice, rejects carriers)
    sox -t raw -r "$SAMPLE_RATE" -e signed -b 16 -c 1 "$raw_file" "$wav_file" 2>/dev/null
    rm -f "$raw_file"
    sox "$wav_file" "$vbf_file" sinc 300-3400 2>/dev/null || { rm -f "$wav_file"; return; }
    rm -f "$wav_file"

    local rms=$(sox "$vbf_file" -n stat 2>&1 | grep "RMS.*amplitude" | awk '{print $NF}')
    local above_noise=$(echo "${rms:-0} > $NOISE_RMS" | bc -l 2>/dev/null || echo "0")

    if [ "$above_noise" != "1" ]; then
        log "  - ${freq_mhz} MHz [${bearing_str}]: RMS=${rms:-0} (below noise)"
        echo "$ts_utc,$freq_mhz,$bearing_deg,$confidence,false," >> "$HUNT_LOG"
        rm -f "$vbf_file"
        return
    fi

    # Variance check
    local var_val
    var_val=$(python3 -c "
import struct, wave, math
with wave.open('$vbf_file', 'rb') as wf:
    rate = wf.getframerate()
    frames = wf.readframes(wf.getnframes())
    samples = struct.unpack('<' + 'h' * (len(frames) // 2), frames)
window = rate
rms_vals = []
for i in range(0, len(samples) - window, window):
    chunk = samples[i:i+window]
    ms = sum(s*s for s in chunk) / len(chunk)
    rms_vals.append(math.sqrt(ms) / 32768.0)
if len(rms_vals) < 3:
    print('0')
else:
    mean_rms = sum(rms_vals) / len(rms_vals)
    print(f'{math.sqrt(sum((r - mean_rms)**2 for r in rms_vals) / len(rms_vals)):.6f}')
" 2>/dev/null || echo "0")

    local has_voice=$(echo "$var_val > $VARIANCE_THRESHOLD" | bc -l 2>/dev/null || echo "0")

    if [ "$has_voice" != "1" ]; then
        log "  - ${freq_mhz} MHz [${bearing_str}]: var=${var_val} (flat carrier)"
        echo "$ts_utc,$freq_mhz,$bearing_deg,$confidence,false," >> "$HUNT_LOG"
        rm -f "$vbf_file"
        return
    fi

    # Step 4: Voice detected! Save with bearing metadata in filename
    local bearing_tag="UNK"
    if [ "$bearing_deg" != "-1" ]; then
        bearing_tag="${bearing_deg}deg"
    fi
    local final_name="hunt_${freq_mhz}MHz_${bearing_tag}_${ts}.wav"
    local final_path="${RECORDINGS_DIR}/${final_name}"

    sox "$vbf_file" "$final_path" norm -1 2>/dev/null
    rm -f "$vbf_file"

    local duration=$(soxi -D "$final_path" 2>/dev/null || echo "0")
    log "  ★ HUNT HIT: ${freq_mhz} MHz → ${bearing_str} (conf=${confidence}) | ${duration}s | var=${var_val}"
    echo "$ts_utc,$freq_mhz,$bearing_deg,$confidence,true,$final_name" >> "$HUNT_LOG"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════

log "═══════════════════════════════════════════════════════════════"
log "KRAKENSDR FOX HUNT"
log "Duration: ${DURATION_HOURS}h | Dwell: ${DWELL_SEC}s/freq"
log "KrakenSDR: ${KRAKEN_HOST}:${KRAKEN_PORT}"
log "Frequencies: ${FREQ_LIST}"
log "Variance threshold: ${VARIANCE_THRESHOLD} | Noise floor: ${NOISE_RMS}"
log "Bearing log: ${HUNT_LOG}"
log "End time: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')"
log "═══════════════════════════════════════════════════════════════"

cycle=0
total_hits=0

while [ $(date +%s) -lt $END_TIME ]; do
    cycle=$((cycle + 1))

    for freq_mhz in "${FREQS[@]}"; do
        [ $(date +%s) -ge $END_TIME ] && break
        log "Cycle $cycle | Hunting ${freq_mhz} MHz..."
        hunt_freq "$freq_mhz"
    done

    hits=$(grep -c "true" "$HUNT_LOG" 2>/dev/null || echo 0)
    total_hits=$((hits - 1))  # subtract header
    [ $total_hits -lt 0 ] && total_hits=0
    log "Cycle $cycle complete | Total hits: $total_hits"
done

log "═══════════════════════════════════════════════════════════════"
log "FOX HUNT COMPLETE — $total_hits voice recordings with bearings"
log "Bearing log: $HUNT_LOG"
log "Recordings: $RECORDINGS_DIR"
log "═══════════════════════════════════════════════════════════════"
