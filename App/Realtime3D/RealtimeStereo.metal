//
//  RealtimeStereo.metal
//  the 3D pipeline – real-time 2D → 3D
//
//  One Depth Anything V2 prediction per converted frame drives a pure GPU
//  view synthesis. Both eyes are resampled from the full-resolution source
//  planes, so 8/10-bit YCbCr and PQ/HLG transfer functions pass through
//  untouched; nothing is generated at model resolution.
//
//  Pass order (one serial command queue):
//    rs_prepare      source → 518×392 model input (display-referred sRGB)
//    rs_analyze      robust depth range, letterbox bars, scene-cut test
//    rs_normalize    percentile-normalised depth + cut-aware temporal filter
//    rs_upsample     joint-bilateral upsample onto the working grid, snapping
//                    depth edges to the full-resolution colour edges
//    rs_dilate       horizontal slope-limited dilation: foreground plateaus
//                    stay rigid, every depth step becomes a background ramp
//    rs_inverse_map  per-eye source offsets by fixed-point inversion
//    rs_warp         per-plane Catmull-Rom resample, both eyes at once
//
//  Because the dilated depth is slope limited, x = u ± S(u) is strictly
//  monotonic on every row: each output pixel has exactly one source pixel.
//  There are no disocclusion holes to fill and no folds to resolve, which is
//  what keeps silhouettes free of the smeared halo of hole-filling converters.
//  The only deformation is a short stretch/squeeze of background texture next
//  to depth edges, never foreground colour dragged onto the background.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared layouts (mirrored in LSRealtimeStereoRenderer.swift)

struct RSColorParams {
    /// x = luma black, y = luma gain, z = chroma zero, w = chroma gain
    /// (chroma gain maps the excursion to ±0.5).
    float4 range;
    /// x = Kr, y = Kb, z = transfer (0 SDR/HLG, 1 PQ, 2 linear), w = unused.
    float4 matrix;
};

struct RSPrepareParams {
    /// Model-space pixels covered by the picture: x, y, width, height.
    float4 contentRect;
    /// Box-filter taps per model texel (anti-aliased downscale).
    uint2 taps;
    uint2 reserved;
};

struct RSAnalyzeParams {
    int4 contentRect;
    uint forceReset;
    float cutThreshold;
    float minimumRange;
    float smoothing;
    /// RSA_ANALYZE_* 位标志。
    uint flags;
};

/// 分析标志：两级切镜（方案 3/4/5）。关闭时按单一亮度阈值判切（老链路）。
#define RSA_ANALYZE_TWO_STAGE_CUT 1u

/// 切镜重置位：TEXEL = 重置逐 texel 时间平均（jump）；RANGE = 重置量程平滑
/// （confirmed）。
#define RSA_CUT_TEXEL 1u
#define RSA_CUT_RANGE 2u

#define RS_CUT_GRID 16
#define RS_CUT_BINS 16

/// 两级切镜阈值（the 3D pipeline 的原值，见 depthCutStep）。
struct RSCutParams {
    float jumpDiff;
    float jumpHist;
    float sameDiff;
    float sameHist;
    float correlationMax;
    float standOut;
    float twoBack;
    float flat;
};

struct RSCutThumb {
    float grid[RS_CUT_GRID * RS_CUT_GRID];
    float histogram[RS_CUT_BINS];
};

/// 两级切镜的两帧历史与状态机（他们的 DepthCut）。
struct RSCutState {
    RSCutThumb current;
    RSCutThumb last;
    RSCutThumb older;
    RSCutThumb before;
    float lastDiff;
    float settledDiff;
    float jumpDiff;
    float jumpHist;
    float twoBackDiff;
    uint haveLast;
    uint haveOlder;
    uint lastJumped;
    uint pending;
};

/// 归一化参数：老链路按像素变化加权（changeSigma）；方案 3/4/5 用真实时间一阶
/// 平均 α = 1 − e^(−dt/τ)（temporalAlpha 由 CPU 按时间戳算好传入）。
struct RSNormalizeParams {
    float temporalAlpha;
    float changeSigma;
    uint flags;
    uint reserved;
};

#define RSA_NORMALIZE_TIME_TAU 1u

struct RSAnalysisState {
    float lo;
    float hi;
    float sceneDelta;
    /// 有任一重置（jump / confirmed / 老链路判切）时为 1。
    uint cut;
    /// Active picture without letterbox bars: x0, y0, x1, y1 (exclusive).
    int4 active;
    uint frames;
    /// RSA_CUT_*：本张预测触发的重置位（两级切镜时区分 jump 与 confirmed）。
    uint cutFlags;
    uint reserved1;
    uint reserved2;
};

struct RSUpsampleParams {
    float4 contentRect;
    /// Source-uv footprint of one working texel.
    float2 footprint;
    float rangeSigma;
    float spatialSigma;
};

