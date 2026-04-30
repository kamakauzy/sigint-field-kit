#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# Adaptive SIGINT Collector — Baseline → Detect → Target
#
# Phase 1: Quick spectrum sweep to measure current state
# Phase 2: Compare against stored baseline (or build one if first run)
# Phase 3: Any frequency that deviates from baseline gets focused
#          voice collection with full dwell time
#
# This implements automated F3EAD:
#   FIND    — spectrum sweep identifies active frequencies
#   FIX     — baseline comparison identifies ANOMALIES
#   FINISH  — voice recorder targets anomalous freqs only
#
# Usage:
#   ./sigint_adaptive.sh              # Run continuously (8h default)
#   ./sigint_adaptive.sh 12           # 12 hours
#   ./sigint_adaptive.sh 8 build      # Force baseline rebuild
#
# Requirements: rtl_power, rtl_fm, sox, bc, python3, RTL-SDR
#══════════════════════════════════════════════════════════════════════════

set -uo pipefail

DURATION_HOURS="${1:-8}"
MODE="${2:-run}"   # "run" or "build" (force baseline rebuild)
GAIN=38
DEVICE=0
SAMPLE_RATE=24000

BASE_DIR="/var/lib/recon-raven"
BASELINE_FILE="$BASE_DIR/baselines/spectrum_baseline.json"
LOG_FILE="$BASE_DIR/logs/adaptive_$(date +%Y%m%d-%H%M%S).log"
RECORDINGS_DIR="$BASE_DIR/recordings"
SWEEP_INTERVAL=120       # Seconds between spectrum checks
VOICE_DWELL=10           # Seconds to record when targeting a freq
VOICE_THRESHOLD="10%"    # Voice-band energy gate
MIN_VOICE_SEC="1.5"      # Min voice duration to keep
ANOMALY_DB=8             # dB above baseline = anomaly

# Bands to sweep (must match baseline)
VHF_RANGE="136M:174M:50k"
UHF_RANGE="400M:470M:100k"
P25_RANGE="806M:870M:100k"

mkdir -p "$BASE_DIR/baselines" "$RECORDINGS_DIR" "$(dirname "$LOG_FILE")"

END_TIME=$(( $(date +%s) + DURATION_HOURS * 3600 ))

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Adaptive collector stopping"
    pkill -P $$ rtl_power 2>/dev/null || true
    pkill -P $$ rtl_fm 2>/dev/null || true
    rm -f /tmp/adaptive_sweep_*.csv /tmp/adaptive_*.raw /tmp/adaptive_*.wav
    log "Session captures: $(find "$RECORDINGS_DIR" -name '*.wav' -newer "$LOG_FILE" 2>/dev/null | wc -l)"
    exit 0
}
trap cleanup EXIT INT TERM

# ─── Quick Spectrum Sweep ────────────────────────────────────────────────
# Returns path to CSV containing all 3 bands
do_sweep() {
    local tmp="/tmp/adaptive_sweep_$$.csv"
    local tv="/tmp/adaptive_vhf_$$.csv"
    local tu="/tmp/adaptive_uhf_$$.csv"
    local tp="/tmp/adaptive_p25_$$.csv"
    rm -f "$tmp" "$tv" "$tu" "$tp"

    rtl_power -f $VHF_RANGE -i 5 -1 -g $GAIN -d $DEVICE -p 0 "$tv" 2>/dev/null
    rtl_power -f $UHF_RANGE -i 5 -1 -g $GAIN -d $DEVICE -p 0 "$tu" 2>/dev/null
    rtl_power -f $P25_RANGE -i 5 -1 -g $GAIN -d $DEVICE -p 0 "$tp" 2>/dev/null
    cat "$tv" "$tu" "$tp" > "$tmp" 2>/dev/null
    rm -f "$tv" "$tu" "$tp"

    echo "$tmp"
}

