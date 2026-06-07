#!/usr/bin/env python3
"""
Antenna Array Calculator — Compute optimal element spacing for KrakenSDR.

The KrakenSDR uses a 5-element Uniform Circular Array (UCA). Element spacing
determines the usable frequency range. This tool helps you:

  1. Find the optimal array radius for your target frequency band
  2. Check if a given radius works for specific frequencies
  3. Show the frequency range for the default array

The general rule: element spacing should be ~λ/2 at the highest frequency
of interest. For a 5-element UCA, the element spacing relates to radius as:
    spacing = 2 × radius × sin(π/5)

Usage:
    ./antenna_calculator.py                          # show default array info
    ./antenna_calculator.py --freq 462.7125          # optimal radius for FRS
    ./antenna_calculator.py --freq 146.0 462.0       # range covering VHF + UHF
    ./antenna_calculator.py --radius 0.127           # what freqs fit 12.7cm radius
    ./antenna_calculator.py --band vhf               # VHF preset
    ./antenna_calculator.py --all-bands              # show all common SIGINT bands

Dependencies: Python 3 (stdlib only)
"""
import argparse
import math
import sys

C = 299792458.0  # speed of light m/s
NUM_ELEMENTS = 5


def freq_to_wavelength(freq_mhz):
    return C / (freq_mhz * 1e6)


def wavelength_to_freq(wavelength_m):
    return C / (wavelength_m * 1e6) if wavelength_m > 0 else 0


def uca_spacing(radius_m):
    """Element-to-element spacing for N-element UCA."""
    return 2 * radius_m * math.sin(math.pi / NUM_ELEMENTS)


def radius_for_spacing(spacing_m):
    """Radius for a given element spacing."""
    return spacing_m / (2 * math.sin(math.pi / NUM_ELEMENTS))


def optimal_radius(freq_mhz):
    """Optimal UCA radius for λ/2 spacing at given frequency."""
    wavelength = freq_to_wavelength(freq_mhz)
    half_lambda = wavelength / 2
    return radius_for_spacing(half_lambda)


def freq_range_for_radius(radius_m):
    """
    Usable frequency range for a given radius.
    - Min freq: spacing = λ (below this, ambiguities appear)
    - Optimal freq: spacing = λ/2 (best accuracy)
    - Max freq: spacing = λ/4 (above this, mutual coupling degrades)
    """
    spacing = uca_spacing(radius_m)

    # spacing = λ → λ = spacing → freq = c/λ
    freq_min = wavelength_to_freq(spacing)       # spacing = λ (loose lower bound)
    freq_opt = wavelength_to_freq(spacing / 0.5) # wait, spacing = λ/2 → λ = 2*spacing
    # Let me redo this correctly:
    # At optimal: spacing = λ/2, so λ = 2*spacing, freq = c/(2*spacing)
    freq_optimal = C / (2 * spacing * 1e0) / 1e6
    # Practical lower: spacing = λ/4, λ = 4*spacing, freq = c/(4*spacing)
    freq_low = C / (spacing * 1e0) / 1e6   # spacing = λ
    # Practical upper: spacing = λ/2 is optimal; at λ/4 grating lobes start
    # Actually for UCA DOA, usable range is roughly:
    #   Lower bound: spacing ≥ λ/4 (below this, almost no phase difference)
    #   Upper bound: spacing ≤ λ (above this, ambiguity/grating lobes)
    freq_lower = C / (4 * spacing) / 1e6   # spacing = λ/4, very low SNR
    freq_upper = C / (spacing) / 1e6        # spacing = λ, ambiguity onset

    return {
        "min_mhz": round(freq_lower, 2),
        "optimal_mhz": round(C / (2 * spacing) / 1e6, 2),
        "max_mhz": round(freq_upper, 2),
        "spacing_m": round(spacing, 4),
        "spacing_cm": round(spacing * 100, 2),
    }


