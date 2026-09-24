(module
  (memory (export "memory") 1 1)
  (func (export "output_bytes_cap") (result i32)
    (local i32)
    i32.const 4
    local.set 0
    local.get 0)
  (func (export "render") (param i32) (result i64)
    i64.const 0)
)
