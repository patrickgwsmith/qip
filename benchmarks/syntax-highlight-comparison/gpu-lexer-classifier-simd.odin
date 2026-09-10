package gpu_lexer_classifier_simd

import "base:intrinsics"

BATCH_TOKENS :: 4096
FEATURE_COUNT :: 64
GATE_COUNT :: 16
HIDDEN_COUNT :: 72
CLASS_COUNT :: 9

GATE_WEIGHTS_OFFSET :: 0
GATE_BIAS_OFFSET :: GATE_WEIGHTS_OFFSET + GATE_COUNT * FEATURE_COUNT
HIDDEN_FEATURE_WEIGHTS_OFFSET :: GATE_BIAS_OFFSET + GATE_COUNT
HIDDEN_GATE_WEIGHTS_OFFSET :: HIDDEN_FEATURE_WEIGHTS_OFFSET + HIDDEN_COUNT * FEATURE_COUNT
HIDDEN_BIAS_OFFSET :: HIDDEN_GATE_WEIGHTS_OFFSET + HIDDEN_COUNT * GATE_COUNT
OUTPUT_WEIGHTS_OFFSET :: HIDDEN_BIAS_OFFSET + HIDDEN_COUNT
OUTPUT_BIAS_OFFSET :: OUTPUT_WEIGHTS_OFFSET + CLASS_COUNT * HIDDEN_COUNT
WEIGHT_COUNT :: OUTPUT_BIAS_OFFSET + CLASS_COUNT

Vec4 :: #simd[4]f32
Vec4_U32 :: #simd[4]u32

features: [BATCH_TOKENS * FEATURE_COUNT]f32
weights: [WEIGHT_COUNT]f32
labels: [BATCH_TOKENS]u8

@(export)
features_ptr :: proc "contextless" () -> u32 {
	return u32(uintptr(&features[0]))
}

@(export)
features_f32_cap :: proc "contextless" () -> u32 {
	return len(features)
}

@(export)
weights_ptr :: proc "contextless" () -> u32 {
	return u32(uintptr(&weights[0]))
}

@(export)
weights_f32_cap :: proc "contextless" () -> u32 {
	return len(weights)
}

@(export)
labels_ptr :: proc "contextless" () -> u32 {
	return u32(uintptr(&labels[0]))
}

@(export)
labels_cap :: proc "contextless" () -> u32 {
	return len(labels)
}

dot_scalar :: proc "contextless" (a, b: [^]f32, count: int) -> f32 {
	sum: f32
	for index in 0..<count {
		sum += a[index] * b[index]
	}
	return sum
}

// This approximation measures matrix throughput. A complete port must use the
// same activation and f16 rounding rules as gpu-lexer.
tanh_approx :: proc "contextless" (value: f32) -> f32 {
	x := max(f32(-3), min(f32(3), value))
	squared := x * x
	return x * (27 + squared) / (27 + 9 * squared)
}

sigmoid_approx :: proc "contextless" (value: f32) -> f32 {
	return 0.5 + 0.5 * tanh_approx(value * 0.5)
}

tanh_approx_4 :: proc "contextless" (value: Vec4) -> Vec4 {
	low: Vec4 = -3
	high: Vec4 = 3
	twenty_seven: Vec4 = 27
	nine: Vec4 = 9
	x := intrinsics.simd_clamp(value, low, high)
	squared := intrinsics.simd_mul(x, x)
	numerator := intrinsics.simd_mul(x, intrinsics.simd_add(twenty_seven, squared))
	denominator := intrinsics.simd_add(twenty_seven, intrinsics.simd_mul(nine, squared))
	return intrinsics.simd_div(numerator, denominator)
}

sigmoid_approx_4 :: proc "contextless" (value: Vec4) -> Vec4 {
	half: Vec4 = 0.5
	return intrinsics.simd_add(half, intrinsics.simd_mul(half, tanh_approx_4(intrinsics.simd_mul(value, half))))
}