BAND_PRESETS = {
    "vhf":      {"name": "VHF (136–174 MHz)", "low": 136, "high": 174,
                 "use": "MURS, marine, ham 2m, public safety"},
    "uhf":      {"name": "UHF (400–470 MHz)", "low": 400, "high": 470,
                 "use": "FRS/GMRS, business, ham 70cm"},
    "frs":      {"name": "FRS/GMRS (462–467 MHz)", "low": 462, "high": 467,
                 "use": "FRS channels, GMRS repeaters"},
    "ham2m":    {"name": "Ham 2m (144–148 MHz)", "low": 144, "high": 148,
                 "use": "Amateur 2m voice/data"},
    "ham70cm":  {"name": "Ham 70cm (420–450 MHz)", "low": 420, "high": 450,
                 "use": "Amateur 70cm voice/data"},
    "marine":   {"name": "Marine VHF (156–163 MHz)", "low": 156, "high": 163,
                 "use": "Marine channels, Ch16 distress"},
    "airband":  {"name": "Airband (118–137 MHz)", "low": 118, "high": 137,
                 "use": "Aviation AM voice"},
    "ism433":   {"name": "ISM 433 MHz", "low": 432, "high": 435,
                 "use": "ISM devices, weather stations, sensors"},
    "800mhz":   {"name": "800 MHz (806–870 MHz)", "low": 806, "high": 870,
                 "use": "P25 trunked, public safety"},
    "murs":     {"name": "MURS (151–154 MHz)", "low": 151, "high": 154,
                 "use": "Multi-Use Radio Service"},
}


def print_radius_info(radius_m):
    """Print info about a given radius."""
    spacing = uca_spacing(radius_m)
    frange = freq_range_for_radius(radius_m)

    print(f"  Array geometry:")
    print(f"    Type:            {NUM_ELEMENTS}-element UCA")
    print(f"    Radius:          {radius_m*100:.2f} cm ({radius_m:.4f} m)")
    print(f"    Diameter:        {radius_m*200:.2f} cm")
    print(f"    Element spacing: {spacing*100:.2f} cm")
    print(f"    Circumference:   {2*math.pi*radius_m*100:.2f} cm")
    print()
    print(f"  Frequency coverage:")
    print(f"    Lower bound:     {frange['min_mhz']:.1f} MHz  (spacing = λ/4, marginal)")
    print(f"    Optimal:         {frange['optimal_mhz']:.1f} MHz  (spacing = λ/2, best DOA)")
    print(f"    Upper bound:     {frange['max_mhz']:.1f} MHz  (spacing = λ, ambiguity risk)")
    print()
    return frange


def print_band_table(radius_m):
    """Show how well a radius covers each band."""
    frange = freq_range_for_radius(radius_m)
    spacing = uca_spacing(radius_m)
    print(f"  Band coverage at {radius_m*100:.1f}cm radius:")
    print(f"  {'Band':<25s}  {'Range':>16s}  {'Status'}")
    print(f"  {'─'*25}  {'─'*16}  {'─'*30}")

    for key in ["airband", "vhf", "ham2m", "murs", "marine", "uhf", "ham70cm",
                "frs", "ism433", "800mhz"]:
        b = BAND_PRESETS[key]
        mid = (b["low"] + b["high"]) / 2
        wl = freq_to_wavelength(mid)
        ratio = spacing / wl

        if b["low"] >= frange["min_mhz"] and b["high"] <= frange["max_mhz"]:
            if abs(ratio - 0.5) < 0.15:
                status = "★ OPTIMAL"
            else:
                status = "✓ Usable"
        elif b["low"] < frange["min_mhz"] and b["high"] > frange["min_mhz"]:
            status = "◐ Partial (low end marginal)"
        elif b["low"] < frange["max_mhz"] and b["high"] > frange["max_mhz"]:
            status = "◐ Partial (high end marginal)"
        else:
            status = "✗ Outside range"

        print(f"  {b['name']:<25s}  {b['low']:>6.0f}–{b['high']:<6.0f} MHz  {status}")

    print()


