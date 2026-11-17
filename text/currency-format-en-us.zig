// Format one exact ASCII decimal using en-US currency conventions.
// Currency is selected with uniform_set_currency using its ISO 4217 numeric
// code. USD (840) is the default. Unsupported codes and invalid input trap.
const currency_format = @import("lib/currency-format.zig");
const format = currency_format.Formatter(.{
    .table = @import("lib/currency-format-en-us-table.zig"),
    .group = ",",
    .decimal = ".",
});

export fn input_ptr() u32 {
    return format.inputPtr();
}

export fn input_utf8_cap() u32 {
    return currency_format.INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return format.output_buf.len;
}

export fn uniform_set_currency(value: u32) u32 {
    return format.setCurrency(value);
}

export fn render(input_size_in: u32) currency_format.RenderResult {
    return format.renderResult(input_size_in);
}

test "currency uniform resets to USD after render" {
    try currency_format.expectRenders(format, "1234.5", 978, "€1,234.50", "$1,234.50");
}
