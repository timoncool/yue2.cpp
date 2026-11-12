#pragma once
// float-check.h: what a float buffer holds, to name where a song turned into
// silence: NaN and Inf, exact zeros, and the sum of magnitudes as a checksum.

#include <cmath>
#include <cstddef>
#include <cstdio>

struct FloatStats {
    size_t count;
    size_t nans;
    size_t infs;
    size_t zeros;
    double abs_sum;
};

static FloatStats float_stats(const float * x, size_t count) {
    FloatStats s = { count, 0, 0, 0, 0.0 };
    for (size_t i = 0; i < count; i++) {
        const float v = x[i];
        if (std::isnan(v)) {
            s.nans++;
        } else if (std::isinf(v)) {
            s.infs++;
        } else {
            if (v == 0.0f) {
                s.zeros++;
            }
            s.abs_sum += std::fabs(v);
        }
    }
    return s;
}

// Not a sound to pass on: anything not finite, or nothing but zeros
static bool float_stats_bad(const FloatStats & s) {
    return s.count > 0 && (s.nans > 0 || s.infs > 0 || s.zeros == s.count);
}

static void float_stats_print(const char * tag, const char * where, const FloatStats & s) {
    fprintf(stderr, "%s %s: %zu values, %zu NaN, %zu Inf, %.1f%% zeros, sum|x| %.6g\n", tag, where, s.count, s.nans,
            s.infs, s.count ? 100.0 * (double) s.zeros / (double) s.count : 0.0, s.abs_sum);
}
