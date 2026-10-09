// test-harmony: chord variety and section order of the planned score, pure CPU,
// on a toy vocabulary.

#include "harmony.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;

static void check(bool ok, const char * what) {
    if (!ok) {
        fprintf(stderr, "[ERROR] %s\n", what);
        failures++;
    }
}

static bool near(float a, float b) {
    return std::fabs(a - b) < 1e-4f;
}

static const std::vector<std::string> VOCAB = {
    "K:C\n", "K:Em\n", "% verse\n", "% chorus\n", "\"C\"", "\"G\"", "\"F#\"", "\"Am\"", "z16|", "\n",
    "%",     " ch",    "orus\n",    " verse\n",   "\"",    "C",     "G",      "x",
};

static int id_of(const std::string & text) {
    for (int i = 0; i < (int) VOCAB.size(); i++) {
        if (VOCAB[(size_t) i] == text) {
            return i;
        }
    }
    return -1;
}

static void feed(const Yue2HarmonyPlan & plan, Yue2HarmonyState * st, std::vector<int> * tokens,
                 std::initializer_list<const char *> texts) {
    for (const char * t : texts) {
        tokens->push_back(id_of(t));
    }
    yue2_harmony_feed(plan, st, *tokens);
}

int main() {
    const int END = (int) VOCAB.size();

    {  // the key of the K: line
        check(yue2_key_scale("X:1\nK:Em\n") == (1 << 4 | 1 << 6 | 1 << 7 | 1 << 9 | 1 << 11 | 1 << 0 | 1 << 2),
              "E minor scale");
        check(yue2_key_scale("K:Cmaj\n") == (1 << 0 | 1 << 2 | 1 << 4 | 1 << 5 | 1 << 7 | 1 << 9 | 1 << 11),
              "Cmaj is major");
        check(yue2_key_scale("K:Em") == -1, "an unfinished K: line is no key yet");
    }
    {  // a chord's share of the recent changes, holding free up to the limit
        Yue2Harmony h;
        h.strength          = 4.0f;
        Yue2HarmonyPlan  plan = yue2_harmony_plan(h, &VOCAB, END);
        Yue2HarmonyState st;
        std::vector<int> tokens;
        feed(plan, &st, &tokens, { "K:C\n", "\"C\"", "z16|", "\"G\"", "z16|", "\"C\"", "z16|", "\"G\"", "z16|" });
        check(st.changes.size() == 4, "four changes");
        check(near(yue2_harmony_cost(plan, &st, "\"C\""), 2.0f), "C holds half the changes");
        check(near(yue2_harmony_cost(plan, &st, "\"G\""), 0.0f), "staying on G is free");
        check(near(yue2_harmony_cost(plan, &st, "z16|"), 0.0f), "a token without a chord costs nothing");
        check(near(yue2_harmony_cost(plan, &st, "\"Am\""), 0.0f), "a chord not heard costs nothing");
    }
    {  // past the hold limit, staying costs more with every symbol
        Yue2Harmony h;
        h.strength          = 4.0f;
        h.hold_limit        = 2;
        Yue2HarmonyPlan  plan = yue2_harmony_plan(h, &VOCAB, END);
        Yue2HarmonyState st;
        std::vector<int> tokens;
        feed(plan, &st, &tokens, { "\"C\"", "\"C\"" });
        check(near(yue2_harmony_cost(plan, &st, "\"C\""), 1.0f), "first symbol past the limit");
        feed(plan, &st, &tokens, { "\"C\"" });
        check(near(yue2_harmony_cost(plan, &st, "\"C\""), 2.0f), "second symbol past the limit");
    }
    {  // a root outside the key gains, until enough changes are outside already
        Yue2Harmony h;
        h.outside_bonus     = 3.0f;
        h.outside_limit     = 0.25f;
        Yue2HarmonyPlan  plan = yue2_harmony_plan(h, &VOCAB, END);
        Yue2HarmonyState st;
        std::vector<int> tokens;
        feed(plan, &st, &tokens, { "K:C\n", "\"C\"", "\"G\"" });
        check(near(yue2_harmony_cost(plan, &st, "\"F#\""), -3.0f), "F# outside C major gains");
        check(near(yue2_harmony_cost(plan, &st, "\"Am\""), 0.0f), "Am in the key gains nothing");
        feed(plan, &st, &tokens, { "\"F#\"" });
        check(near(yue2_harmony_cost(plan, &st, "\"F#\""), 0.0f), "a third of the changes outside stops it");
    }
    {  // a section may not open the way the one before did
        Yue2Harmony h;
        h.section_strength  = 5.0f;
        Yue2HarmonyPlan  plan = yue2_harmony_plan(h, &VOCAB, END);
        Yue2HarmonyState st;
        std::vector<int> tokens;
        feed(plan, &st, &tokens, { "% verse\n", "\"C\"", "\"G\"", "\n", "% chorus\n" });
        check(st.section_count == 2 && st.previous == std::vector<int>({ 0, 7 }), "the verse opened C G");
        check(near(yue2_harmony_cost(plan, &st, "\"C\""), 5.0f), "the chorus may not open on C");
        check(near(yue2_harmony_cost(plan, &st, "\"Am\""), 0.0f), "Am is free");
        feed(plan, &st, &tokens, { "\"Am\"" });
        check(near(yue2_harmony_cost(plan, &st, "\"G\""), 5.0f), "nor move to G second");
        check(near(yue2_harmony_cost(plan, &st, "\"Am\""), 0.0f), "holding Am is free");
    }
    {  // the structure: the next name after "%", no "%" past the list, no end before it is done
        Yue2Harmony h;
        h.follow            = { "verse", "chorus" };
        Yue2HarmonyPlan  plan = yue2_harmony_plan(h, &VOCAB, END);
        Yue2HarmonyState st;
        std::vector<int> tokens;
        std::vector<float> logits((size_t) END + 1, 0.0f), out;
        feed(plan, &st, &tokens, { "% verse\n", "\"C\"", "\n", "%" });
        check(yue2_harmony_apply(plan, &st, logits.data(), END + 1, 64, &out), "the structure steers");
        check(near(out[(size_t) id_of(" ch")], YUE2_FOLLOW_BOOST), "\" ch\" spells the chorus");
        check(near(out[(size_t) id_of(" verse\n")], 0.0f), "\" verse\" is not next");
        check(near(out[(size_t) END], -YUE2_FOLLOW_BOOST), "no end with the chorus missing");
        feed(plan, &st, &tokens, { " ch", "orus\n", "\"C\"", "\"G\"", "\"C\"", "\"G\"", "\n" });
        check(st.section_count == 2 && st.section_chords == 4, "the chorus has four chords");
        check(yue2_harmony_apply(plan, &st, logits.data(), END + 1, 64, &out), "a further section is barred");
        check(near(out[(size_t) id_of("%")], -YUE2_FOLLOW_BOOST), "no third \"%\" line");
        check(near(out[(size_t) END], 0.0f), "the plan may end");
    }
    {  // off changes nothing
        Yue2HarmonyPlan    plan = yue2_harmony_plan(Yue2Harmony(), &VOCAB, END);
        Yue2HarmonyState   st;
        std::vector<int>   tokens;
        std::vector<float> logits((size_t) END + 1, 0.0f), out;
        feed(plan, &st, &tokens, { "\"C\"", "\"C\"" });
        check(!yue2_harmony_apply(plan, &st, logits.data(), END + 1, 64, &out), "off leaves the logits alone");
    }
    {  // the bounds of a request
        Yue2Harmony h;
        check(yue2_harmony_valid(h), "defaults are valid");
        h.follow = { "pre-chorus", "verse 2" };
        check(yue2_harmony_valid(h), "names with '-' and spaces");
        h.follow = { "verse\n" };
        check(!yue2_harmony_valid(h), "a newline is no name");
        h.follow.clear();
        h.strength = 65.0f;
        check(!yue2_harmony_valid(h), "strength over 64");
    }

    if (failures) {
        fprintf(stderr, "[ERROR] %d checks failed\n", failures);
        return 1;
    }
    fprintf(stderr, "[OK] test-harmony\n");
    return 0;
}
