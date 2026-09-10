const std = @import("std");

const BATCH_TOKENS: usize = 4096;
const FEATURE_COUNT: usize = 64;
const GATE_COUNT: usize = 16;
const HIDDEN_COUNT: usize = 72;
const CLASS_COUNT: usize = 9;

const GATE_WEIGHTS_OFFSET: usize = 0;
const GATE_BIAS_OFFSET: usize = GATE_WEIGHTS_OFFSET + GATE_COUNT * FEATURE_COUNT;
const HIDDEN_FEATURE_WEIGHTS_OFFSET: usize = GATE_BIAS_OFFSET + GATE_COUNT;
const HIDDEN_GATE_WEIGHTS_OFFSET: usize = HIDDEN_FEATURE_WEIGHTS_OFFSET + HIDDEN_COUNT * FEATURE_COUNT;
const HIDDEN_BIAS_OFFSET: usize = HIDDEN_GATE_WEIGHTS_OFFSET + HIDDEN_COUNT * GATE_COUNT;
const OUTPUT_WEIGHTS_OFFSET: usize = HIDDEN_BIAS_OFFSET + HIDDEN_COUNT;
const OUTPUT_BIAS_OFFSET: usize = OUTPUT_WEIGHTS_OFFSET + CLASS_COUNT * HIDDEN_COUNT;
const WEIGHT_COUNT: usize = OUTPUT_BIAS_OFFSET + CLASS_COUNT;

const Vec4 = @Vector(4, f32);
const Vec4u32 = @Vector(4, u32);

var features: [BATCH_TOKENS * FEATURE_COUNT]f32 align(16) = undefined;
var weights: [WEIGHT_COUNT]f32 align(16) = undefined;
var labels: [BATCH_TOKENS]u8 = undefined;

export fn features_ptr() u32 {
    return @intCast(@intFromPtr(&features));
}

export fn features_f32_cap() u32 {
    return features.len;
}

export fn weights_ptr() u32 {
    return @intCast(@intFromPtr(&weights));
}

export fn weights_f32_cap() u32 {
    return weights.len;
}

export fn labels_ptr() u32 {
    return @intCast(@intFromPtr(&labels));
}

export fn labels_cap() u32 {
    return labels.len;
}

fn dotScalar(a: [*]const f32, b: [*]const f32, comptime count: usize) f32 {
    var sum: f32 = 0.0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        sum += a[index] * b[index];
    }
    return sum;
}

// This rational approximation keeps the experiment focused on matrix work.
// A complete port must measure its label agreement with gpu-lexer's f32 tanh.
fn tanhApprox(value: f32) f32 {
    const x = @max(-3.0, @min(3.0, value));
    const squared = x * x;
    return x * (27.0 + squared) / (27.0 + 9.0 * squared);
}

fn sigmoidApprox(value: f32) f32 {
    return 0.5 + 0.5 * tanhApprox(value * 0.5);
}

fn tanhApprox4(value: Vec4) Vec4 {
    const x = @max(@as(Vec4, @splat(-3.0)), @min(@as(Vec4, @splat(3.0)), value));
    const squared = x * x;
    return x * (@as(Vec4, @splat(27.0)) + squared) /
        (@as(Vec4, @splat(27.0)) + @as(Vec4, @splat(9.0)) * squared);
}

fn sigmoidApprox4(value: Vec4) Vec4 {
    return @as(Vec4, @splat(0.5)) + @as(Vec4, @splat(0.5)) * tanhApprox4(value * @as(Vec4, @splat(0.5)));
}

fn classifyOne(token: usize) u8 {
    const feature_values: [*]const f32 = @ptrCast(&features);
    const weight_values: [*]const f32 = @ptrCast(&weights);
    const input = feature_values + token * FEATURE_COUNT;
    var gates: [GATE_COUNT]f32 align(16) = undefined;
    var gate: usize = 0;
    while (gate < GATE_COUNT) : (gate += 1) {
        const row = weight_values + GATE_WEIGHTS_OFFSET + gate * FEATURE_COUNT;
        gates[gate] = sigmoidApprox(weight_values[GATE_BIAS_OFFSET + gate] + dotScalar(input, row, FEATURE_COUNT));
    }

    var hidden: [HIDDEN_COUNT]f32 align(16) = undefined;
    var hidden_index: usize = 0;
    while (hidden_index < HIDDEN_COUNT) : (hidden_index += 1) {
        const feature_row = weight_values + HIDDEN_FEATURE_WEIGHTS_OFFSET + hidden_index * FEATURE_COUNT;
        const gate_row = weight_values + HIDDEN_GATE_WEIGHTS_OFFSET + hidden_index * GATE_COUNT;
        const value = weight_values[HIDDEN_BIAS_OFFSET + hidden_index] +
            dotScalar(input, feature_row, FEATURE_COUNT) +
            dotScalar(&gates, gate_row, GATE_COUNT);
        hidden[hidden_index] = tanhApprox(value);
    }

    var best_class: u8 = 0;
    var best_score: f32 = -std.math.inf(f32);
    var class: usize = 0;
    while (class < CLASS_COUNT) : (class += 1) {
        const row = weight_values + OUTPUT_WEIGHTS_OFFSET + class * HIDDEN_COUNT;
        const score = weight_values[OUTPUT_BIAS_OFFSET + class] + dotScalar(&hidden, row, HIDDEN_COUNT);
        if (score > best_score) {
            best_score = score;
            best_class = @intCast(class);
        }
    }
    return best_class;
}

