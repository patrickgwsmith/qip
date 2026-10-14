// Exact-output oracle generated from text/tldraw-draw-font-metrics-csv.wasm.
const std = @import("std");

extern "qip" fn must_render_exactly(ordinal: u64, input_ptr: u32, input_len: u32, expected_ptr: u32, expected_len: u32) i32;

const Case = struct { input: []const u8, expected: []const u8 };

const cases = [_]Case{
    .{ .input = "Hello", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,5,\"Hello\",5,5,63.952,62.952,24.48,0,32.16,24.48,7.68,0,32.16,0.696,6.240000000000002,61.944,25.536,1000,24,0\n" },
    .{ .input = "AVATAR, yay!?", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,13,\"AVATAR, yay!?\",13,13,175.888,174.888,24.48,0,32.16,24.48,7.68,0,32.16,0.504,7.199999999999999,174.504,30.744,1000,24,0\n" },
    .{ .input = "space  test", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,11,\"space  test\",11,11,137.632,136.632,24.48,0,32.16,24.48,7.68,0,32.16,0.456,6.864000000000001,136.224,30.744,1000,24,0\n" },
    .{ .input = "Hello\nWorld", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,5,\"Hello\",5,5,63.952,62.952,24.48,0,32.16,24.48,7.68,0,32.16,0.696,6.240000000000002,61.944,25.536,1000,24,0\n1,6,11,\"World\",5,5,74.152,73.152,56.64,32.16,64.32,24.48,7.68,0,32.16,1.608,38.400000000000006,72.048,56.928,1000,24,0\n" },
    .{ .input = "Café déjà vu — €", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,23,\"Café déjà vu — €\",16,16,211.552,210.552,24.48,0,32.16,24.48,7.68,0,32.16,1.2,4.32,209.544,30.72,1000,24,0\n" },
    .{ .input = "fi fl ffi", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,9,\"fi fl ffi\",9,9,86.08,85.08,24.48,0,32.16,24.48,7.68,0,32.16,1.56,6.240000000000002,65.712,27.048000000000002,1000,24,0\n" },
    .{ .input = "--------------------", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,20,\"--------------------\",20,20,244.984,243.984,24.48,0,32.16,24.48,7.68,0,32.16,1.128,16.584,11.064,19.92,1000,24,0\n" },
    .{ .input = "“Hello” (World) 123", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,23,\"“Hello” (World) 123\",19,19,242.248,241.248,24.48,0,32.16,24.48,7.68,0,32.16,1.368,4.968,239.976,30.768,1000,24,0\n" },
    .{ .input = "quotes: “AVATAR” — yay!", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,29,\"quotes: “AVATAR” — yay!\",23,23,312.208,311.208,24.48,0,32.16,24.48,7.68,0,32.16,0.84,4.968,309.768,30.744,1000,24,0\n" },
    .{ .input = "To VA WA Te Yo", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,14,\"To VA WA Te Yo\",14,14,189.592,188.592,24.48,0,32.16,24.48,7.68,0,32.16,0.96,7.464000000000002,187.584,25.536,1000,24,0\n" },
    .{ .input = "The quick brown fox jumps over the lazy dog.", .expected = "line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n0,0,44,\"The quick brown fox jumps over the lazy dog.\",44,44,563.152,562.152,24.48,0,32.16,24.48,7.68,0,32.16,0.96,6.240000000000002,560.616,30.744,1000,24,0\n" },
};

export fn comply() i32 {
    for (cases, 0..) |case, ordinal| {
        _ = must_render_exactly(
            ordinal,
            @intCast(@intFromPtr(case.input.ptr)),
            @intCast(case.input.len),
            @intCast(@intFromPtr(case.expected.ptr)),
            @intCast(case.expected.len),
        );
    }
    return cases.len;
}