struct RSStereoParams {
    /// Per-eye shift per unit of normalised depth, in normalised width.
    float amplitude;
    /// Zero-parallax depth.
    float convergence;
    /// Maximum depth change per working texel after dilation（老链路用；
    /// 可见性 gather 不用膨胀，此位闲置）。
    float slope;
    /// 老链路：膨胀半径；可见性 gather：逐行搜索半径（texel）。
    int radius;
    /// Disparity fades to zero this close to the left/right picture edge.
    float edgeMargin;
    /// 老链路：固定点迭代次数。
    uint iterations;
    /// RSA_REFINE_*：牛顿精修步数（0 = 不做精修）。
    uint refineSteps;
    /// RSA_FLAG_* 位标志。
    uint flags;
};

/// 精修时深度沿行用三次 B 样条读（复刻 the 3D pipeline 的低分辨率深度读取），
/// 否则线性。
#define RSA_FLAG_CUBIC_DEPTH 1u

constant bool rsSourceIsRGBA [[function_constant(0)]];

constexpr sampler rsLinear(coord::normalized, address::clamp_to_edge, filter::linear);

#define RS_HISTOGRAM_BINS 512
#define RS_MAX_MODEL_SIDE 1024
#define RS_MAX_ANALYZE_THREADS 1024

// MARK: - Colour helpers

inline float rs_luma(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

/// SMPTE ST 2084 to a display-referred SDR rendition for the depth model.
/// 203 nits becomes reference white; highlights roll off smoothly.
inline float3 rs_pq_to_sdr(float3 encoded) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    float3 p = pow(max(encoded, 0.0), 1.0 / m2);
    float3 linear = pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    float3 y = linear * (10000.0 / 203.0);
    y = y * (1.0 + y / 16.0) / (1.0 + y);
    return pow(saturate(y), 1.0 / 2.2);
}

inline float3 rs_display_rgb(float3 rgb, float transfer) {
    if (transfer > 0.5 && transfer < 1.5) {
        return rs_pq_to_sdr(rgb);
    }
    if (transfer > 1.5) {
        return pow(saturate(rgb), 1.0 / 2.2);
    }
    return saturate(rgb);
}

inline float3 rs_source_rgb(texture2d<float, access::sample> plane0,
                            texture2d<float, access::sample> plane1,
                            float2 uv,
                            constant RSColorParams &color) {
    float3 rgb;
    if (rsSourceIsRGBA) {
        rgb = plane0.sample(rsLinear, uv).rgb;
    } else {
        float y = (plane0.sample(rsLinear, uv).r - color.range.x) * color.range.y;
        float2 c = (plane1.sample(rsLinear, uv).rg - color.range.z) * color.range.w;
        float kr = color.matrix.x;
        float kb = color.matrix.y;
        float r = y + 2.0 * (1.0 - kr) * c.y;
        float b = y + 2.0 * (1.0 - kb) * c.x;
        float g = (y - kr * r - kb * b) / (1.0 - kr - kb);
        rgb = float3(r, g, b);
    }
    return rs_display_rgb(rgb, color.matrix.z);
}

// MARK: - Model input

kernel void rs_prepare(texture2d<float, access::sample> plane0 [[texture(0)]],
                       texture2d<float, access::sample> plane1 [[texture(1)]],
                       texture2d<float, access::write> modelInput [[texture(2)]],
                       constant RSColorParams &color [[buffer(0)]],
                       constant RSPrepareParams &params [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= modelInput.get_width() || gid.y >= modelInput.get_height()) {
        return;
    }
    float2 position = float2(gid) + 0.5;
    float4 rect = params.contentRect;
    if (position.x < rect.x || position.y < rect.y ||
        position.x > rect.x + rect.z || position.y > rect.y + rect.w) {
        modelInput.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }
    float2 uv = (position - rect.xy) / rect.zw;
    float2 footprint = 1.0 / rect.zw;
    uint2 taps = max(params.taps, uint2(1));
    float3 sum = 0.0;
    for (uint j = 0; j < taps.y; ++j) {
        for (uint i = 0; i < taps.x; ++i) {
            float2 offset = (float2(i, j) + 0.5) / float2(taps) - 0.5;
            sum += rs_source_rgb(plane0, plane1, saturate(uv + offset * footprint), color);
        }
    }
    modelInput.write(float4(sum / float(taps.x * taps.y), 1.0), gid);
}

inline float rs_cut_diff(RSCutThumb a, RSCutThumb b) {
    float sum = 0.0;
    for (uint i = 0; i < RS_CUT_GRID * RS_CUT_GRID; ++i) {
        sum += abs(a.grid[i] - b.grid[i]);
    }
    return sum / float(RS_CUT_GRID * RS_CUT_GRID);
}

