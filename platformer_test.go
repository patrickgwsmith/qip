package main

import (
	"context"
	"testing"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func TestSideScrollerPlatformerIsWinnable(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "gui/side-scroller-platformer.wasm")
	defer compiled.Close(ctx)

	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("test-side-scroller-platformer"))
	if err != nil {
		t.Fatalf("instantiate platformer: %v", err)
	}
	defer mod.Close(ctx)

	keyEvent := requiredExportedFunction(t, mod, "key_event")
	render := requiredExportedFunction(t, mod, "render")
	beginUpdateAt := requiredExportedFunction(t, mod, "begin_update_at")
	finishUpdate := requiredExportedFunction(t, mod, "finish_update")
	playerTileX := requiredExportedFunction(t, mod, "test_player_tile_x")
	playerTileY := requiredExportedFunction(t, mod, "test_player_tile_y")
	gameOver := requiredExportedFunction(t, mod, "test_game_over")
	won := requiredExportedFunction(t, mod, "test_won")
	hasFlames := requiredExportedFunction(t, mod, "test_has_flames")

	const (
		xkRight     = 0xFF53
		xkSpace     = 0x20
		xkZ         = 0x5A
		keyDownFlag = 1
		stepMs      = 16
	)

	if results, err := render.Call(ctx, 0); err != nil || len(results) != 1 {
		t.Fatalf("initialize platformer: results=%v error=%v", results, err)
	}
	callVoid(t, ctx, beginUpdateAt, 1)
	callVoid(t, ctx, keyEvent, xkRight, keyDownFlag)
	if results, err := finishUpdate.Call(ctx); err != nil || len(results) != 1 {
		t.Fatalf("finish initial input update: results=%v error=%v", results, err)
	}

	jumpAtTiles := []uint64{14, 33, 43, 51, 57, 71, 82, 96, 107, 121, 136, 149, 168, 180, 192, 204}
	nextJump := 0
	jumpUpFrame := -1
	fireFrames := []int{760, 910, 1040, 1200}
	nextFire := 0
	fireUpFrame := -1

	for frame := 1; frame <= 2500; frame++ {
		nowMs := uint64(frame * stepMs)
		tx := callI32(t, ctx, playerTileX)
		ty := callI32(t, ctx, playerTileY)
		eventAtMS := nowMs - 1
		hasEvent := false

		if nextJump < len(jumpAtTiles) && tx >= jumpAtTiles[nextJump] {
			callVoid(t, ctx, beginUpdateAt, eventAtMS)
			callVoid(t, ctx, keyEvent, xkSpace, keyDownFlag)
			hasEvent = true
			jumpUpFrame = frame + 4
			nextJump++
		}
		if frame == jumpUpFrame {
			if !hasEvent {
				callVoid(t, ctx, beginUpdateAt, eventAtMS)
				hasEvent = true
			}
			callVoid(t, ctx, keyEvent, xkSpace, 0)
		}
		if nextFire < len(fireFrames) && frame == fireFrames[nextFire] {
			if !hasEvent {
				callVoid(t, ctx, beginUpdateAt, eventAtMS)
				hasEvent = true
			}
			callVoid(t, ctx, keyEvent, xkZ, keyDownFlag)
			fireUpFrame = frame + 2
			nextFire++
		}
		if frame == fireUpFrame {
			if !hasEvent {
				callVoid(t, ctx, beginUpdateAt, eventAtMS)
				hasEvent = true
			}
			callVoid(t, ctx, keyEvent, xkZ, 0)
		}
		if hasEvent {
			if results, err := finishUpdate.Call(ctx); err != nil || len(results) != 1 {
				t.Fatalf("finish event update at frame=%d: results=%v error=%v", frame, results, err)
			}
		}

		callVoid(t, ctx, beginUpdateAt, nowMs)
		if results, err := finishUpdate.Call(ctx); err != nil || len(results) != 1 {
			t.Fatalf("finish platformer update at frame=%d: results=%v error=%v", frame, results, err)
		}

		if callI32(t, ctx, gameOver) != 0 {
			t.Fatalf("scripted playthrough died at frame=%d tile=(%d,%d) nextJump=%d", frame, tx, ty, nextJump)
		}
		if callI32(t, ctx, won) != 0 {
			if callI32(t, ctx, hasFlames) == 0 {
				t.Fatalf("won without collecting flame power-up")
			}
			if tx < 210 {
				t.Fatalf("won too early at tile x=%d", tx)
			}
			return
		}
	}

	t.Fatalf("scripted playthrough did not win; final tile=(%d,%d) nextJump=%d", callI32(t, ctx, playerTileX), callI32(t, ctx, playerTileY), nextJump)
}

func requiredExportedFunction(t *testing.T, mod api.Module, name string) api.Function {
	t.Helper()
	fn := mod.ExportedFunction(name)
	if fn == nil {
		t.Fatalf("missing exported function %q", name)
	}
	return fn
}

func callI32(t *testing.T, ctx context.Context, fn api.Function, args ...uint64) uint64 {
	t.Helper()
	res, err := fn.Call(ctx, args...)
	if err != nil {
		t.Fatalf("call %s: %v", fn.Definition().Name(), err)
	}
	if len(res) != 1 {
		t.Fatalf("call %s returned %d values, want 1", fn.Definition().Name(), len(res))
	}
	return res[0]
}

func callVoid(t *testing.T, ctx context.Context, fn api.Function, args ...uint64) {
	t.Helper()
	res, err := fn.Call(ctx, args...)
	if err != nil {
		t.Fatalf("call %s: %v", fn.Definition().Name(), err)
	}
	if len(res) > 1 {
		t.Fatalf("call %s returned %d values, want 0 or 1", fn.Definition().Name(), len(res))
	}
}
