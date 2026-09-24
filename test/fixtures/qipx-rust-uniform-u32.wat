(module
  (memory (export "memory") 1 1)
  (global $value (mut i32) (i32.const 0))
  (func (export "uniform_set_value") (param i32)
    local.get 0
    global.set $value)
  (func (export "output_bytes_cap") (result i32)
    i32.const 4)
  (func (export "render") (param i32) (result i64)
    i32.const 0
    global.get $value
    i32.store
    i64.const 4)
)