inline float rs_cut_hist_diff(RSCutThumb a, RSCutThumb b) {
    float sum = 0.0;
    for (uint i = 0; i < RS_CUT_BINS; ++i) {
        sum += abs(a.histogram[i] - b.histogram[i]);
    }
    return 0.5 * sum;
}

/// 格均值的皮尔逊相关；任一帧近似平铺时返回 0（他们同规则）。
inline float rs_cut_correlation(RSCutThumb a, RSCutThumb b, float flat) {
    const uint count = RS_CUT_GRID * RS_CUT_GRID;
    float ma = 0.0, mb = 0.0;
    for (uint i = 0; i < count; ++i) {
        ma += a.grid[i];
        mb += b.grid[i];
    }
    ma /= float(count);
    mb /= float(count);
    float ab = 0.0, aa = 0.0, bb = 0.0;
    for (uint i = 0; i < count; ++i) {
        const float x = a.grid[i] - ma;
        const float y = b.grid[i] - mb;
        ab += x * y;
        aa += x * x;
        bb += y * y;
    }
    if (aa < flat * float(count) || bb < flat * float(count)) {
        return 0.0;
    }
    return ab / sqrt(max(aa * bb, 1.0e-12));
}

/// 两级切镜的状态机（对照 the 3D pipeline 的 depthCutStep）。
/// jump：格均值差或直方图差超过阈值 → 重置逐 texel 时间平均。
/// confirmed：跳变后的下一张与跳变帧「同」（差小于 same*）、与跳变前一帧「远」、
/// 两帧相关性低、跳变幅度显著（≥ standOut × 邻域差）且再前一帧不显著
/// （twoBackDiff ≤ twoBack × jumpDiff）→ 重置量程平滑。
/// 只在 tid 0 且屏障之后调用。
inline uint rs_cut_step(device RSCutState &c,
                        threadgroup const float *grid,
                        threadgroup const atomic_uint *histogram,
                        constant RSCutParams &p) {
    for (uint i = 0; i < RS_CUT_GRID * RS_CUT_GRID; ++i) {
        c.current.grid[i] = grid[i];
    }
    uint samples = 0;
    for (uint i = 0; i < RS_CUT_BINS; ++i) {
        samples += atomic_load_explicit(&histogram[i], memory_order_relaxed);
    }
    for (uint i = 0; i < RS_CUT_BINS; ++i) {
        c.current.histogram[i] = samples > 0
            ? float(atomic_load_explicit(&histogram[i], memory_order_relaxed)) / float(samples)
            : 0.0;
    }
    if (c.haveLast == 0) {
        c.last = c.current;
        c.haveLast = 1;
        c.haveOlder = 0;
        c.lastJumped = 0;
        c.pending = 0;
        c.lastDiff = 0.0;
        return 0;
    }
    const float diff = rs_cut_diff(c.current, c.last);
    const float histDiff = rs_cut_hist_diff(c.current, c.last);
    const bool jump = diff > p.jumpDiff || histDiff > p.jumpHist;
    uint result = jump ? RSA_CUT_TEXEL : 0u;

    if (c.pending != 0) {
        c.pending = 0;
        const float beforeDiff = rs_cut_diff(c.current, c.before);
        const float beforeHistDiff = rs_cut_hist_diff(c.current, c.before);
        const bool farFromBefore = beforeDiff > p.jumpDiff || beforeHistDiff > p.jumpHist;
        const bool nearLast = diff < p.sameDiff && histDiff < p.sameHist;
        const float corr = rs_cut_correlation(c.last, c.before, p.flat);
        const float around = max(c.settledDiff, diff);
        if (farFromBefore && nearLast && corr < p.correlationMax &&
            c.jumpDiff >= p.standOut * around && c.twoBackDiff <= p.twoBack * c.jumpDiff) {
            result |= RSA_CUT_RANGE;
        }
    }
    // 只有「从没跳过的一张跳到」才挂起确认，不会在一次等待上再挂一次。
    if (jump && c.lastJumped == 0) {
        c.pending = 1;
        c.before = c.last;
        c.settledDiff = c.lastDiff;
        c.twoBackDiff = c.haveOlder != 0 ? rs_cut_diff(c.current, c.older) : diff;
        c.jumpDiff = diff;
        c.jumpHist = histDiff;
    }
    c.lastJumped = jump ? 1u : 0u;
    c.lastDiff = diff;
    c.older = c.last;
    c.haveOlder = 1;
    c.last = c.current;
    return result;
}


// MARK: - Depth statistics

