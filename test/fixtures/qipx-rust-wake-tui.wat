(module
  (memory (export "memory") 1 1)
  (data (i32.const 0) "before")
  (data (i32.const 16) "after")
  (global $state (mut i32) (i32.const 0))
  (global $now (mut i64) (i64.const 0))
  (func (export "output_utf8_cap") (result i32)
    i32.const 6)
  (func (export "render") (param i32) (result i64)
    global.get $state
    if (result i64)
      i64.const 68719476741
    else
      i64.const 6
    end)
  (func (export "begin_update_at") (param i64)
    local.get 0
    global.set $now
    local.get 0
    i64.const 10
    i64.ge_u
    if
      i32.const 1
      global.set $state
    end)
  (func (export "key_event") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "finish_update") (result i64)
    global.get $state
    if (result i64)
      global.get $now
    else
      i64.const 10
    end)
)
