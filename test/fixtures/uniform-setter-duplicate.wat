;; Exports two setters with the short key quality, which hosts must reject.
(module
  (memory (export "memory") 1 1)
  (func (export "uniform_set_quality__0x64") (param i32) (result i32)
    local.get 0)
  (func (export "uniform_set_quality") (param i32) (result i32)
    local.get 0)
  (func (export "output_bytes_cap") (result i32)
    i32.const 4)
  (func (export "render") (param i32) (result i64)
    i64.const 0)
)
