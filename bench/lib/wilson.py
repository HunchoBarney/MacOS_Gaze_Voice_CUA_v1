"""Wilson score lower bound + percentiles. Stdlib only."""

import math


def wilson_low(successes, n, z=1.96):
    """Wilson lower bound for successes/n at confidence z (1.96 = 95%).
    0/0 -> 0.0. Reference bounds: 5/5 ~= 0.566, 8/10 ~= 0.49."""
    if n <= 0:
        return 0.0
    p = successes / n
    z2 = z * z
    denom = 1.0 + z2 / n
    centre = p + z2 / (2.0 * n)
    margin = z * math.sqrt(p * (1.0 - p) / n + z2 / (4.0 * n * n))
    return max(0.0, (centre - margin) / denom)


def percentile(values, pct):
    """Linear-interpolated percentile (pct in 0..100); None on empty."""
    vals = sorted(float(v) for v in values if v is not None)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * pct / 100.0
    lo = int(math.floor(k))
    hi = min(lo + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def p50(values):
    return percentile(values, 50)


def p95(values):
    return percentile(values, 95)
