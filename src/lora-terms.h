#pragma once
// lora-terms.h: LoRA terms merged into the weights of a GGUF model at load
//
// A model built on another one (SheetSage2 and the audio tokenizer on MERT)
// carries LoRA factors for its base; the terms land on the staged PendingCopy
// of each tensor between the GGUF loads and wctx_alloc, so fused projections
// concatenate adapted rows. Per tensor: the base dequantized on the host,
// every term summed in one backend graph, the sum quantized back to the GGUF
// type on the host. Request adapters go through adapter.h.

#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml.h"
#include "gguf-weights.h"
#include "weight-ctx.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

enum LoraTermRole {
    LORA_TERM_A,     // a LoRA pair: A [rank, in], B [out, rank]
    LORA_TERM_DIFF,  // W += s * D
    LORA_TERM_FULL,  // W += s * (F - W)
};

// s without the prefix, false when s does not start with it
static bool lora_strip(std::string * s, const char * prefix) {
    size_t n = strlen(prefix);
    if (s->compare(0, n, prefix) != 0) {
        return false;
    }
    s->erase(0, n);
    return true;
}

// s without the suffix, false when s does not end with it
static bool lora_cut(std::string * s, const char * suffix) {
    size_t n = strlen(suffix);
    if (s->size() < n || s->compare(s->size() - n, n, suffix) != 0) {
        return false;
    }
    s->resize(s->size() - n);
    return true;
}

struct LoraTensor {
    const void *   data;
    enum ggml_type type;
    int64_t        ne0, ne1;
};

// One term on one GGUF tensor
struct LoraTerm {
    LoraTermRole   role;  // LORA_TERM_A for a LoRA pair, LORA_TERM_DIFF, LORA_TERM_FULL
    LoraTensor a;     // A [rank, in], or D, or F
    LoraTensor b;     // B [out, rank], rows [row0, row0 + rows) land on the tensor
    int64_t       row0;
    float         scale;
};

// The terms of a merge, by GGUF tensor name
using LoraTerms = std::map<std::string, std::vector<LoraTerm>>;

// Elements [first, first + n) of a term tensor as F32
static void lora_f32(const LoraTensor & t, int64_t first, int64_t n, float * dst) {
    const uint8_t * src = (const uint8_t *) t.data + first * ggml_type_size(t.type);
    if (t.type == GGML_TYPE_F32) {
        memcpy(dst, src, (size_t) n * 4);
    } else {
        ggml_get_type_traits(t.type)->to_float(src, dst, n);
    }
}

// Runs fn(r0, r1) over row ranges on every hardware thread
template <typename F> static void lora_rows(int64_t nrows, F fn) {
    int64_t                  n     = std::min<int64_t>(std::max(1u, std::thread::hardware_concurrency()), nrows);
    int64_t                  chunk = (nrows + n - 1) / n;
    std::vector<std::thread> threads;
    for (int64_t r0 = 0; r0 < nrows; r0 += chunk) {
        threads.emplace_back(fn, r0, std::min(nrows, r0 + chunk));
    }
    for (auto & t : threads) {
        t.join();
    }
}

