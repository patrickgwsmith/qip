(module
  (memory (export "memory") 1024 1024)

  (func (export "input_ptr") (result i32)
    i32.const 0)

  (func (export "input_bytes_cap") (result i32)
    i32.const 67108864)

  (func (export "output_bytes_cap") (result i32)
    i32.const 67108864)

  (func (export "render") (param $input_size i32) (result i64)
    local.get $input_size
    i64.extend_i32_u))
