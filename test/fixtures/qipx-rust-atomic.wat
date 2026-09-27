(module
  (memory (export "memory") 1 2)
  (func (export "render") (param i32) (result i64) (drop (i32.atomic.load (i32.const 0))) i64.const 0)
  (func (export "begin_update_at") (param i32) (result i32) i32.const 0)
  (func (export "finish_update"))
  (func (export "key_event") (param i32 i32))
  (func (export "output_utf8_cap") (result i32) i32.const 0))
