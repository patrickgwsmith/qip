package qinternal

import (
	"fmt"
	"strings"

	"github.com/tetratelabs/wazero/api"
)

const uniformSetterPrefix = "uniform_set_"

// UniformSetterExports maps each uniform key to the name of the export that
// sets it. A setter export is uniform_set_<key>, optionally followed by "__"
// and a suffix reserved for declaring the uniform's maxima, so hosts match on
// <key> alone. A module that exports two setters for one key is rejected.
func UniformSetterExports(exports map[string]api.FunctionDefinition) (map[string]string, error) {
	setters := make(map[string]string)
	for name := range exports {
		rest, ok := strings.CutPrefix(name, uniformSetterPrefix)
		if !ok {
			continue
		}
		key, _, _ := strings.Cut(rest, "__")
		if other, duplicate := setters[key]; duplicate {
			return nil, fmt.Errorf("Wasm module exports both %s and %s for uniform %q", min(other, name), max(other, name), key)
		}
		setters[key] = name
	}
	return setters, nil
}