def main():
    parser = argparse.ArgumentParser(
        description="Antenna array calculator for KrakenSDR 5-element UCA",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                              # default 12.7cm array info
  %(prog)s --freq 462.7125              # optimal for FRS
  %(prog)s --freq 146.0 462.0           # compromise for VHF+UHF
  %(prog)s --radius 0.25                # check 25cm radius coverage
  %(prog)s --band vhf                   # VHF-optimized array
  %(prog)s --all-bands                  # all bands with default radius

Bands: """ + ", ".join(BAND_PRESETS.keys()),
    )
    parser.add_argument("--freq", type=float, nargs="+",
                        help="Target frequency/frequencies in MHz")
    parser.add_argument("--radius", type=float,
                        help="Check coverage for specific radius (meters)")
    parser.add_argument("--band", choices=list(BAND_PRESETS.keys()),
                        help="Use band preset")
    parser.add_argument("--all-bands", action="store_true",
                        help="Show coverage table for all bands")

    args = parser.parse_args()

    print()
    print("═══ KrakenSDR Antenna Array Calculator ═══")
    print()

    if args.freq:
        # Compute optimal radius for target frequencies
        if len(args.freq) == 1:
            freq = args.freq[0]
            r = optimal_radius(freq)
            print(f"  Target: {freq:.4f} MHz")
            print(f"  λ = {freq_to_wavelength(freq)*100:.1f} cm")
            print(f"  Optimal radius: {r*100:.2f} cm ({r:.4f} m)")
            print()
            print_radius_info(r)
            print_band_table(r)
        else:
            # Compromise radius for multiple frequencies
            # Use geometric mean for best compromise
            radii = [optimal_radius(f) for f in args.freq]
            r_compromise = math.exp(sum(math.log(r) for r in radii) / len(radii))

            print(f"  Target frequencies:")
            for f in args.freq:
                r = optimal_radius(f)
                print(f"    {f:.4f} MHz → optimal radius {r*100:.2f} cm")
            print()
            print(f"  Compromise radius: {r_compromise*100:.2f} cm (geometric mean)")
            print()
            print_radius_info(r_compromise)

            # Show per-frequency performance at compromise
            print(f"  Per-frequency performance at {r_compromise*100:.1f}cm:")
            spacing = uca_spacing(r_compromise)
            for f in args.freq:
                wl = freq_to_wavelength(f)
                ratio = spacing / wl
                quality = "optimal" if abs(ratio - 0.5) < 0.1 else \
                          "good" if abs(ratio - 0.5) < 0.2 else \
                          "usable" if 0.25 < ratio < 1.0 else "poor"
                print(f"    {f:.4f} MHz: spacing/λ = {ratio:.3f} ({quality})")
            print()
            print_band_table(r_compromise)

    elif args.band:
        b = BAND_PRESETS[args.band]
        mid = (b["low"] + b["high"]) / 2
        r = optimal_radius(mid)
        print(f"  Band: {b['name']}")
        print(f"  Use:  {b['use']}")
        print(f"  Mid-band: {mid:.1f} MHz")
        print(f"  Optimal radius: {r*100:.2f} cm")
        print()
        print_radius_info(r)
        print_band_table(r)

    elif args.radius:
        print(f"  Specified radius: {args.radius*100:.2f} cm")
        print()
        print_radius_info(args.radius)
        print_band_table(args.radius)

    elif args.all_bands:
        # Default radius
        default_r = 0.127
        print(f"  Default array radius: {default_r*100:.1f} cm")
        print()
        print_radius_info(default_r)
        print_band_table(default_r)

        print("  Optimal radii per band:")
        print(f"  {'Band':<25s}  {'Radius':>10s}  {'Diameter':>10s}  {'Spacing':>10s}")
        print(f"  {'─'*25}  {'─'*10}  {'─'*10}  {'─'*10}")
        for key in ["airband", "vhf", "ham2m", "murs", "marine", "uhf",
                     "ham70cm", "frs", "ism433", "800mhz"]:
            b = BAND_PRESETS[key]
            mid = (b["low"] + b["high"]) / 2
            r = optimal_radius(mid)
            s = uca_spacing(r)
            print(f"  {b['name']:<25s}  {r*100:>8.1f}cm  {r*200:>8.1f}cm  {s*100:>8.1f}cm")
        print()

    else:
        # Default: show info for the config default (12.7cm)
        default_r = 0.127
        print(f"  Current config radius: {default_r*100:.1f} cm")
        print(f"  (from kraken/config/kraken_defaults.json)")
        print()
        print_radius_info(default_r)
        print_band_table(default_r)

        print("  Tip: The 12.7cm radius is optimized for ~430-590 MHz (UHF/FRS/GMRS).")
        print("  For VHF (MURS/marine/2m), you need a larger array (~50-55cm radius).")
        print("  You can't cover both VHF and UHF well with one array size.")
        print("  Build two ground planes, or optimize for your primary target band.")
        print()


if __name__ == "__main__":
    main()
