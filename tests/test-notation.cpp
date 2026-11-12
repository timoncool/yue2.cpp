// test-notation.cpp: measure inference from decoded beats
//
// SheetSage2 labels each rhythm event with the eighth position it hears, and
// notation.h turns the events labelled beat 1 into downbeats, so the measures
// are the spans between two downbeats. A weak beat labelled beat 1 at a phrase
// boundary used to become a one-beat measure and the ABC carried a 1/4 meter.
// not_measures() now re-cuts the score from the first span whose length
// disagrees with the meter the beats themselves carry.
//
// Pure CPU: notation.h only needs the standard library.

#include "notation.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static std::vector<NotBeat> grid(const std::vector<int> & beat_ids, int num = 4, int den = 4) {
    std::vector<NotBeat> beats;
    beats.reserve(beat_ids.size());
    for (size_t i = 0; i < beat_ids.size(); i++) {
        beats.push_back({ 0.5 * (double) i, beat_ids[i], num, den });
    }
    return beats;
}

static bool infer(const std::vector<NotBeat> & beats, std::vector<NotMeasure> * measures) {
    std::string error;
    if (!not_measures(beats, measures, &error)) {
        fprintf(stderr, "[Test-Notation] FAIL: not_measures: %s\n", error.c_str());
        return false;
    }
    return true;
}

static bool all_full_bars(const std::vector<NotMeasure> & measures, int num) {
    for (const NotMeasure & m : measures) {
        if (m.end_beat - m.start_beat != num || m.abc_numerator != num || m.abc_denominator != 4) {
            return false;
        }
    }
    return true;
}

static void expect(bool condition, const char * what) {
    if (!condition) {
        fprintf(stderr, "[Test-Notation] FAIL: %s\n", what);
        exit(1);
    }
}

static void expect_span(const NotMeasure & m, int start, int end, const char * what) {
    if (m.start_beat != start || m.end_beat != end) {
        fprintf(stderr, "[Test-Notation] FAIL: %s (measure [%d,%d), expected [%d,%d))\n", what, m.start_beat, m.end_beat, start, end);
        exit(1);
    }
}

// A clean 4/4 score: four beats per measure, the last downbeat closes it.
static void clean_4_4_is_untouched() {
    std::vector<int> ids;
    for (int bar = 0; bar < 8; bar++) {
        ids.push_back(1);
        ids.push_back(2);
        ids.push_back(3);
        ids.push_back(4);
    }
    ids.push_back(1);
    std::vector<NotMeasure> measures;
    expect(infer(grid(ids), &measures), "clean 4/4 reads");
    expect(measures.size() == 8, "clean 4/4 keeps 8 measures");
    for (size_t i = 0; i < measures.size(); i++) {
        expect_span(measures[i], (int) i * 4, (int) i * 4 + 4, "clean 4/4 boundary");
    }
    expect(all_full_bars(measures, 4), "clean 4/4 stays 4/4");
}

// The 王北车-画 pattern: a downbeat one beat after the last one (the model
// labelled a weak beat beat 1), and the new phase keeps going afterwards.
static void early_downbeat_is_rebarred() {
    std::vector<int> ids = { 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4,
                             1,  // the bar starts here
                             1, 2, 3, 4,  // one beat in, the slip lands
                             1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4 };
    std::vector<NotMeasure> measures;
    expect(infer(grid(ids), &measures), "slipped 4/4 reads");
    expect(measures.size() == 8, "slipped 4/4 has 8 measures");
    for (size_t i = 0; i < 4; i++) {
        expect_span(measures[i], (int) i * 4, (int) i * 4 + 4, "measures before the slip stay");
    }
    expect(all_full_bars(measures, 4), "slipped 4/4 is rebarred to 4/4");
}

// The 借 pattern: three beats then one before the next real downbeat.
static void three_one_pair_is_rebarred() {
    std::vector<int> ids = { 1, 2, 3, 4, 1, 2, 3, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2 };
    // downbeats 0, 4, 7, 11, 15, 19: spans 4, 3, 4, 4, 4
    std::vector<NotMeasure> measures;
    expect(infer(grid(ids), &measures), "3+1 reads");
    expect(measures.size() == 5, "3+1 rebarred into 5 measures");
    expect(all_full_bars(measures, 4), "3+1 becomes 4/4");
}

// A short first span is a pickup: it keeps its notes and takes the following
// meter with a leading rest.
static void pickup_is_padded() {
    std::vector<int> ids = { 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1 };
    std::vector<NotMeasure> measures;
    expect(infer(grid(ids), &measures), "pickup reads");
    expect(measures.size() == 3, "pickup plus two measures");
    expect(measures[0].pad_before, "pickup is padded before");
    expect(measures[0].abc_numerator == 4 && measures[0].abc_denominator == 4, "pickup takes the following meter");
    expect(measures[0].end_beat - measures[0].start_beat == 2, "pickup keeps its two beats");
}

// A real 3/4 score must not be rebarred to 4/4.
static void waltz_stays_three() {
    std::vector<int> ids;
    for (int bar = 0; bar < 8; bar++) {
        ids.push_back(1);
        ids.push_back(2);
        ids.push_back(3);
    }
    ids.push_back(1);
    std::vector<NotMeasure> measures;
    expect(infer(grid(ids, 3, 4), &measures), "3/4 reads");
    expect(measures.size() == 8, "3/4 keeps 8 measures");
    expect(all_full_bars(measures, 3), "3/4 stays 3/4");
}

// Beats that disagree about the meter are a meter change, not a slip: the
// span is left alone.
static void mixed_meter_span_is_kept() {
    std::vector<NotBeat> beats = {
        { 0.0, 1, 4, 4 }, { 0.5, 2, 4, 4 }, { 1.0, 3, 4, 4 }, { 1.5, 4, 4, 4 },
        { 2.0, 1, 4, 4 }, { 2.5, 2, 3, 4 }, { 3.0, 3, 3, 4 }, { 3.5, 4, 3, 4 },
        { 4.0, 1, 3, 4 },
    };
    std::vector<NotMeasure> measures;
    expect(infer(beats, &measures), "mixed meter reads");
    expect(measures.size() == 2, "mixed meter keeps both spans");
    expect_span(measures[0], 0, 4, "first span unchanged");
    expect_span(measures[1], 4, 8, "mixed span unchanged");
}

int main() {
    clean_4_4_is_untouched();
    early_downbeat_is_rebarred();
    three_one_pair_is_rebarred();
    pickup_is_padded();
    waltz_stays_three();
    mixed_meter_span_is_kept();
    fprintf(stderr, "[Test-Notation] ok\n");
    return 0;
}
