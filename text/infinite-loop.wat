(module
  (memory (export "memory") 1 1)

  (func (export "input_ptr") (result i32)
    (i32.const 0)
  )
  (func (export "input_utf8_cap") (result i32)
    (i32.const 65536)
  )
  (global $output_ptr i32 (i32.const 0))
  (func (export "output_utf8_cap") (result i32)
    (i32.const 65536)
  )

  (func $render_size (param i32) (result i32)
    (loop $forever
      br $forever
    )
    unreachable
  )
  (func (export "render") (param $input_size i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
      (i64.extend_i32_u (call $render_size (local.get $input_size)))))
)