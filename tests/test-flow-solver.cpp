// test-flow-solver: the flow matching steppers on analytic fields, pure CPU.
// x -= v(x, t) dt with t from 1 to 0; with v = -x the state ends at x0 * e,
// with v = -2t it ends at x0 + 1, with v = c at x0 - c.

#include "flow-solver.h"

#include <cmath>
#include <cstdio>

static int failures = 0;

static void check(bool ok, const char * what) {
    if (!ok) {
        fprintf(stderr, "[ERROR] %s\n", what);
        failures++;
    }
}

template <typename Field> static double solved(Yue2Solver solver, int steps, Field field, int * evaluations) {
    float x     = 1.0f;
    int   count = 0;
    yue2_flow_solve(
        &x, 1, steps, solver,
        [&](const float * at, float t, float * out) {
            count++;
            out[0] = field(at[0], t);
            return true;
        },
        [](int, const float *) { return true; });
    *evaluations = count;
    return x;
}

int main() {
    auto exponential = [](float x, float) { return -x; };
    auto timed       = [](float, float t) { return -2.0f * t; };
    auto constant    = [](float, float) { return 0.25f; };
    int  evals       = 0;

    check(std::fabs(solved(YUE2_SOLVER_AB2, 16, constant, &evals) - 0.75) < 1e-5, "a constant field is exact");
    check(evals == 17, "ab2 spends S + 1 evaluations");
    solved(YUE2_SOLVER_MIDPOINT, 16, constant, &evals);
    check(evals == 32, "midpoint spends 2S evaluations");
    check(yue2_solver_evaluations(YUE2_SOLVER_AB2, 32) == 33 && yue2_solver_evaluations(YUE2_SOLVER_MIDPOINT, 32) == 64,
          "the evaluation count");

    for (Yue2Solver solver : { YUE2_SOLVER_MIDPOINT, YUE2_SOLVER_AB2 }) {
        double e16 = std::fabs(solved(solver, 16, exponential, &evals) - std::exp(1.0));
        double e32 = std::fabs(solved(solver, 32, exponential, &evals) - std::exp(1.0));
        double t16 = std::fabs(solved(solver, 16, timed, &evals) - 2.0);
        check(e16 < 5e-3, "the exponential lands near x0 e");
        check(e16 / e32 > 3.0 && e16 / e32 < 5.0, "halving the step quarters the error: second order");
        check(t16 < 1e-4, "a field of t alone is integrated to second order");
        printf("%s: error 16 steps %.2e, 32 steps %.2e, ratio %.2f\n", solver == YUE2_SOLVER_AB2 ? "ab2" : "midpoint",
               e16, e32, e16 / e32);
    }
    Yue2Solver parsed;
    check(yue2_solver_parse("ab2", &parsed) && parsed == YUE2_SOLVER_AB2, "ab2 parses");
    check(!yue2_solver_parse("euler", &parsed), "an unknown solver is refused");
    if (failures) {
        fprintf(stderr, "[ERROR] %d checks failed\n", failures);
        return 1;
    }
    fprintf(stderr, "[OK] test-flow-solver\n");
    return 0;
}
