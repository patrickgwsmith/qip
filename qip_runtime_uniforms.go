package main

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero/api"
)

func parseUniformInt(value string, bitSize int) (int64, error) {
	base := 10
	raw := value

	if len(value) >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X') {
		base = 16
		raw = value[2:]
	} else if len(value) >= 3 && (value[0] == '+' || value[0] == '-') && value[1] == '0' && (value[2] == 'x' || value[2] == 'X') {
		base = 16
		raw = value[:1] + value[3:]
	}

	return strconv.ParseInt(raw, base, bitSize)
}

func validUniformKey(key string) bool {
	if key == "" || len(key) > 63 || key[0] < 'a' || key[0] > 'z' || strings.HasSuffix(key, "_") || strings.Contains(key, "__") {
		return false
	}
	for _, r := range key {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' {
			continue
		}
		return false
	}
	return true
}

func parseUniformUint(value string, bitSize int) (uint64, error) {
	base := 10
	raw := value
	if len(value) >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X') {
		base = 16
		raw = value[2:]
	}
	return strconv.ParseUint(raw, base, bitSize)
}

func applyModuleUniforms(ctx context.Context, mod api.Module, uniforms map[string]string) error {
	defs := mod.ExportedFunctionDefinitions()
	setters, err := qinternal.UniformSetterExports(defs)
	if err != nil {
		return err
	}
	keys := make([]string, 0, len(uniforms))
	for key := range uniforms {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		if !validUniformKey(key) {
			return fmt.Errorf("invalid uniform key %q (must be 1..63 chars, start with [a-z], continue with [a-z0-9_], must not end with _, and must not contain __)", key)
		}
		fnName, ok := setters[key]
		if !ok {
			return fmt.Errorf("Wasm module does not export uniform_set_%s for uniform %q", key, key)
		}
		fn := mod.ExportedFunction(fnName)
		def, ok := defs[fnName]
		if !ok {
			return fmt.Errorf("Wasm module is missing function definition for %s", fnName)
		}
		paramTypes := def.ParamTypes()
		if len(paramTypes) != 1 {
			return fmt.Errorf("%s must accept exactly one argument", fnName)
		}
		value := uniforms[key]

		var args [1]uint64
		switch paramTypes[0] {
		case api.ValueTypeF32:
			parsed, err := strconv.ParseFloat(value, 32)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected f32)", value, fnName)
			}
			args[0] = api.EncodeF32(float32(parsed))
		case api.ValueTypeF64:
			parsed, err := strconv.ParseFloat(value, 64)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected f64)", value, fnName)
			}
			args[0] = api.EncodeF64(parsed)
		case api.ValueTypeI32:
			parsed, err := parseUniformUint(value, 32)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected unsigned i32)", value, fnName)
			}
			args[0] = uint64(uint32(parsed))
		case api.ValueTypeI64:
			parsed, err := parseUniformInt(value, 64)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected i64)", value, fnName)
			}
			args[0] = uint64(parsed)
		default:
			return fmt.Errorf("%s has unsupported parameter type", fnName)
		}

		if _, err := fn.Call(ctx, args[0]); err != nil {
			return fmt.Errorf("Error running %s(%s): %w", fnName, value, wasmruntime.HumanizeExecutionError(ctx, err))
		}
	}
	return nil
}