classify_one :: proc "contextless" (token: int) -> u8 {
	input := &features[token * FEATURE_COUNT]
	gates: [GATE_COUNT]f32
	for gate in 0..<GATE_COUNT {
		row := &weights[GATE_WEIGHTS_OFFSET + gate * FEATURE_COUNT]
		gates[gate] = sigmoid_approx(weights[GATE_BIAS_OFFSET + gate] + dot_scalar(input, row, FEATURE_COUNT))
	}

	hidden: [HIDDEN_COUNT]f32
	for hidden_index in 0..<HIDDEN_COUNT {
		feature_row := &weights[HIDDEN_FEATURE_WEIGHTS_OFFSET + hidden_index * FEATURE_COUNT]
		gate_row := &weights[HIDDEN_GATE_WEIGHTS_OFFSET + hidden_index * GATE_COUNT]
		value := weights[HIDDEN_BIAS_OFFSET + hidden_index] +
		         dot_scalar(input, feature_row, FEATURE_COUNT) +
		         dot_scalar(&gates[0], gate_row, GATE_COUNT)
		hidden[hidden_index] = tanh_approx(value)
	}

	best_class: u8
	best_score: f32 = -3.4028235e38
	for class in 0..<CLASS_COUNT {
		row := &weights[OUTPUT_WEIGHTS_OFFSET + class * HIDDEN_COUNT]
		score := weights[OUTPUT_BIAS_OFFSET + class] + dot_scalar(&hidden[0], row, HIDDEN_COUNT)
		if score > best_score {
			best_score = score
			best_class = u8(class)
		}
	}
	return best_class
}

@(export)
classify_scalar :: proc "contextless" (token_count: u32) -> u32 {
	if token_count > BATCH_TOKENS do intrinsics.trap()
	checksum: u32
	for token: int = 0; token < int(token_count); token += 1 {
		label := classify_one(token)
		labels[token] = label
		checksum += u32(label)
	}
	return checksum
}

@(export)
classify_simd :: proc "contextless" (token_count: u32) -> u32 {
	if token_count > BATCH_TOKENS do intrinsics.trap()
	checksum: u32
	token := 0
	for token + 4 <= int(token_count) {
		gates: [GATE_COUNT]Vec4
		for gate in 0..<GATE_COUNT {
			value: Vec4 = weights[GATE_BIAS_OFFSET + gate]
			for feature_index in 0..<FEATURE_COUNT {
				input_lanes := [4]f32{
					features[(token + 0) * FEATURE_COUNT + feature_index],
					features[(token + 1) * FEATURE_COUNT + feature_index],
					features[(token + 2) * FEATURE_COUNT + feature_index],
					features[(token + 3) * FEATURE_COUNT + feature_index],
				}
				input := transmute(Vec4)input_lanes
				weight: Vec4 = weights[GATE_WEIGHTS_OFFSET + gate * FEATURE_COUNT + feature_index]
				value = intrinsics.simd_add(value, intrinsics.simd_mul(input, weight))
			}
			gates[gate] = sigmoid_approx_4(value)
		}

		hidden: [HIDDEN_COUNT]Vec4
		for hidden_index in 0..<HIDDEN_COUNT {
			value: Vec4 = weights[HIDDEN_BIAS_OFFSET + hidden_index]
			for feature_index in 0..<FEATURE_COUNT {
				input_lanes := [4]f32{
					features[(token + 0) * FEATURE_COUNT + feature_index],
					features[(token + 1) * FEATURE_COUNT + feature_index],
					features[(token + 2) * FEATURE_COUNT + feature_index],
					features[(token + 3) * FEATURE_COUNT + feature_index],
				}
				input := transmute(Vec4)input_lanes
				weight: Vec4 = weights[HIDDEN_FEATURE_WEIGHTS_OFFSET + hidden_index * FEATURE_COUNT + feature_index]
				value = intrinsics.simd_add(value, intrinsics.simd_mul(input, weight))
			}
			for gate in 0..<GATE_COUNT {
				weight: Vec4 = weights[HIDDEN_GATE_WEIGHTS_OFFSET + hidden_index * GATE_COUNT + gate]
				value = intrinsics.simd_add(value, intrinsics.simd_mul(gates[gate], weight))
			}
			hidden[hidden_index] = tanh_approx_4(value)
		}

		best_class: Vec4_U32
		best_score: Vec4 = -3.4028235e38
		for class in 0..<CLASS_COUNT {
			score: Vec4 = weights[OUTPUT_BIAS_OFFSET + class]
			for hidden_index in 0..<HIDDEN_COUNT {
				weight: Vec4 = weights[OUTPUT_WEIGHTS_OFFSET + class * HIDDEN_COUNT + hidden_index]
				score = intrinsics.simd_add(score, intrinsics.simd_mul(hidden[hidden_index], weight))
			}
			better := intrinsics.simd_lanes_gt(score, best_score)
			class_vector: Vec4_U32 = u32(class)
			best_score = intrinsics.simd_select(better, score, best_score)
			best_class = intrinsics.simd_select(better, class_vector, best_class)
		}

		class_lanes := transmute([4]u32)best_class
		for lane in 0..<4 {
			label := u8(class_lanes[lane])
			labels[token + lane] = label
			checksum += u32(label)
		}
		token += 4
	}

	for token < int(token_count) {
		label := classify_one(token)
		labels[token] = label
		checksum += u32(label)
		token += 1
	}
	return checksum
}