// Sums the terms into the staged copy of one GGUF tensor
static bool lora_merge_tensor(WeightCtx *                      wctx,
                                 WeightCtx::PendingCopy *         pc,
                                 const struct ggml_tensor *       meta,
                                 const std::vector<LoraTerm> & terms,
                                 ggml_backend_t                   backend) {
    const int64_t        ne0  = meta->ne[0];
    const int64_t        ne1  = ggml_nrows(meta);
    const enum ggml_type type = meta->type;
    const size_t         row  = ggml_row_size(type, ne0);

    std::vector<float> base((size_t) (ne0 * ne1));
    if (type == GGML_TYPE_F32) {
        memcpy(base.data(), pc->src, base.size() * 4);
    } else {
        const auto * traits = ggml_get_type_traits(type);
        lora_rows(ne1, [&](int64_t r0, int64_t r1) {
            traits->to_float((const uint8_t *) pc->src + r0 * row, base.data() + r0 * ne0, (r1 - r0) * ne0);
        });
    }

    size_t                  n_inputs = 1 + 2 * terms.size();
    struct ggml_init_params params   = {
        (n_inputs + 4 * terms.size() + 2) * ggml_tensor_overhead() + ggml_graph_overhead(), NULL, true
    };
    struct ggml_context * ctx = ggml_init(params);
    struct ggml_tensor *  w   = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, ne0, ne1);
    struct ggml_tensor *  out = w;

    // Host data per input, uploaded once the context is allocated
    std::vector<std::pair<struct ggml_tensor *, std::vector<float>>> inputs;
    for (const LoraTerm & t : terms) {
        if (t.role == LORA_TERM_A) {
            const int64_t      rank = t.a.ne1;
            std::vector<float> a((size_t) (rank * ne0));
            std::vector<float> at(a.size());
            std::vector<float> b((size_t) (ne1 * rank));
            lora_f32(t.a, 0, rank * ne0, a.data());
            lora_f32(t.b, t.row0 * rank, ne1 * rank, b.data());
            for (int64_t r = 0; r < rank; r++) {
                for (int64_t i = 0; i < ne0; i++) {
                    at[i * rank + r] = a[r * ne0 + i];
                }
            }
            struct ggml_tensor * ta = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, rank, ne0);
            struct ggml_tensor * tb = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, rank, ne1);
            inputs.push_back({ ta, std::move(at) });
            inputs.push_back({ tb, std::move(b) });
            out = ggml_add(ctx, out, ggml_scale(ctx, ggml_mul_mat(ctx, ta, tb), t.scale));
        } else {
            std::vector<float> d((size_t) (ne0 * ne1));
            lora_f32(t.a, 0, ne0 * ne1, d.data());
            struct ggml_tensor * td = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, ne0, ne1);
            inputs.push_back({ td, std::move(d) });
            struct ggml_tensor * delta = t.role == LORA_TERM_DIFF ? td : ggml_sub(ctx, td, w);
            out                        = ggml_add(ctx, out, ggml_scale(ctx, delta, t.scale));
        }
    }

    struct ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, out);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(ctx, backend);
    if (!buf) {
        fprintf(stderr, "[LoRA] FATAL: cannot allocate the merge graph\n");
        ggml_free(ctx);
        return false;
    }
    ggml_backend_tensor_set(w, base.data(), 0, base.size() * 4);
    for (auto & in : inputs) {
        ggml_backend_tensor_set(in.first, in.second.data(), 0, in.second.size() * 4);
    }
    ggml_backend_graph_compute(backend, gf);
    ggml_backend_tensor_get(out, base.data(), 0, base.size() * 4);
    ggml_backend_buffer_free(buf);
    ggml_free(ctx);

    wctx->staging.emplace_back(new float[(pc->nbytes + 3) / 4]);
    uint8_t * dst = (uint8_t *) wctx->staging.back().get();
    if (type == GGML_TYPE_F32) {
        memcpy(dst, base.data(), pc->nbytes);
    } else {
        ggml_quantize_init(type);
        lora_rows(ne1, [&](int64_t r0, int64_t r1) {
            ggml_quantize_chunk(type, base.data(), dst, r0 * ne0, r1 - r0, ne0, NULL);
        });
    }
    pc->src = dst;
    return true;
}

// Sums every term into the staged copy of its GGUF tensor, between the GGUF
// loads of a model and its wctx_alloc
static bool lora_terms_apply(WeightCtx * wctx, const GGUFModel & gf, ggml_backend_t backend, const LoraTerms & terms) {
    std::unordered_map<const void *, size_t> staged;
    for (size_t i = 0; i < wctx->pending.size(); i++) {
        staged[wctx->pending[i].src] = i;
    }
    for (const auto & kv : terms) {
        const struct ggml_tensor * meta = ggml_get_tensor(gf.meta, kv.first.c_str());
        if (!meta) {
            fprintf(stderr, "[LoRA] FATAL: %s is not in the GGUF\n", kv.first.c_str());
            return false;
        }
        for (const LoraTerm & t : kv.second) {
            bool fits = t.role == LORA_TERM_A ?
                            t.a.ne0 == meta->ne[0] && t.b.ne0 == t.a.ne1 && t.row0 + ggml_nrows(meta) <= t.b.ne1 :
                            t.a.ne0 * t.a.ne1 == ggml_nelements(meta);
            if (!fits) {
                fprintf(stderr, "[LoRA] FATAL: a term does not fit %s\n", kv.first.c_str());
                return false;
            }
        }
        int64_t idx = gguf_find_tensor(gf.gguf, kv.first.c_str());
        auto    it  = staged.find(gf.mapping + gf.data_offset + gguf_get_tensor_offset(gf.gguf, idx));
        if (it == staged.end()) {
            fprintf(stderr, "[LoRA] FATAL: %s is not staged by this model\n", kv.first.c_str());
            return false;
        }
        if (!lora_merge_tensor(wctx, &wctx->pending[it->second], meta, kv.second, backend)) {
            return false;
        }
    }
    return true;
}