# ─── Parse Sweep → JSON baseline ────────────────────────────────────────
# Extracts per-frequency average power into a JSON dict
parse_sweep_to_json() {
    local csv_file="$1"
    local out_file="$2"

    python3 << PYEOF
import json
from collections import defaultdict

freq_power = defaultdict(list)
with open("$csv_file") as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) < 7:
            continue
        hz_low = float(parts[2].strip())
        hz_high = float(parts[3].strip())
        powers = [float(p.strip()) for p in parts[6:] if p.strip()]
        if not powers:
            continue
        center_mhz = round((hz_low + hz_high) / 2 / 1e6, 3)
        freq_power[center_mhz].append(max(powers))

baseline = {}
for freq, powers in freq_power.items():
    baseline[str(freq)] = round(sum(powers) / len(powers), 1)

with open("$out_file", 'w') as f:
    json.dump(baseline, f, indent=2)

print(f"Baseline: {len(baseline)} frequencies")
PYEOF
}

# ─── Compare current sweep against baseline ──────────────────────────────
# Returns list of anomalous frequencies (above baseline by ANOMALY_DB)
find_anomalies() {
    local csv_file="$1"

    python3 << PYEOF
import json
from collections import defaultdict

# Load baseline
try:
    with open("$BASELINE_FILE") as f:
        baseline = json.load(f)
except:
    print("NO_BASELINE")
    exit(0)

# Parse current sweep
freq_power = defaultdict(list)
with open("$csv_file") as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) < 7:
            continue
        hz_low = float(parts[2].strip())
        hz_high = float(parts[3].strip())
        powers = [float(p.strip()) for p in parts[6:] if p.strip()]
        if not powers:
            continue
        center_mhz = round((hz_low + hz_high) / 2 / 1e6, 3)
        freq_power[center_mhz].append(max(powers))

# Find anomalies
anomalies = []
for freq_str, current_powers in freq_power.items():
    current_max = max(current_powers)
    baseline_val = baseline.get(str(freq_str))
    if baseline_val is None:
        # New frequency not in baseline — always anomalous
        if current_max > -20:
            anomalies.append((freq_str, current_max, 99.0))
    else:
        delta = current_max - baseline_val
        if delta >= $ANOMALY_DB:
            anomalies.append((freq_str, current_max, delta))

# Sort by delta (biggest anomaly first), output top 5
anomalies.sort(key=lambda x: x[2], reverse=True)
for freq, power, delta in anomalies[:5]:
    freq_hz = int(float(freq) * 1e6)
    print(f"{freq_hz}:{power}:{delta}")
PYEOF
}

