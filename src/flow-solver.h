// flow-solver.h: the flow matching ODE stepper of the acoustic stage
//
// t walks from 1 down to 0 in uniform steps and the state follows
// x -= v(x, t) dt. Two solvers:
//   midpoint  two velocity evaluations a step, the reference's
//   ab2       Adams-Bashforth of the second order: the first step is a
//             midpoint step, every later one evaluates the velocity once and
//             reuses the one before, x -= dt (1.5 v_n - 0.5 v_{n-1}); S + 1
//             evaluations for S steps instead of 2S (after Riff)
// The velocity is a callback, so the network and an analytic field share
// one stepper.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

enum Yue2Solver {
    YUE2_SOLVER_MIDPOINT = 0,
    YUE2_SOLVER_AB2      = 1,
};

static bool yue2_solver_parse(const std::string & name, Yue2Solver * out) {
    if (name == "midpoint") {
        *out = YUE2_SOLVER_MIDPOINT;
        return true;
    }
    if (name == "ab2") {
        *out = YUE2_SOLVER_AB2;
        return true;
    }
    return false;
}

// Velocity evaluations a solver spends on a number of steps
static int yue2_solver_evaluations(Yue2Solver solver, int steps) {
    return solver == YUE2_SOLVER_AB2 ? steps + 1 : 2 * steps;
}

// Integrates state[count] over steps. velocity(x, t, out) writes v at x and t;
// stepped(step, v_used) runs after each step for logging. Returns false when a
// callback does.
template <typename Velocity, typename Stepped>
static bool yue2_flow_solve(float *    state,
                            size_t     count,
                            int        steps,
                            Yue2Solver solver,
                            Velocity   velocity,
                            Stepped    stepped) {
    std::vector<float> first(count), mid(count), second(count), previous;
    const float        dt = 1.0f / (float) steps;
    for (int step = 0; step < steps; step++) {
        const float t = 1.0f - (float) step * dt;
        if (!velocity(state, t, first.data())) {
            return false;
        }
        if (solver == YUE2_SOLVER_AB2 && step > 0) {
            for (size_t i = 0; i < count; i++) {
                state[i] -= dt * (1.5f * first[i] - 0.5f * previous[i]);
            }
            previous.swap(first);
            if (!stepped(step, previous.data())) {
                return false;
            }
            continue;
        }
        for (size_t i = 0; i < count; i++) {
            mid[i] = state[i] - first[i] * (dt * 0.5f);
        }
        if (!velocity(mid.data(), t - dt * 0.5f, second.data())) {
            return false;
        }
        for (size_t i = 0; i < count; i++) {
            state[i] -= second[i] * dt;
        }
        if (solver == YUE2_SOLVER_AB2) {
            previous = first;
        }
        if (!stepped(step, second.data())) {
            return false;
        }
    }
    return true;
}
