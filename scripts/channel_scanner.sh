#!/bin/bash
#══════════════════════════════════════════════════════════════════════════
# Channel Activity Scanner — Quickly samples multiple frequencies and
# reports which ones have intermittent voice traffic vs constant carriers.
#
# Usage:
#   ./channel_scanner.sh              # Scan FRS + MURS + Marine
#   ./channel_scanner.sh 10           # 10s dwell per channel
#   ./channel_scanner.sh 10 custom    # 10s dwell, custom freq list via stdin
#
# Output: sorted list of frequencies ranked by voice likelihood
#══════════════════════════════════════════════════════════════════════════

set -euo pipefail

DWELL="${1:-8}"
MODE="${2:-default}"
GAIN=38
DEVICE=0
SAMPLE_RATE=24000

# FRS (7 channels), MURS (5 channels), Marine ch16, Ham 2m, VHF biz
if [ "$MODE" = "default" ]; then
    FREQS=(
        462.5625 462.5875 462.6125 462.6375 462.6625 462.6875 462.7125
        467.5625 467.5875 467.6125 467.6375 467.6625 467.6875 467.7125
        151.820 151.880 151.940 154.570 154.600
        156.800 156.450 156.500
        145.500 146.520 146.940 147.000 147.060 147.120
        153.643 155.370 155.640 158.400
    )
else
    # Read freqs from stdin
    read -ra FREQS
fi

echo "═══════════════════════════════════════════════════════════════"
echo "CHANNEL ACTIVITY SCANNER"
echo "Channels: ${#FREQS[@]} | Dwell: ${DWELL}s each"
echo "ETA: $(( ${#FREQS[@]} * (DWELL + 2) / 60 )) minutes"
echo "═══════════════════════════════════════════════════════════════"
echo ""

RESULTS_FILE="/tmp/scanner_results_$$.txt"
> "$RESULTS_FILE"

for freq_mhz in "${FREQS[@]}"; do
    freq_hz=$(echo "$freq_mhz * 1000000" | bc | cut -d. -f1)
    raw="/tmp/scan_$$.raw"
    wav="/tmp/scan_$$.wav"
    vbf="/tmp/scan_vbf_$$.wav"
    
    # Record
    timeout "$DWELL" rtl_fm -f "$freq_hz" -M fm -s "$SAMPLE_RATE" -g "$GAIN" \
        -l 0 -p 0 -d "$DEVICE" "$raw" 2>/dev/null || true
    
    if [ ! -f "$raw" ] || [ $(stat -c%s "$raw" 2>/dev/null || echo 0) -lt 2400 ]; then
        echo "$freq_mhz DEAD 0 0 0" >> "$RESULTS_FILE"
        printf "  %9s MHz: DEAD (no output)\n" "$freq_mhz"
        rm -f "$raw"
        continue
    fi
    
    # Convert + bandpass
    sox -t raw -r "$SAMPLE_RATE" -e signed -b 16 -c 1 "$raw" "$wav" 2>/dev/null
    rm -f "$raw"
    sox "$wav" "$vbf" sinc 300-3400 2>/dev/null || { rm -f "$wav"; continue; }
    rm -f "$wav"
    
    # Analyze: RMS + variance
    result=$(python3 -c "
import struct, wave, math

with wave.open('$vbf', 'rb') as wf:
    rate = wf.getframerate()
    frames = wf.readframes(wf.getnframes())
    samples = struct.unpack('<' + 'h' * (len(frames) // 2), frames)

window = rate  # 1-second windows
rms_vals = []
for i in range(0, len(samples) - window, window):
    chunk = samples[i:i+window]
    ms = sum(s*s for s in chunk) / len(chunk)
    rms_vals.append(math.sqrt(ms) / 32768.0)

if len(rms_vals) < 2:
    print('SHORT 0 0 0')
else:
    mean_rms = sum(rms_vals) / len(rms_vals)
    stddev = math.sqrt(sum((r - mean_rms)**2 for r in rms_vals) / len(rms_vals))
    peak = max(rms_vals)
    
    # Classify
    if mean_rms < 0.010:
        kind = 'QUIET'
    elif stddev < 0.002:
        kind = 'CARRIER'
    elif stddev < 0.005:
        kind = 'MAYBE'
    else:
        kind = 'VOICE'
    
    print(f'{kind} {mean_rms:.6f} {stddev:.6f} {peak:.6f}')
" 2>/dev/null || echo "ERROR 0 0 0")
    
    rm -f "$vbf"
    
    kind=$(echo "$result" | awk '{print $1}')
    mean_r=$(echo "$result" | awk '{print $2}')
    stddev=$(echo "$result" | awk '{print $3}')
    peak=$(echo "$result" | awk '{print $4}')
    
    echo "$freq_mhz $kind $mean_r $stddev $peak" >> "$RESULTS_FILE"
    
    case "$kind" in
        VOICE)  marker="★★★" ;;
        MAYBE)  marker="★★ " ;;
        CARRIER) marker="─── " ;;
        QUIET)  marker="   " ;;
        *)      marker="? " ;;
    esac
    
    printf "  %9s MHz: %-7s %s  (rms=%.4f var=%.5f peak=%.4f)\n" \
        "$freq_mhz" "$kind" "$marker" "$mean_r" "$stddev" "$peak"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "SUMMARY — Best targets for voice recording:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
grep -E "VOICE|MAYBE" "$RESULTS_FILE" | sort -k4 -rn | while read freq kind mean_r stddev peak; do
    printf "  %9s MHz  variance=%-8s  (peak RMS=%.4f)\n" "$freq" "$stddev" "$peak"
done

voice_count=$(grep -c "VOICE" "$RESULTS_FILE" 2>/dev/null || echo 0)
maybe_count=$(grep -c "MAYBE" "$RESULTS_FILE" 2>/dev/null || echo 0)
carrier_count=$(grep -c "CARRIER" "$RESULTS_FILE" 2>/dev/null || echo 0)
quiet_count=$(grep -c "QUIET" "$RESULTS_FILE" 2>/dev/null || echo 0)

echo ""
echo "Totals: $voice_count VOICE | $maybe_count MAYBE | $carrier_count CARRIER | $quiet_count QUIET"
echo ""

# Output recommended freq list
echo "Recommended freq list for squelch_recorder.sh:"
recommended=$(grep -E "VOICE|MAYBE" "$RESULTS_FILE" | sort -k4 -rn | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
if [ -n "$recommended" ]; then
    echo "  $recommended"
else
    echo "  (none found — try during busier hours)"
fi

rm -f "$RESULTS_FILE"