/// Single threadgroup. Finds letterbox/pillarbox bars, the 2nd/98th depth
/// percentiles of the active picture and the mean luma change against the
/// previous inferred frame. A cut resets all temporal state immediately, so
/// a new shot never inherits the previous shot's depth range.
kernel void rs_analyze(texture2d<float, access::read> depthRaw [[texture(0)]],
                       texture2d<float, access::read> guide [[texture(1)]],
                       texture2d<float, access::read> guidePrevious [[texture(2)]],
                       device RSAnalysisState &state [[buffer(0)]],
                       constant RSAnalyzeParams &params [[buffer(1)]],
                       constant RSCutParams &cutParams [[buffer(2)]],
                       device RSCutState &cutState [[buffer(3)]],
                       uint tid [[thread_index_in_threadgroup]],
                       uint threads [[threads_per_threadgroup]]) {
    threadgroup atomic_uint histogram[RS_HISTOGRAM_BINS];
    threadgroup uchar darkRow[RS_MAX_MODEL_SIDE];
    threadgroup uchar darkColumn[RS_MAX_MODEL_SIDE];
    threadgroup float deltaSum[RS_MAX_ANALYZE_THREADS];
    threadgroup uint deltaCount[RS_MAX_ANALYZE_THREADS];
    threadgroup int4 activeBox[1];
    threadgroup float cutGrid[RS_CUT_GRID * RS_CUT_GRID];
    threadgroup atomic_uint cutHistogram[RS_CUT_BINS];

    const int4 rect = params.contentRect;
    const bool twoStageCut = (params.flags & RSA_ANALYZE_TWO_STAGE_CUT) != 0u;
    for (uint i = tid; i < RS_HISTOGRAM_BINS; i += threads) {
        atomic_store_explicit(&histogram[i], 0u, memory_order_relaxed);
    }
    if (twoStageCut) {
        for (uint i = tid; i < RS_CUT_BINS; i += threads) {
            atomic_store_explicit(&cutHistogram[i], 0u, memory_order_relaxed);
        }
    }
    for (int row = int(tid); row < rect.w; row += int(threads)) {
        float peak = 0.0;
        for (int x = 0; x < rect.z; x += 2) {
            peak = max(peak, rs_luma(guide.read(uint2(rect.x + x, rect.y + row)).rgb));
        }
        darkRow[row] = peak < 0.07 ? 1 : 0;
    }
    for (int column = int(tid); column < rect.z; column += int(threads)) {
        float peak = 0.0;
        for (int y = 0; y < rect.w; y += 2) {
            peak = max(peak, rs_luma(guide.read(uint2(rect.x + column, rect.y + y)).rgb));
        }
        darkColumn[column] = peak < 0.07 ? 1 : 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        int top = 0;
        while (top < rect.w && darkRow[top] != 0) { ++top; }
        int bottom = rect.w;
        while (bottom > top && darkRow[bottom - 1] != 0) { --bottom; }
        int left = 0;
        while (left < rect.z && darkColumn[left] != 0) { ++left; }
        int right = rect.z;
        while (right > left && darkColumn[right - 1] != 0) { --right; }
        // A dark frame or a mostly dark shot is not a letterbox.
        if (bottom - top < rect.w / 3 || right - left < rect.z / 3) {
            top = 0;
            bottom = rect.w;
            left = 0;
            right = rect.z;
        }
        activeBox[0] = int4(rect.x + left, rect.y + top, rect.x + right, rect.y + bottom);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const int4 box = activeBox[0];
    const uint boxWidth = uint(box.z - box.x);
    const uint count = boxWidth * uint(box.w - box.y);
    float delta = 0.0;
    uint samples = 0;
    for (uint i = tid; i < count; i += threads) {
        uint2 at = uint2(uint(box.x) + i % boxWidth, uint(box.y) + i / boxWidth);
        float value = clamp(depthRaw.read(at).r, 0.0, 1.0);
        uint bin = min(uint(value * float(RS_HISTOGRAM_BINS - 1) + 0.5), uint(RS_HISTOGRAM_BINS - 1));
        atomic_fetch_add_explicit(&histogram[bin], 1u, memory_order_relaxed);
        if ((i & 3u) == 0u) {
            delta += abs(rs_luma(guide.read(at).rgb) - rs_luma(guidePrevious.read(at).rgb));
            samples += 1;
        }
    }
    // 两级切镜的统计量：16×16 格均值（每格按 2×2 步长采样）与 16 桶亮度直方图
    // （画面内 64×64 稀疏网格）。软边内容上格均值足够稳定，且比全采样便宜。
    if (twoStageCut) {
        const uint cells = RS_CUT_GRID * RS_CUT_GRID;
        for (uint cell = tid; cell < cells; cell += threads) {
            const uint cx = cell % RS_CUT_GRID;
            const uint cy = cell / RS_CUT_GRID;
            const int x0 = rect.x + int(cx) * rect.z / RS_CUT_GRID;
            const int x1 = rect.x + int(cx + 1) * rect.z / RS_CUT_GRID;
            const int y0 = rect.y + int(cy) * rect.w / RS_CUT_GRID;
            const int y1 = rect.y + int(cy + 1) * rect.w / RS_CUT_GRID;
            float sum = 0.0;
            int cellCount = 0;
            for (int y = y0; y < y1; y += 2) {
                for (int x = x0; x < x1; x += 2) {
                    sum += rs_luma(guide.read(uint2(uint(x), uint(y))).rgb);
                    cellCount += 1;
                }
            }
            cutGrid[cell] = cellCount > 0 ? sum / float(cellCount) : 0.0;
        }
        const uint histogramStepX = uint(max(1, rect.z / 64));
        const uint histogramStepY = uint(max(1, rect.w / 64));
        for (uint i = tid; i < 64u * 64u; i += threads) {
            const uint x = min(uint(rect.x) + (i % 64u) * histogramStepX, uint(rect.x + rect.z - 1));
            const uint y = min(uint(rect.y) + (i / 64u) * histogramStepY, uint(rect.y + rect.w - 1));
            const float luma = rs_luma(guide.read(uint2(x, y)).rgb);
            const uint bin = min(uint(luma * float(RS_CUT_BINS)), uint(RS_CUT_BINS - 1));
            atomic_fetch_add_explicit(&cutHistogram[bin], 1u, memory_order_relaxed);
        }
    }

    deltaSum[tid] = delta;
    deltaCount[tid] = samples;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = threads / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            deltaSum[tid] += deltaSum[tid + stride];
            deltaCount[tid] += deltaCount[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid != 0) {
        return;
    }

    const float sceneDelta = deltaSum[0] / float(max(deltaCount[0], 1u));
    const uint lowTarget = uint(float(count) * 0.02);
    const uint highTarget = uint(float(count) * 0.98);
    uint running = 0;
    float lo = 0.0;
    float hi = 1.0;
    bool foundLow = false;
    for (uint bin = 0; bin < RS_HISTOGRAM_BINS; ++bin) {
        running += atomic_load_explicit(&histogram[bin], memory_order_relaxed);
        float value = float(bin) / float(RS_HISTOGRAM_BINS - 1);
        if (!foundLow && running > lowTarget) {
            lo = value;
            foundLow = true;
        }
        if (running >= highTarget) {
            hi = value;
            break;
        }
    }
    // Nearly flat shots keep a proportionally small depth range instead of
    // stretching model noise to full parallax.
    lo = min(lo, hi - params.minimumRange);

    uint cutFlags;
    if (twoStageCut) {
        cutFlags = rs_cut_step(cutState, cutGrid, cutHistogram, cutParams);
        // 强制重置（seek / 换布局 / 新时间线的第一张）：另一槽的深度属于旧时间线
        // 或未初始化，绝不能做时间混合。
        if (params.forceReset != 0u) {
            cutFlags |= RSA_CUT_TEXEL;
        }
    } else {
        const bool cut = params.forceReset != 0 || state.frames == 0 ||
            sceneDelta > params.cutThreshold;
        cutFlags = cut ? (RSA_CUT_TEXEL | RSA_CUT_RANGE) : 0u;
    }
    // 强制重置（seek / 换布局后的第一张）也让两级切镜的历史从这一张重新开始。
    if (params.forceReset != 0u && twoStageCut) {
        cutState.haveLast = 0;
        cutState.pending = 0;
    }
    if ((cutFlags & RSA_CUT_RANGE) != 0u || params.forceReset != 0u || state.frames == 0) {
        state.lo = lo;
        state.hi = hi;
        state.frames = 1;
    } else {
        state.lo = mix(state.lo, lo, params.smoothing);
        state.hi = mix(state.hi, hi, params.smoothing);
        state.frames = min(state.frames + 1, 1000000u);
    }
    state.sceneDelta = sceneDelta;
    state.cutFlags = cutFlags;
    state.cut = cutFlags != 0u ? 1u : 0u;
    state.active = box;
}

// MARK: - Normalisation

kernel void rs_normalize(texture2d<float, access::read> depthRaw [[texture(0)]],
                         texture2d<float, access::read> guide [[texture(1)]],
                         texture2d<float, access::read> guidePrevious [[texture(2)]],
                         texture2d<float, access::read> depthPrevious [[texture(3)]],
                         texture2d<float, access::write> depthOut [[texture(4)]],
                         device const RSAnalysisState &state [[buffer(0)]],
                         constant RSNormalizeParams &params [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= depthOut.get_width() || gid.y >= depthOut.get_height()) {
        return;
    }
    const int2 at = int2(gid);
    const bool inside = at.x >= state.active.x && at.y >= state.active.y &&
        at.x < state.active.z && at.y < state.active.w;
    float depth = 0.0;
    if (inside) {
        depth = saturate((depthRaw.read(gid).r - state.lo) / max(state.hi - state.lo, 1.0e-3));
        if ((params.flags & RSA_NORMALIZE_TIME_TAU) != 0u) {
            // 方案 3/4/5：真实时间一阶平均（他们的 tau）；jump 那一张（TEXEL）与
            // 量程刚换的那一张（RANGE）都不混合，避免跨量程混值。
            if ((state.cutFlags & (RSA_CUT_TEXEL | RSA_CUT_RANGE)) == 0u) {
                depth = mix(depth, depthPrevious.read(gid).r, saturate(params.temporalAlpha));
            }
        } else if (state.cut == 0) {
            // Only static pixels are averaged with the previous inference;
            // anything that moved or changed takes this frame's depth as is.
            float change = abs(rs_luma(guide.read(gid).rgb) - rs_luma(guidePrevious.read(gid).rgb));
            float keep = params.changeSigma > 0.0
                ? 0.5 * exp(-change * change / (2.0 * params.changeSigma * params.changeSigma))
                : 0.0;
            depth = mix(depth, depthPrevious.read(gid).r, keep);
        }
    }
    depthOut.write(float4(depth), gid);
}

// MARK: - Edge-aligned upsampling

kernel void rs_upsample(texture2d<float, access::sample> plane0 [[texture(0)]],
                        texture2d<float, access::sample> plane1 [[texture(1)]],
                        texture2d<float, access::read> depth [[texture(2)]],
                        texture2d<float, access::read> guide [[texture(3)]],
                        texture2d<float, access::write> depthOut [[texture(4)]],
                        constant RSColorParams &color [[buffer(0)]],
                        constant RSUpsampleParams &params [[buffer(1)]],
                        device const RSAnalysisState &state [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    const uint2 size = uint2(depthOut.get_width(), depthOut.get_height());
    if (gid.x >= size.x || gid.y >= size.y) {
        return;
    }
    const float2 uv = (float2(gid) + 0.5) / float2(size);
    const float2 quarter = params.footprint * 0.25;
    const float3 target = 0.25 * (
        rs_source_rgb(plane0, plane1, uv + float2(-quarter.x, -quarter.y), color) +
        rs_source_rgb(plane0, plane1, uv + float2(quarter.x, -quarter.y), color) +
        rs_source_rgb(plane0, plane1, uv + float2(-quarter.x, quarter.y), color) +
        rs_source_rgb(plane0, plane1, uv + float2(quarter.x, quarter.y), color));

    const float2 q = params.contentRect.xy + uv * params.contentRect.zw - 0.5;
    const int2 base = int2(floor(q));
    const float2 fraction = q - float2(base);
    const int2 lower = state.active.xy;
    const int2 upper = state.active.zw - 1;
    const float spatial = 1.0 / (2.0 * params.spatialSigma * params.spatialSigma);
    const float range = 1.0 / (2.0 * params.rangeSigma * params.rangeSigma);
    float sum = 0.0;
    float weightSum = 0.0;
    for (int j = -1; j <= 2; ++j) {
        for (int i = -1; i <= 2; ++i) {
            const uint2 tap = uint2(clamp(base + int2(i, j), lower, upper));
            const float2 distance = float2(i, j) - fraction;
            const float3 difference = guide.read(tap).rgb - target;
            const float ws = exp(-dot(distance, distance) * spatial);
            const float weight = ws * (exp(-dot(difference, difference) * range) + 1.0e-4);
            sum += weight * depth.read(tap).r;
            weightSum += weight;
        }
    }
    depthOut.write(float4(sum / max(weightSum, 1.0e-8)), gid);
}

// MARK: - Slope-limited dilation

/// D'(u) = max_j D(u + j) - slope * max(|j| - 1, 0), along the row only.
/// The one-texel flat core keeps every foreground edge pixel on its plateau;
/// the cone turns each depth step into a background-side ramp whose slope
/// guarantees a monotonic warp.
kernel void rs_dilate(texture2d<float, access::read> depth [[texture(0)]],
                      texture2d<float, access::write> depthOut [[texture(1)]],
                      constant RSStereoParams &params [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const int width = int(depth.get_width());
    if (int(gid.x) >= width || gid.y >= depth.get_height()) {
        return;
    }
    float result = depth.read(gid).r;
    for (int j = 1; j <= params.radius + 1; ++j) {
        const float falloff = params.slope * float(j - 1);
        if (1.0 - falloff <= result) {
            break;
        }
        const float leftValue = depth.read(uint2(max(int(gid.x) - j, 0), gid.y)).r;
        const float rightValue = depth.read(uint2(min(int(gid.x) + j, width - 1), gid.y)).r;
        result = max(result, max(leftValue, rightValue) - falloff);
    }
    depthOut.write(float4(result), gid);
}

// MARK: - Visibility-aware gather（the 3D pipeline 的做法）

/// 输出像素 x 处，源位置 t 落到这里的误差是 e(t) = (t - x) ± S(t)，
/// S(t) = A·edge(t)·(d(t) - convergence)（左眼取 +、右眼取 −，与老链路的
/// x = u ± S(u) 同一符号约定）。e 的每个变号区间都是「确实落到本像素」的一个
/// 源面；多于一个时取最近（深度最大）的那个，这就是遮挡。
///
/// 与限斜率膨胀 + 固定点迭代的区别：这里不改造深度，深度台阶处的遮挡关系由
/// 求解本身给出（背景不再被拉伸，但搜索半径随视差增长）。反向采样保证每个输出
/// 像素都有源，无空洞。
kernel void rs_gather(texture2d<float, access::read> depth [[texture(0)]],
                      texture2d<float, access::write> offsets [[texture(1)]],
                      constant RSStereoParams &params [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const int width = int(depth.get_width());
    if (int(gid.x) >= width || gid.y >= depth.get_height()) {
        return;
    }
    const float px = float(gid.x);
    const float edgeMargin = max(params.edgeMargin, 1.0e-6);
    const float amplitudeTexels = params.amplitude * float(width);
    const int reach = max(params.radius, 0);
    float result[2];
    for (int eye = 0; eye < 2; ++eye) {
        // 左眼 e = (t - x) + S(t)，右眼 e = (t - x) - S(t)。
        const float side = (eye == 0) ? 1.0 : -1.0;
        int bestIndex = 0;
        float bestFraction = 0.0;
        float bestDepth = -1.0;
        float previousE = 0.0;
        float previousDepth = 0.0;
        int previousIndex = 0;
        const int from = int(px) - reach;
        const int to = int(px) + reach;
        for (int i = from; i <= to; ++i) {
            // 位置用未夹取的 i（帧外由边缘淡出把视差压到 0），深度读夹取到帧内。
            const int clamped = clamp(i, 0, width - 1);
            const float d = depth.read(uint2(uint(clamped), gid.y)).r;
            const float position = (float(i) + 0.5) / float(width);
            const float edge = saturate(min(position, 1.0 - position) / edgeMargin);
            const float e = (float(i) - px) + side * amplitudeTexels * edge * (d - params.convergence);
            if (i > from) {
                const float span = e - previousE;
                if (previousE * e <= 0.0 && abs(span) > 1.0e-6) {
                    const float fraction = saturate(-previousE / span);
                    const float crossingDepth = mix(previousDepth, d, fraction);
                    if (crossingDepth > bestDepth) {
                        bestDepth = crossingDepth;
                        bestIndex = previousIndex;
                        bestFraction = fraction;
                    }
                }
            }
            previousE = e;
            previousDepth = d;
            previousIndex = clamped;
        }
        // 视差为 0 时过零点恒存在于像素自身（offset = 0）；这里的回退是防
        // 浮点退化，与「零视差 = 精确复制」的契约一致。
        const float offsetTexels = bestDepth > -0.5
            ? (float(bestIndex) + bestFraction) - px
            : 0.0;
        result[eye] = offsetTexels / float(width);
    }
    offsets.write(float4(result[0], result[1], 0.0, 0.0), gid);
}

/// 精修用的深度读：线性，或三次 B 样条（RSA_FLAG_CUBIC_DEPTH）。
inline float rs_depth_at(texture2d<float, access::sample> depth, float u, float v,
                         constant RSStereoParams &params) {
    if ((params.flags & RSA_FLAG_CUBIC_DEPTH) == 0u) {
        return depth.sample(rsLinear, float2(u, v)).r;
    }
    const float width = float(depth.get_width());
    const float position = u * width - 0.5;
    const float base = floor(position);
    const float t = position - base;
    const float t2 = t * t;
    const float t3 = t2 * t;
    const float w0 = (-t3 + 3.0 * t2 - 3.0 * t + 1.0) / 6.0;
    const float w1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    const float w2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    const float w3 = t3 / 6.0;
    const float x0 = (base - 0.5) / width;
    const float texel = 1.0 / width;
    return w0 * depth.sample(rsLinear, float2(x0, v)).r
         + w1 * depth.sample(rsLinear, float2(x0 + texel, v)).r
         + w2 * depth.sample(rsLinear, float2(x0 + 2.0 * texel, v)).r
         + w3 * depth.sample(rsLinear, float2(x0 + 3.0 * texel, v)).r;
}

/// 两步阻尼牛顿：gather 在 texel 网格上只把位置定到一个 texel，斜向轮廓会因此
/// 出现阶梯；对连续深度做牛顿迭代把它收敛到亚 texel。位置步长限幅 ±4 texel，
/// 避免深度台阶附近跳到另一个面上去。
kernel void rs_refine(texture2d<float, access::sample> depth [[texture(0)]],
                      texture2d<float, access::read> offsetsIn [[texture(1)]],
                      texture2d<float, access::write> offsetsOut [[texture(2)]],
                      constant RSStereoParams &params [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const uint2 size = uint2(offsetsOut.get_width(), offsetsOut.get_height());
    if (gid.x >= size.x || gid.y >= size.y) {
        return;
    }
    const float width = float(size.x);
    const float h = 1.0 / width;
    const float x = (float(gid.x) + 0.5) / width;
    const float y = (float(gid.y) + 0.5) / float(size.y);
    const float edgeMargin = max(params.edgeMargin, 1.0e-6);
    const float4 encoded = offsetsIn.read(gid);
    float result[2];
    for (int eye = 0; eye < 2; ++eye) {
        const float side = (eye == 0) ? 1.0 : -1.0;
        float t = x + ((eye == 0) ? encoded.r : encoded.g);
        for (uint step = 0; step < params.refineSteps; ++step) {
            const float d0 = rs_depth_at(depth, t, y, params);
            const float dm = rs_depth_at(depth, t - h, y, params);
            const float dp = rs_depth_at(depth, t + h, y, params);
            const float edge = saturate(min(t, 1.0 - t) / edgeMargin);
            const float e = (t - x) + side * params.amplitude * edge * (d0 - params.convergence);
            float slope = 1.0 + side * params.amplitude * edge * (dp - dm) / (2.0 * h);
            if (abs(slope) < 0.25) {
                slope = (slope < 0.0) ? -0.25 : 0.25;
            }
            t -= clamp(e / slope, -4.0 * h, 4.0 * h);
        }
        result[eye] = t - x;
    }
    offsetsOut.write(float4(result[0], result[1], 0.0, 0.0), gid);
}

// MARK: - Per-eye inverse map

inline float rs_shift(texture2d<float, access::sample> depth,
                      float u, float y,
                      constant RSStereoParams &params) {
    const float edge = saturate(min(u, 1.0 - u) / params.edgeMargin);
    return params.amplitude * edge * (depth.sample(rsLinear, float2(u, y)).r - params.convergence);
}

/// Left eye shows source u at x = u + S(u), right eye at x = u - S(u): nearer
/// than the convergence plane gives crossed disparity (in front of screen).
/// |dS/du| < 1 makes u = x ∓ S(u) a contraction, so fixed-point iteration
/// converges to the unique source position.
kernel void rs_inverse_map(texture2d<float, access::sample> depth [[texture(0)]],
                           texture2d<float, access::write> offsets [[texture(1)]],
                           constant RSStereoParams &params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    const uint2 size = uint2(offsets.get_width(), offsets.get_height());
    if (gid.x >= size.x || gid.y >= size.y) {
        return;
    }
    const float x = (float(gid.x) + 0.5) / float(size.x);
    const float y = (float(gid.y) + 0.5) / float(size.y);
    float leftSource = x;
    float rightSource = x;
    for (uint i = 0; i < params.iterations; ++i) {
        leftSource = x - rs_shift(depth, leftSource, y, params);
        rightSource = x + rs_shift(depth, rightSource, y, params);
    }
    offsets.write(float4(leftSource - x, rightSource - x, 0.0, 0.0), gid);
}

// MARK: - Full-resolution resample

/// Works on any plane (Y, CbCr, BGRA, RGBA half). Shifts are horizontal
/// only, so rows are read at their exact centres and only x is filtered:
/// Catmull-Rom keeps the source sharpness, the clamp suppresses ringing.
kernel void rs_warp(texture2d<float, access::read> source [[texture(0)]],
                    texture2d<float, access::sample> offsets [[texture(1)]],
                    texture2d<float, access::write> left [[texture(2)]],
                    texture2d<float, access::write> right [[texture(3)]],
                    uint3 gid [[thread_position_in_grid]]) {
    const uint width = source.get_width();
    const uint height = source.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    const float2 uv = (float2(gid.xy) + 0.5) / float2(width, height);
    const float2 offset = offsets.sample(rsLinear, uv).rg;
    const float position = (uv.x + (gid.z == 0 ? offset.x : offset.y)) * float(width) - 0.5;
    const float base = floor(position);
    const float t = position - base;
    const int x0 = int(base);
    const int last = int(width) - 1;
    const float t2 = t * t;
    const float t3 = t2 * t;
    const float w0 = -0.5 * t3 + t2 - 0.5 * t;
    const float w1 = 1.5 * t3 - 2.5 * t2 + 1.0;
    const float w2 = -1.5 * t3 + 2.0 * t2 + 0.5 * t;
    const float w3 = 0.5 * t3 - 0.5 * t2;
    const float4 a = source.read(uint2(clamp(x0 - 1, 0, last), gid.y));
    const float4 b = source.read(uint2(clamp(x0, 0, last), gid.y));
    const float4 c = source.read(uint2(clamp(x0 + 1, 0, last), gid.y));
    const float4 d = source.read(uint2(clamp(x0 + 2, 0, last), gid.y));
    float4 value = a * w0 + b * w1 + c * w2 + d * w3;
    value = clamp(value, min(b, c), max(b, c));
    if (gid.z == 0) {
        left.write(value, gid.xy);
    } else {
        right.write(value, gid.xy);
    }
}