# ─── Voice capture on a specific frequency ───────────────────────────────
capture_voice() {
    local freq_hz="$1"
    local freq_mhz="$2"
    local delta="$3"

    local ts=$(date +%Y%m%d-%H%M%S)
    local raw_file="/tmp/adaptive_${freq_mhz}MHz_${ts}.raw"
    local tmp_wav="/tmp/adaptive_${freq_mhz}MHz_${ts}.wav"
    local vbf_wav="/tmp/adaptive_${freq_mhz}MHz_${ts}_vbf.wav"
    local final_wav="${RECORDINGS_DIR}/target_${freq_mhz}MHz_${ts}.wav"

    # Record with longer dwell (targeting this specific freq)
    timeout "$VOICE_DWELL" rtl_fm \
        -f "$freq_hz" \
        -M fm \
        -s "$SAMPLE_RATE" \
        -g "$GAIN" \
        -p 0 \
        "$raw_file" 2>/dev/null || true

    [ ! -f "$raw_file" ] && return 1
    [ $(stat -c%s "$raw_file" 2>/dev/null || echo 0) -lt 4800 ] && { rm -f "$raw_file"; return 1; }

    # Convert to WAV
    sox -t raw -r "$SAMPLE_RATE" -e signed -b 16 -c 1 "$raw_file" "$tmp_wav" 2>/dev/null || { rm -f "$raw_file"; return 1; }
    rm -f "$raw_file"

    # Bandpass voice frequencies (300-3000 Hz)
    # Removes CTCSS tones (67-254 Hz) and high-freq noise
    sox "$tmp_wav" "$vbf_wav" sinc 300-3000 2>/dev/null || { rm -f "$tmp_wav"; return 1; }

    # Voice gate: strip silence from filtered audio
    sox "$vbf_wav" "$final_wav" \
        silence 1 0.1 "$VOICE_THRESHOLD" \
        reverse silence 1 0.1 "$VOICE_THRESHOLD" reverse \
        2>/dev/null || { rm -f "$tmp_wav" "$vbf_wav"; return 1; }

    rm -f "$tmp_wav" "$vbf_wav"

    # Check duration — must have MIN_VOICE_SEC of actual voice
    if [ -f "$final_wav" ] && [ $(stat -c%s "$final_wav" 2>/dev/null || echo 0) -gt 44 ]; then
        local duration=$(sox "$final_wav" -n stat 2>&1 | grep "Length" | awk '{print $NF}')
        if [ -n "$duration" ] && [ "$(echo "$duration >= $MIN_VOICE_SEC" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            log "  ✓ CAPTURED VOICE: ${freq_mhz} MHz | ${duration}s | +${delta}dB over baseline"
            return 0
        else
            rm -f "$final_wav"
        fi
    else
        rm -f "$final_wav"
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════

log "═══════════════════════════════════════════════════════════════"
log "ADAPTIVE SIGINT COLLECTOR"
log "Duration: ${DURATION_HOURS}h | Sweep interval: ${SWEEP_INTERVAL}s"
log "Anomaly threshold: +${ANOMALY_DB}dB | Voice dwell: ${VOICE_DWELL}s"
log "End time: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')"
log "═══════════════════════════════════════════════════════════════"

# Phase 0: Build or verify baseline
if [ "$MODE" = "build" ] || [ ! -f "$BASELINE_FILE" ]; then
    log "BUILDING BASELINE (3 sweeps averaged)..."
    for i in 1 2 3; do
        sweep_file=$(do_sweep)
        if [ $i -eq 1 ]; then
            cp "$sweep_file" /tmp/baseline_combined.csv
        else
            cat "$sweep_file" >> /tmp/baseline_combined.csv
        fi
        rm -f "$sweep_file"
        log "  Baseline sweep $i/3 complete"
    done
    parse_sweep_to_json /tmp/baseline_combined.csv "$BASELINE_FILE"
    rm -f /tmp/baseline_combined.csv
    log "Baseline saved: $BASELINE_FILE"
fi

log "Baseline loaded: $(python3 -c "import json; print(len(json.load(open('$BASELINE_FILE'))))" 2>/dev/null) frequencies"
log "Entering detection loop..."

cycle=0
total_anomalies=0
total_captures=0

while [ $(date +%s) -lt $END_TIME ]; do
    cycle=$((cycle + 1))

    # Phase 1: FIND — Quick spectrum sweep
    sweep_file=$(do_sweep)

    # Phase 2: FIX — Compare to baseline
    anomalies=$(find_anomalies "$sweep_file")
    rm -f "$sweep_file"

    if [ "$anomalies" = "NO_BASELINE" ]; then
        log "ERROR: No baseline file. Run with 'build' argument first."
        exit 1
    fi

    if [ -z "$anomalies" ]; then
        # No anomalies — everything matches baseline
        if [ $((cycle % 5)) -eq 0 ]; then
            log "Cycle $cycle | No anomalies | Captures: $total_captures"
        fi
    else
        # Phase 3: FINISH — Target each anomaly with voice capture
        total_anomalies=$((total_anomalies + 1))
        log "Cycle $cycle | ANOMALIES DETECTED:"

        while IFS=: read -r freq_hz power delta; do
            [ -z "$freq_hz" ] && continue
            freq_mhz=$(echo "scale=3; $freq_hz/1000000" | bc)
            log "  → ${freq_mhz} MHz | power: ${power} dB | +${delta} dB over baseline"

            # Target it with voice capture
            if capture_voice "$freq_hz" "$freq_mhz" "$delta"; then
                total_captures=$((total_captures + 1))
            fi
        done <<< "$anomalies"
    fi

    # Wait before next sweep
    sleep 30
done

log "═══════════════════════════════════════════════════════════════"
log "SESSION COMPLETE"
log "Cycles: $cycle | Anomaly events: $total_anomalies | Voice captures: $total_captures"
log "═══════════════════════════════════════════════════════════════"
