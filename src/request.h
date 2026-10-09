#pragma once
// request.h: YuE2 generation request (JSON serialization)
//
// Pure data container + JSON read/write. Zero business logic.
// Only fields the pipeline consumes: the protocol constants (vocabulary
// slices, sampling presets, frame rate) live in the pipeline, not here.

#include "harmony.h"
#include "sampling.h"

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

// One adapter of a request, named as it sits in the server adapter directory.
// scale applies to both halves, ar_scale and nar_scale override it for one
// half when set, and a zero leaves that half untouched.
struct Yue2RequestAdapter {
    std::string name;
    float       scale     = 1.0f;
    float       ar_scale  = NAN;
    float       nar_scale = NAN;
};

// One sung section of the lyrics and the moment the score reaches it: its first
// Vocal note on the score clock, and its codepoints in the request lyrics.
struct Yue2LyricSection {
    double  start_sec = 0.0;
    int64_t lyric_c0  = 0;
    int64_t lyric_c1  = 0;
};

// Lyric schedule tied to the score clock (HOT-Step's C6): while the semantic
// stage composes the frame at t, a section whose first note lies more than
// lead_sec after t is kept out of sight by an additive attention bias on its
// prompt rows (-inf hides it outright). behind >= 0 also hides sections more
// than that many before the current one.
struct Yue2LyricSchedule {
    bool                          on       = false;
    float                         bias     = -INFINITY;
    double                        lead_sec = 0.0;
    int                           behind   = -1;
    std::vector<Yue2LyricSection> sections;
};

struct Yue2Request {
    // text content
    std::string style;   // ""
    std::string lyrics;  // ""

    // symbolic plan. Empty in melody or full mode makes the model write one,
    // and the score it produces comes back in the reply so it can be edited
    // and submitted again.
    std::string abc;  // ""

    // with abc: the score is the opening of a plan, not the whole of it. It
    // goes in without its end token and the model writes the rest of the
    // song on from it, in its key and meter (a hummed or played seed).
    bool abc_continue;  // false

    // chain of thought mode: "full", "melody" or "off"
    std::string cot;  // "full"

    // target length in seconds, the budget the semantic stage stops at. The
    // preset of the stage caps it, so the shorter of the two wins.
    float duration;  // 360

    // generation. Two seeds: the token draw consumes lm_seed as a Philox key,
    // the acoustic noise consumes seed as an mt19937 seed. Splitting them is
    // ours, the release runs both from one. Stored in int64_t to land positive
    // after rd().
    int64_t lm_seed;  // -1 = random
    int64_t seed;     // -1 = random
    int     steps;    // 32, steps of the flow matching ODE

    // the ODE solver: "midpoint" (2 evaluations a step) or "ab2" (one a step
    // after the first, see flow-solver.h)
    std::string solver;  // "midpoint"

    // batching: number of songs generated from this prompt. Song i draws
    // its tokens with lm_seed + i, consecutive seeds.
    int lm_batch_size;  // 1

    // number of flow matching variations per song, consecutive noise seeds
    // (seed + j) on the same semantic stream. Output order is song-major:
    // song * synth_batch_size + variation.
    int synth_batch_size;  // 1

    // sampling of each autoregressive stage, the checkpoint presets by default
    Yue2Sampling abc_sampling;
    Yue2Sampling semantic_sampling;

    // semantic stream (CSV of codec values, 25 per second). Non empty replaces
    // the autoregressive stage: the prefix and the codes are prefilled in one
    // forward, so re-rendering with other ODE steps or another decoder costs a
    // single pass instead of the whole token loop.
    std::string semantic_tokens;  // ""

    // with semantic_tokens: compose on after them instead of rendering them
    // alone. The stream is a prefix of the song, prefilled under the same
    // prompt and score; sampling picks up at its frame count and runs to the
    // requested length. One song.
    bool continue_semantic_tokens;  // false

    // classifier free guidance on the semantic stage. Negative applies the
    // protocol default, which is 1.01 in off mode and 1.0 otherwise, and a
    // scale of exactly 1.0 keeps a single branch.
    float cfg_scale;  // -1

    // strength of the server's decoder companion under this render: 1 keeps
    // the sound it was started with, 0 decodes with the checkpoint alone
    float companion_scale;  // 1

    // output normalization percentile control, the peak being the
    // 1 - peak_clip / 1e6 percentile of the absolute signal
    int peak_clip;  // 10

    // audio output format: "mp3", "wav16", "wav24", "wav32"
    std::string output_format;

    // MP3 encoder bitrate in kbps, used when output_format is "mp3".
    // WAV outputs ignore this field.
    int mp3_bitrate;  // 128

    // adapters merged into the backbone for this request, applied in order.
    // "adapter" and "adapter_scale" are read too, as a one entry list.
    std::vector<Yue2RequestAdapter> adapters;  // []

    // sections of the lyrics revealed as the score reaches them; needs a
    // supplied score, one prompt for every song and no guidance
    Yue2LyricSchedule lyric_schedule;  // off

    // chord variety and section order of a planned score, see harmony.h;
    // "harmony": {"identity": "root"|"spelling", "strength", "window",
    // "hold_limit", "outside_bonus", "outside_limit", "section_strength",
    // "section_open", "follow": ["intro", "verse", ...]}
    Yue2Harmony harmony;  // off
};

// fills every field with its default
void request_init(Yue2Request * r);

// parses a JSON string, missing fields keep their default
bool request_parse_json(Yue2Request * r, const char * json);

// parses a JSON file, missing fields keep their default
bool request_parse(Yue2Request * r, const char * path);

// serializes, sparse skips the fields left at their default
std::string request_to_json(const Yue2Request * r, bool sparse = true);

// resolves a negative seed to a random positive one
void request_resolve_seed(Yue2Request * r);

// the request that renders one track of a batch again without the
// autoregression: its score, its semantic stream and the two seeds it consumed
Yue2Request request_replay(const Yue2Request & base,
                           const std::string & abc,
                           const std::string & tokens,
                           int                 song,
                           int                 variation);
