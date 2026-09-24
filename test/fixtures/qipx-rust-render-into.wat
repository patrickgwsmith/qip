(module
  (import "qip" "must_render_into" (func $render (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_render_into_emit_error" (func $error (param i64 i32 i32) (result i32)))
  (import "qip" "must_render_into_finish" (func $finish (param i64 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "x")
  (data (i32.const 64) "bad output")
  (func (export "comply") (result i32)
    (local $size i32)
    i64.const 0
    i32.const 0
    i32.const 1
    i32.const 32
    i32.const 2
    call $render
    local.set $size
    local.get $size
    i32.const 1
    i32.ne
    i32.const 32
    i32.load8_u
    i32.const 120
    i32.ne
    i32.or
    if
      i64.const 0
      i32.const 64
      i32.const 10
      call $error
      drop
      i64.const 0
      i32.const 1
      call $finish
      drop
    else
      i64.const 0
      i32.const 0
      call $finish
      drop
    end
    i32.const 1)
)
