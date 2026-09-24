(module
  (memory (export "memory") 1 1)
  (func (export "input_ptr") (result i32) (i32.const 0))
  (func (export "input_bytes_cap") (result i32) (i32.const 16))
  (func (export "output_bytes_cap") (result i32) (i32.const 16))
  (func (export "render") (param i32) (result i64)
    (i32.const 1)
    memory.grow
    drop
    (i64.const 0)))
