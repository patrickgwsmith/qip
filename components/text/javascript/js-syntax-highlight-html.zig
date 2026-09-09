const std = @import("std");
const javascript = @import("javascript");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 32 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/javascript";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,
    span_depth: usize = 0,
    emitted_stack: [8]bool = [_]bool{false} ** 8,

    fn remaining(self: *const Writer) usize {
        return output_buf.len - self.idx;
    }

    fn rawByte(self: *Writer, byte: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = byte;
        self.idx += 1;
    }

    fn rawSlice(self: *Writer, slice: []const u8) void {
        if (self.overflow or slice.len == 0) return;
        if (self.remaining() < slice.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + slice.len], slice);
        self.idx += slice.len;
    }

    fn writeEscapedByte(self: *Writer, byte: u8) void {
        const escaped = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => {
                self.rawByte(byte);
                return;
            },
        };
        self.rawSlice(escaped);
    }

    pub fn writeByte(self: *Writer, byte: u8) void {
        self.writeEscapedByte(byte);
    }

    pub fn writeSlice(self: *Writer, slice: []const u8) void {
        for (slice) |byte| self.writeByte(byte);
    }

    pub fn writeOperator(self: *Writer, slice: []const u8) void {
        self.rawSlice("<span class=\"syntax-operator\">");
        self.writeSlice(slice);
        self.rawSlice("</span>");
    }

    pub fn writeParameterType(self: *Writer, slice: []const u8) void {
        self.writeSlice(slice);
    }

    fn mappedClass(class_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, class_name, "hljs-comment")) return "syntax-comment";
        if (std.mem.eql(u8, class_name, "hljs-string") or
            std.mem.eql(u8, class_name, "hljs-regexp")) return "syntax-string";
        if (std.mem.eql(u8, class_name, "hljs-number")) return "syntax-number";
        if (std.mem.eql(u8, class_name, "hljs-keyword") or
            std.mem.eql(u8, class_name, "hljs-meta")) return "syntax-keyword";
        if (std.mem.eql(u8, class_name, "hljs-title class_") or
            std.mem.eql(u8, class_name, "hljs-title class_ inherited__") or
            std.mem.eql(u8, class_name, "hljs-built_in") or
            std.mem.eql(u8, class_name, "hljs-name")) return "syntax-type";
        if (std.mem.eql(u8, class_name, "hljs-title function_")) return "syntax-function";
        if (std.mem.eql(u8, class_name, "hljs-literal") or
            std.mem.eql(u8, class_name, "hljs-variable language_")) return "syntax-constant";
        return null;
    }

    pub fn writeSpan(self: *Writer, class_name: []const u8, slice: []const u8) void {
        if (std.mem.eql(u8, class_name, "hljs-variable language_") and
            std.mem.eql(u8, slice, "console"))
        {
            self.writeSlice(slice);
            return;
        }
        if (std.mem.eql(u8, class_name, "hljs-built_in") and
            slice.len > 0 and slice[0] >= 'a' and slice[0] <= 'z' and
            !std.mem.eql(u8, slice, "exports") and !std.mem.eql(u8, slice, "module"))
        {
            self.writeSlice(slice);
            return;
        }
        if (std.mem.eql(u8, class_name, "hljs-built_in") and
            (std.mem.eql(u8, slice, "Array") or std.mem.eql(u8, slice, "Date") or
                std.mem.eql(u8, slice, "Error") or std.mem.eql(u8, slice, "Map") or
                std.mem.eql(u8, slice, "RegExp") or std.mem.eql(u8, slice, "Set") or
                std.mem.eql(u8, slice, "Uint8Array")))
        {
            self.writeSlice(slice);
            return;
        }
        if (std.mem.eql(u8, class_name, "hljs-title class_") and
            std.mem.eql(u8, slice, "JSON"))
        {
            self.writeSlice(slice);
            return;
        }
        if (std.mem.eql(u8, class_name, "hljs-keyword")) {
            if (std.mem.eql(u8, slice, "type")) {
                self.writeSlice(slice);
                return;
            }
            const mapped: ?[]const u8 = if (std.mem.eql(u8, slice, "this"))
                "syntax-constant"
            else if (std.mem.eql(u8, slice, "module"))
                "syntax-type"
            else if (std.mem.eql(u8, slice, "delete") or
                std.mem.eql(u8, slice, "in") or
                std.mem.eql(u8, slice, "instanceof") or
                std.mem.eql(u8, slice, "new") or
                std.mem.eql(u8, slice, "typeof") or
                std.mem.eql(u8, slice, "void"))
                "syntax-operator"
            else
                null;
            if (mapped) |name| {
                self.rawSlice("<span class=\"");
                self.rawSlice(name);
                self.rawSlice("\">");
                self.writeSlice(slice);
                self.rawSlice("</span>");
                return;
            }
        }
        self.openSpan(class_name);
        self.writeSlice(slice);
        self.closeSpan();
    }

    pub fn openSpan(self: *Writer, class_name: []const u8) void {
        if (self.span_depth == self.emitted_stack.len) {
            self.overflow = true;
            return;
        }
        const mapped = mappedClass(class_name);
        const emitted = mapped != null;
        self.emitted_stack[self.span_depth] = emitted;
        self.span_depth += 1;
        if (mapped) |name| {
            self.rawSlice("<span class=\"");
            self.rawSlice(name);
            self.rawSlice("\">");
        }
    }

    pub fn closeSpan(self: *Writer) void {
        if (self.span_depth == 0) {
            self.overflow = true;
            return;
        }
        self.span_depth -= 1;
        if (self.emitted_stack[self.span_depth]) {
            self.rawSlice("</span>");
        }
    }

    fn finish(self: *Writer) void {
        if (self.span_depth != 0) self.overflow = true;
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_utf8_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

fn renderImpl(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();

    var writer = Writer{};
    javascript.write(input_buf[0..input_len], &writer);
    writer.finish();
    if (writer.overflow) @trap();
    return @intCast(writer.idx);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn runForTest(input: []const u8) []const u8 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const output_len = renderImpl(@intCast(input.len));
    return output_buf[0..output_len];
}

test "writes the shared semantic classes" {
    const input = "async function render(value) { return Promise.resolve(value ?? null); }";
    const expected = "<span class=\"syntax-keyword\">async</span> <span class=\"syntax-keyword\">function</span> <span class=\"syntax-function\">render</span>(value) { <span class=\"syntax-keyword\">return</span> <span class=\"syntax-type\">Promise</span>.<span class=\"syntax-function\">resolve</span>(value <span class=\"syntax-operator\">??</span> <span class=\"syntax-constant\">null</span>); }";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "escapes raw JavaScript as HTML" {
    const input = "const message = '<QIP & JavaScript>';";
    const expected = "<span class=\"syntax-keyword\">const</span> message <span class=\"syntax-operator\">=</span> <span class=\"syntax-string\">&#39;&lt;QIP &amp; JavaScript&gt;&#39;</span>;";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "maps JavaScript word operators and this like Shiki" {
    const input = "this.value = new Value() instanceof Object; typeof this.value; object.get();";
    const expected = "<span class=\"syntax-constant\">this</span>.value <span class=\"syntax-operator\">=</span> <span class=\"syntax-operator\">new</span> <span class=\"syntax-function\">Value</span>() <span class=\"syntax-operator\">instanceof</span> <span class=\"syntax-type\">Object</span>; <span class=\"syntax-operator\">typeof</span> <span class=\"syntax-constant\">this</span>.value; object.<span class=\"syntax-function\">get</span>();";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "uses function context for anonymous functions and object properties" {
    const input = "const task = function (callback) { return callback; }; const queue = { then: function (resolve) { return resolve; }, get: function () { return arguments; }, type: 'task' }; exports.Component = Component.prototype;";
    const expected = "<span class=\"syntax-keyword\">const</span> <span class=\"syntax-function\">task</span> <span class=\"syntax-operator\">=</span> <span class=\"syntax-keyword\">function</span> (callback) { <span class=\"syntax-keyword\">return</span> callback; }; <span class=\"syntax-keyword\">const</span> queue <span class=\"syntax-operator\">=</span> { <span class=\"syntax-function\">then</span>: <span class=\"syntax-keyword\">function</span> (resolve) { <span class=\"syntax-keyword\">return</span> resolve; }, <span class=\"syntax-function\">get</span>: <span class=\"syntax-keyword\">function</span> () { <span class=\"syntax-keyword\">return</span> <span class=\"syntax-constant\">arguments</span>; }, type: <span class=\"syntax-string\">&#39;task&#39;</span> }; <span class=\"syntax-type\">exports</span>.Component <span class=\"syntax-operator\">=</span> <span class=\"syntax-type\">Component</span>.prototype;";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "treats JavaScript property and variable names as identifiers" {
    const input = "function describe(type) { return Symbol.for(type); } function of(value) { return value instanceof of; } module.exports = ioInfo.default; const value = new p; const event = new window.ErrorEvent();";
    const expected = "<span class=\"syntax-keyword\">function</span> <span class=\"syntax-function\">describe</span>(type) { <span class=\"syntax-keyword\">return</span> Symbol.<span class=\"syntax-function\">for</span>(type); } <span class=\"syntax-keyword\">function</span> <span class=\"syntax-function\">of</span>(value) { <span class=\"syntax-keyword\">return</span> value <span class=\"syntax-operator\">instanceof</span> <span class=\"syntax-type\">of</span>; } <span class=\"syntax-type\">module</span>.<span class=\"syntax-type\">exports</span> <span class=\"syntax-operator\">=</span> ioInfo.default; <span class=\"syntax-keyword\">const</span> value <span class=\"syntax-operator\">=</span> <span class=\"syntax-operator\">new</span> p; <span class=\"syntax-keyword\">const</span> event <span class=\"syntax-operator\">=</span> <span class=\"syntax-operator\">new</span> window.<span class=\"syntax-function\">ErrorEvent</span>();";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "distinguishes conditional and object property colons" {
    const input = "const result = ready ? identity : function () {}; const object = { value: function () {} };";
    const expected = "<span class=\"syntax-keyword\">const</span> result <span class=\"syntax-operator\">=</span> ready <span class=\"syntax-operator\">?</span> identity <span class=\"syntax-operator\">:</span> <span class=\"syntax-keyword\">function</span> () {}; <span class=\"syntax-keyword\">const</span> object <span class=\"syntax-operator\">=</span> { <span class=\"syntax-function\">value</span>: <span class=\"syntax-keyword\">function</span> () {} };";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "uses value context for JavaScript constructor objects" {
    const input = "const isArray = Array.isArray; const now = Date.now; const map = new Map();";
    const expected = "<span class=\"syntax-keyword\">const</span> isArray <span class=\"syntax-operator\">=</span> Array.isArray; <span class=\"syntax-keyword\">const</span> now <span class=\"syntax-operator\">=</span> Date.now; <span class=\"syntax-keyword\">const</span> map <span class=\"syntax-operator\">=</span> <span class=\"syntax-operator\">new</span> <span class=\"syntax-function\">Map</span>();";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "distinguishes accessor keywords from identifiers" {
    const input = "function setToArray(set) { return set; } const object = { get value() { return 1; } };";
    const expected = "<span class=\"syntax-keyword\">function</span> <span class=\"syntax-function\">setToArray</span>(set) { <span class=\"syntax-keyword\">return</span> set; } <span class=\"syntax-keyword\">const</span> object <span class=\"syntax-operator\">=</span> { <span class=\"syntax-keyword\">get</span> <span class=\"syntax-function\">value</span>() { <span class=\"syntax-keyword\">return</span> <span class=\"syntax-number\">1</span>; } };";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "treats uppercase JavaScript parameters as variables" {
    const input = "function useContext(Context) { return Context; }";
    const expected = "<span class=\"syntax-keyword\">function</span> <span class=\"syntax-function\">useContext</span>(Context) { <span class=\"syntax-keyword\">return</span> Context; }";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}