export fn classify_scalar(token_count_in: u32) u32 {
    const token_count: usize = @intCast(token_count_in);
    if (token_count > BATCH_TOKENS) @trap();
    var checksum: u32 = 0;
    var token: usize = 0;
    while (token < token_count) : (token += 1) {
        const label = classifyOne(token);
        labels[token] = label;
        checksum +%= label;
    }
    return checksum;
}

export fn classify_simd(token_count_in: u32) u32 {
    const token_count: usize = @intCast(token_count_in);
    if (token_count > BATCH_TOKENS) @trap();
    const feature_values: [*]const f32 = @ptrCast(&features);
    const weight_values: [*]const f32 = @ptrCast(&weights);

    var checksum: u32 = 0;
    var token: usize = 0;
    while (token + 4 <= token_count) : (token += 4) {
        var gates: [GATE_COUNT]Vec4 align(16) = undefined;
        var gate: usize = 0;
        while (gate < GATE_COUNT) : (gate += 1) {
            var value: Vec4 = @splat(weight_values[GATE_BIAS_OFFSET + gate]);
            var feature_index: usize = 0;
            while (feature_index < FEATURE_COUNT) : (feature_index += 1) {
                const input = Vec4{
                    feature_values[(token + 0) * FEATURE_COUNT + feature_index],
                    feature_values[(token + 1) * FEATURE_COUNT + feature_index],
                    feature_values[(token + 2) * FEATURE_COUNT + feature_index],
                    feature_values[(token + 3) * FEATURE_COUNT + feature_index],
                };
                value += input * @as(Vec4, @splat(weight_values[GATE_WEIGHTS_OFFSET + gate * FEATURE_COUNT + feature_index]));
            }
            gates[gate] = sigmoidApprox4(value);
        }

        var hidden: [HIDDEN_COUNT]Vec4 align(16) = undefined;
        var hidden_index: usize = 0;
        while (hidden_index < HIDDEN_COUNT) : (hidden_index += 1) {
            var value: Vec4 = @splat(weight_values[HIDDEN_BIAS_OFFSET + hidden_index]);
            var feature_index: usize = 0;
            while (feature_index < FEATURE_COUNT) : (feature_index += 1) {
                const input = Vec4{
                    feature_values[(token + 0) * FEATURE_COUNT + feature_index],
                    feature_values[(token + 1) * FEATURE_COUNT + feature_index],
                    feature_values[(token + 2) * FEATURE_COUNT + feature_index],
                    feature_values[(token + 3) * FEATURE_COUNT + feature_index],
                };
                value += input * @as(Vec4, @splat(weight_values[HIDDEN_FEATURE_WEIGHTS_OFFSET + hidden_index * FEATURE_COUNT + feature_index]));
            }
            gate = 0;
            while (gate < GATE_COUNT) : (gate += 1) {
                value += gates[gate] * @as(Vec4, @splat(weight_values[HIDDEN_GATE_WEIGHTS_OFFSET + hidden_index * GATE_COUNT + gate]));
            }
            hidden[hidden_index] = tanhApprox4(value);
        }

        var best_class: Vec4u32 = @splat(0);
        var best_score: Vec4 = @splat(-std.math.inf(f32));
        var class: usize = 0;
        while (class < CLASS_COUNT) : (class += 1) {
            var score: Vec4 = @splat(weight_values[OUTPUT_BIAS_OFFSET + class]);
            var output_hidden: usize = 0;
            while (output_hidden < HIDDEN_COUNT) : (output_hidden += 1) {
                score += hidden[output_hidden] * @as(Vec4, @splat(weight_values[OUTPUT_WEIGHTS_OFFSET + class * HIDDEN_COUNT + output_hidden]));
            }
            const better = score > best_score;
            best_score = @select(f32, better, score, best_score);
            best_class = @select(u32, better, @as(Vec4u32, @splat(@as(u32, @intCast(class)))), best_class);
        }
        inline for (0..4) |lane| {
            const label: u8 = @intCast(best_class[lane]);
            labels[token + lane] = label;
            checksum +%= label;
        }
    }

    while (token < token_count) : (token += 1) {
        const label = classifyOne(token);
        labels[token] = label;
        checksum +%= label;
    }
    return checksum;
}

test "SIMD and scalar classifiers select the same labels" {
    for (&features, 0..) |*value, index| {
        const signed: i32 = @intCast(index % 29);
        value.* = @as(f32, @floatFromInt(signed - 14)) * 0.003;
    }
    for (&weights, 0..) |*value, index| {
        const signed: i32 = @intCast(index % 31);
        value.* = @as(f32, @floatFromInt(signed - 15)) * 0.002;
    }

    const scalar_checksum = classify_scalar(32);
    var scalar_labels: [32]u8 = undefined;
    @memcpy(&scalar_labels, labels[0..32]);
    const simd_checksum = classify_simd(32);

    try std.testing.expectEqual(scalar_checksum, simd_checksum);
    try std.testing.expectEqualSlices(u8, &scalar_labels, labels[0..32]);
}
