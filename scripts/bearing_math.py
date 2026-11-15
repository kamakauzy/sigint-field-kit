#!/usr/bin/env python3
"""
Circular statistics for compass bearings (degrees, 0 = north, clockwise).

Bearings live on a circle, so ordinary arithmetic breaks at the 0/360 seam:
the linear mean of 359 and 1 is 180 (due south) when the right answer is 0.
Every place that averages, compares, or differences bearings should use
these helpers instead of +, -, min/max, or statistics.mean.
"""
import math


def normalize_deg(angle):
    """Wrap any angle into [0, 360)."""
    a = float(angle) % 360.0
    return 0.0 if a >= 360.0 else a  # guard against -1e-18 % 360 == 360.0


def angular_diff_deg(a, b):
    """Signed shortest rotation from b to a, in [-180, 180).

    angular_diff_deg(1, 359) == 2, angular_diff_deg(359, 1) == -2.
    """
    d = (float(a) - float(b) + 180.0) % 360.0 - 180.0
    return -180.0 if d >= 180.0 else d


def angular_distance_deg(a, b):
    """Unsigned shortest angle between two bearings, in [0, 180]."""
    return abs(angular_diff_deg(a, b))


def _resultant(angles):
    s = sum(math.sin(math.radians(a)) for a in angles)
    c = sum(math.cos(math.radians(a)) for a in angles)
    return s, c


def circular_mean_deg(angles):
    """Circular mean of bearings in [0, 360), or None if empty/undefined.

    Undefined (None) when the bearings cancel out, e.g. [0, 180].
    """
    angles = list(angles)
    if not angles:
        return None
    s, c = _resultant(angles)
    if math.hypot(s, c) < 1e-9 * len(angles):
        return None
    return normalize_deg(math.degrees(math.atan2(s, c)))


def mean_resultant_length(angles):
    """R in [0, 1]: 1 = all bearings identical, 0 = uniformly spread."""
    angles = list(angles)
    if not angles:
        return 0.0
    s, c = _resultant(angles)
    return min(1.0, math.hypot(s, c) / len(angles))


def circular_std_deg(angles):
    """Circular standard deviation in degrees: sqrt(-2 ln R)."""
    R = mean_resultant_length(angles)
    if R >= 1.0:
        return 0.0
    return math.degrees(math.sqrt(-2.0 * math.log(max(R, 1e-10))))


def circular_range_deg(angles):
    """Smallest arc containing all bearings: (start, end, width).

    Walks clockwise from start to end. For [350, 5, 10] returns
    (350.0, 10.0, 20.0), not the linear (5, 350).
    """
    pts = sorted(normalize_deg(a) for a in angles)
    if not pts:
        return None
    if len(pts) == 1:
        return pts[0], pts[0], 0.0
    # The arc is the complement of the largest gap between neighbours.
    gaps = [(pts[(i + 1) % len(pts)] - pts[i]) % 360.0 for i in range(len(pts))]
    i = max(range(len(pts)), key=lambda k: gaps[k])
    start = pts[(i + 1) % len(pts)]
    end = pts[i]
    return start, end, 360.0 - gaps[i]
