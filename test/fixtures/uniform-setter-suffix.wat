;; Exports a setter whose name carries a "__" suffix. Hosts match it by its
;; short key, so -u quality=80 reaches uniform_set_quality__0x64.
(module
  (memory (export "memory") 1 1)
  (global $quality (mut i32) (i32.const 0))
  (func (export "uniform_set_quality__0x64") (param i32) (result i32)
    local.get 0
    global.set $quality
    local.get 0)
  (func (export "output_bytes_cap") (result i32)
    i32.const 4)
  (func (export "render") (param i32) (result i64)
    i32.const 0
    global.get $quality
    i32.store
    i64.const 4)
)
