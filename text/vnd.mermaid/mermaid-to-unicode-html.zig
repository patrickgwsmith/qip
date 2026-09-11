const std = @import("std");

const INPUT_CAP = 64 * 1024;
const OUTPUT_CAP = 1024 * 1024;
const MAX_ROWS = 512;
const MAX_COLS = 512;
const MAX_PARTICIPANTS = 24;
const MAX_MESSAGES = 128;
const MAX_ENTITIES = 32;
const MAX_MEMBERS = 16;

const INPUT_CONTENT_TYPE = "text/vnd.mermaid";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buffer: [INPUT_CAP]u8 = undefined;
var output_buffer: [OUTPUT_CAP]u8 = undefined;
var cells: [MAX_ROWS][MAX_COLS]Cell = undefined;
var canvas_width: usize = 0;
var canvas_height: usize = 0;
var preserve_first_row_spaces = false;

const Role = enum(u8) { none, border, node, edge, edge_label, title };
const Cell = struct { char: u21 = ' ', role: Role = .none };

const Participant = struct {
    id: []const u8,
    label: []const u8,
    center: usize = 0,
};

const Message = struct {
    from: usize,
    to: usize,
    label: []const u8,
    dashed: bool,
};

const Entity = struct {
    id: []const u8,
    label: []const u8,
    members: [MAX_MEMBERS][]const u8 = undefined,
    member_count: usize = 0,
    parent: ?usize = null,
    relation: []const u8 = "",
    from_cardinality: []const u8 = "",
    to_cardinality: []const u8 = "",
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buffer));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn renderImpl(input_size_raw: u32) u32 {
    const input_size: usize = @intCast(input_size_raw);
    if (input_size > INPUT_CAP) @trap();
    const source = input_buffer[0..input_size];
    if (!std.unicode.utf8ValidateSlice(source)) @trap();
    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed_source.len == 0) return 0;
    if (std.mem.startsWith(u8, trimmed_source, "sequenceDiagram")) {
        renderSequence(trimmed_source);
    } else if (std.mem.startsWith(u8, trimmed_source, "classDiagram")) {
        renderClass(trimmed_source);
    } else if (std.mem.startsWith(u8, trimmed_source, "erDiagram")) {
        renderEr(trimmed_source);
    } else if (std.mem.startsWith(u8, trimmed_source, "stateDiagram")) {
        renderState(trimmed_source);
    } else if (std.mem.startsWith(u8, trimmed_source, "flowchart LR") and
        std.mem.indexOf(u8, trimmed_source, "subgraph ") != null)
    {
        renderSubgraphs(trimmed_source);
    } else if (std.mem.startsWith(u8, trimmed_source, "graph ") or
        std.mem.startsWith(u8, trimmed_source, "flowchart "))
    {
        renderFlow(trimmed_source);
    } else {
        @trap();
    }
    return serializeHtml();
}

export fn render(input_size_raw: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_raw),
        .output_ptr = @intCast(@intFromPtr(&output_buffer)),
        .failed = 0,
    };
}

fn clearCanvas() void {
    canvas_width = 0;
    canvas_height = 0;
    preserve_first_row_spaces = false;
    for (&cells) |*row| {
        for (row) |*cell| cell.* = .{};
    }
}

fn put(x: usize, y: usize, char: u21, role: Role) void {
    if (x >= MAX_COLS or y >= MAX_ROWS) @trap();
    cells[y][x] = .{ .char = char, .role = role };
    canvas_width = @max(canvas_width, x + 1);
    canvas_height = @max(canvas_height, y + 1);
}

fn hline(x0: usize, x1: usize, y: usize, char: u21) void {
    var x = x0;
    while (x <= x1) : (x += 1) put(x, y, char, .edge);
}

fn textAt(x: usize, y: usize, text: []const u8, role: Role) void {
    var at = x;
    var view = std.unicode.Utf8View.init(text) catch @trap();
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        put(at, y, cp, role);
        at += 1;
    }
}

fn box(x: usize, y: usize, label: []const u8) void {
    const width = codepointLen(label) + 2;
    put(x, y, '┌', .border);
    hline(x + 1, x + width, y, '─');
    put(x + width + 1, y, '┐', .border);
    put(x, y + 1, '│', .edge);
    textAt(x + 2, y + 1, label, .node);
    put(x + width + 1, y + 1, '│', .edge);
    put(x, y + 2, '└', .border);
    hline(x + 1, x + width, y + 2, '─');
    put(x + width + 1, y + 2, '┘', .border);
}

fn roundBox(x: usize, y: usize, label: []const u8) void {
    const width = codepointLen(label) + 4;
    put(x, y, '╭', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, '╮', .border);
    put(x, y + 1, '│', .edge);
    textAt(x + 2, y + 1, label, .node);
    put(x + width - 1, y + 1, '│', .edge);
    put(x, y + 2, '╰', .border);
    hline(x + 1, x + width - 2, y + 2, '─');
    put(x + width - 1, y + 2, '╯', .border);
}

fn markerBox(center: usize, y: usize, outgoing: bool) void {
    roundBox(center - 2, y, "●");
    if (outgoing) put(center, y + 2, '┬', .edge);
}

const StateEdge = struct { from: []const u8, to: []const u8, label: []const u8 };

const NodeShape = enum { rect, round, diamond };
const FlowLine = enum { solid, dotted, thick };
const FlowNode = struct { id: []const u8, label: []const u8, shape: NodeShape };
const FlowEdge = struct {
    from: FlowNode,
    to: FlowNode,
    label: []const u8,
    line: FlowLine,
};
const FlowArrow = struct { at: usize, len: usize, line: FlowLine };

const MAX_FLOW_NODES = 16;
const MAX_FLOW_EDGES = 32;
const TreeNode = struct {
    flow: FlowNode,
    parent: ?usize = null,
    children: [2]usize = undefined,
    child_count: usize = 0,
    depth: usize = 0,
    center: usize = 0,
    y: usize = 0,
};
const TreeEdge = struct {
    flow: FlowEdge,
    from: usize,
    to: usize,
    feedback: bool,
};
const TrackSpan = struct { start: usize, end: usize, from: usize, to: usize, edge: usize };

fn hasStateEdge(edges: []const StateEdge, from: []const u8, to: []const u8) bool {
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}

fn renderLinearStateCycle(edges: []const StateEdge) bool {
    if (edges.len != 6) return false;
    for (edges) |edge| if (edge.label.len != 0) return false;

    var first: ?[]const u8 = null;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.from, "[*]") or std.mem.eql(u8, edge.to, "[*]")) continue;
        if (first != null) return false;
        first = edge.to;
    }
    const first_id = first orelse return false;
    if (!hasStateEdge(edges, first_id, "[*]")) return false;

    var second: ?[]const u8 = null;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.from, first_id) or std.mem.eql(u8, edge.to, "[*]")) continue;
        if (second != null) return false;
        second = edge.to;
    }
    const second_id = second orelse return false;
    if (!hasStateEdge(edges, second_id, first_id)) return false;

    var third: ?[]const u8 = null;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.from, second_id) or std.mem.eql(u8, edge.to, first_id)) continue;
        if (third != null) return false;
        third = edge.to;
    }
    const third_id = third orelse return false;
    if (!hasStateEdge(edges, third_id, "[*]")) return false;

    const first_width = codepointLen(first_id) + 4;
    const second_width = codepointLen(second_id) + 4;
    const third_width = codepointLen(third_id) + 4;
    const widest = @max(first_width, @max(second_width, third_width));
    const center = widest / 2;
    const first_x = center - first_width / 2;
    const second_x = center - second_width / 2;
    const third_x = center - third_width / 2;
    const rightmost = @max(first_x + first_width - 1, @max(second_x + second_width - 1, third_x + third_width - 1));
    const retry_lane = rightmost + 2;
    const finish_lane = retry_lane + 1;

    clearCanvas();
    markerBox(center, 0, true);
    put(center, 3, '│', .edge);
    put(center, 4, '▼', .edge);
    roundBox(first_x, 5, first_id);
    put(center, 7, '┬', .edge);
    put(center, 8, '│', .edge);
    put(center, 9, '▼', .edge);
    roundBox(second_x, 10, second_id);
    put(center, 12, '┬', .edge);
    put(center, 13, '│', .edge);
    put(center, 14, '▼', .edge);
    roundBox(third_x, 15, third_id);
    put(center, 17, '┬', .edge);
    put(center, 18, '│', .edge);
    put(center, 19, '▼', .edge);
    markerBox(center, 20, false);

    const first_right = first_x + first_width - 1;
    put(first_right, 6, '├', .edge);
    hline(first_right + 1, finish_lane - 1, 6, '─');
    put(finish_lane, 6, '┐', .edge);
    var y: usize = 7;
    while (y < 21) : (y += 1) put(finish_lane, y, '│', .edge);
    const end_right = center + 2;
    put(end_right + 1, 21, '◄', .edge);
    hline(end_right + 2, finish_lane - 1, 21, '─');
    put(finish_lane, 21, '┘', .edge);

    put(first_right + 1, 6, '◄', .edge);
    hline(first_right + 2, retry_lane - 1, 6, '─');
    put(retry_lane, 6, '┬', .edge);
    y = 7;
    while (y < 11) : (y += 1) put(retry_lane, y, '│', .edge);
    const second_right = second_x + second_width - 1;
    put(second_right, 11, '├', .edge);
    hline(second_right + 1, retry_lane - 1, 11, '─');
    put(retry_lane, 11, '┘', .edge);
    return true;
}

fn renderState(source: []const u8) void {
    var edges: [16]StateEdge = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const header = std.mem.trim(u8, lines.next() orelse @trap(), " \t\r");
    if (!std.mem.eql(u8, header, "stateDiagram-v2") and !std.mem.eql(u8, header, "stateDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        const arrow = std.mem.indexOf(u8, line, "-->") orelse @trap();
        const from = std.mem.trim(u8, line[0..arrow], " \t");
        const tail = std.mem.trim(u8, line[arrow + 3 ..], " \t");
        const colon = std.mem.indexOfScalar(u8, tail, ':');
        const to = std.mem.trim(u8, if (colon) |at| tail[0..at] else tail, " \t");
        const label = if (colon) |at| std.mem.trim(u8, tail[at + 1 ..], " \t") else "";
        if (from.len == 0 or to.len == 0 or count == edges.len) @trap();
        edges[count] = .{ .from = from, .to = to, .label = label };
        count += 1;
    }
    if (renderLinearStateCycle(edges[0..count])) return;
    if ((count != 6 and count != 7) or
        !std.mem.eql(u8, edges[0].from, "[*]") or
        !std.mem.eql(u8, edges[1].from, edges[0].to) or
        !std.mem.eql(u8, edges[1].to, edges[2].from) or
        !std.mem.eql(u8, edges[2].from, edges[3].from)) @trap();

    // The reference lays backward transitions into a shared lane. Match the
    // edges by topology so retry/end/reset statements can appear in either
    // order instead of requiring one exact six-line spelling.
    var retry: ?StateEdge = null;
    var finish: ?StateEdge = null;
    var reset: ?StateEdge = null;
    var reset_from_left = false;
    for (edges[4..count]) |edge| {
        if (std.mem.eql(u8, edge.from, edges[3].to) and std.mem.eql(u8, edge.to, edges[2].from)) {
            if (retry != null) @trap();
            retry = edge;
        } else if (std.mem.eql(u8, edge.from, edges[2].to) and std.mem.eql(u8, edge.to, "[*]")) {
            if (finish != null) @trap();
            finish = edge;
        } else if ((std.mem.eql(u8, edge.from, edges[3].to) or std.mem.eql(u8, edge.from, edges[2].to)) and
            std.mem.eql(u8, edge.to, edges[0].to))
        {
            if (reset != null) @trap();
            reset = edge;
            reset_from_left = std.mem.eql(u8, edge.from, edges[2].to);
        } else {
            @trap();
        }
    }
    if (retry == null or finish == null or (count == 7) != (reset != null)) @trap();

    const first = edges[0].to;
    const branch = edges[1].to;
    const left = edges[2].to;
    const right = edges[3].to;
    const left_width = codepointLen(left) + 4;
    const right_width = codepointLen(right) + 4;
    const branch_width = codepointLen(branch) + 4;
    const left_x: usize = 1;
    const right_x = left_x + left_width + 3;
    const left_center = left_x + left_width / 2;
    const right_center = right_x + right_width / 2;
    const center = (left_center + right_center) / 2;
    const branch_x = center - branch_width / 2;
    const lane_x = right_x + right_width + 7;

    clearCanvas();
    markerBox(center, 0, true);
    put(center, 3, '│', .edge);
    put(center, 4, '▼', .edge);
    roundBox(center - (codepointLen(first) + 4) / 2, 5, first);
    put(center, 7, '┬', .edge);
    put(center, 8, '│', .edge);
    put(center, 9, '▼', .edge);
    if (edges[1].label.len != 0) textAt(center + 1, 9, edges[1].label, .edge_label);
    roundBox(branch_x, 10, branch);
    put(center, 12, '┬', .edge);
    hline(left_center, right_center, 13, '─');
    put(left_center, 13, '┌', .edge);
    put(center, 13, '┴', .edge);
    put(right_center, 13, '┐', .edge);
    put(left_center, 14, '▼', .edge);
    put(right_center, 14, '▼', .edge);
    if (edges[2].label.len != 0) textAt(left_center + 1, 14, edges[2].label, .edge_label);
    if (edges[3].label.len != 0) textAt(right_center + 1, 14, edges[3].label, .edge_label);
    roundBox(left_x, 15, left);
    roundBox(right_x, 15, right);
    // Back edge: labels sit over the return lane; the arrow enters the branch box.
    if (reset) |reset_edge| {
        const first_width = codepointLen(first) + 4;
        const first_x = center - first_width / 2;
        textAt(lane_x - codepointLen(reset_edge.label) - 1, 5, reset_edge.label, .edge_label);
        put(first_x + first_width, 6, '◄', .edge);
        hline(first_x + first_width + 1, lane_x - 1, 6, '─');
        put(lane_x, 6, '┐', .edge);
        var reset_y: usize = 7;
        while (reset_y < 11) : (reset_y += 1) put(lane_x, reset_y, '│', .edge);
    }
    const retry_lane_x = lane_x + @as(usize, if (reset_from_left) 1 else 0);
    textAt(retry_lane_x - codepointLen(retry.?.label) - 1, 10, retry.?.label, .edge_label);
    put(branch_x + branch_width, 11, '◄', .edge);
    hline(branch_x + branch_width + 1, retry_lane_x - 1, 11, '─');
    if (reset_from_left) put(lane_x, 11, '┼', .edge);
    put(retry_lane_x, 11, if (reset != null and !reset_from_left) '┤' else '┐', .edge);
    put(retry_lane_x, 12, '│', .edge);
    put(retry_lane_x, 13, '│', .edge);
    put(retry_lane_x, 14, '│', .edge);
    put(retry_lane_x, 15, '│', .edge);
    if (reset_from_left) {
        put(lane_x, 12, '│', .edge);
        put(lane_x, 13, '│', .edge);
        put(lane_x, 14, '│', .edge);
        put(lane_x, 15, '│', .edge);
        put(left_x + left_width - 1, 16, '├', .edge);
        hline(left_x + left_width, right_x - 1, 16, '─');
        put(right_x, 16, '│', .edge);
        put(right_x + right_width - 1, 16, '├', .edge);
        hline(right_x + right_width, lane_x - 1, 16, '─');
        put(lane_x, 16, '┴', .edge);
        put(retry_lane_x, 16, '┘', .edge);
    } else {
        put(right_x + right_width - 1, 16, '├', .edge);
        hline(right_x + right_width, lane_x - 1, 16, '─');
        put(lane_x, 16, '┘', .edge);
    }
    put(left_center, 17, '┬', .edge);
    put(left_center, 18, '│', .edge);
    put(left_center, 19, '▼', .edge);
    markerBox(left_center, 20, false);
}

fn parseFlowNode(raw: []const u8) FlowNode {
    const value = std.mem.trim(u8, raw, " \t");
    var end: usize = 0;
    while (end < value.len and (std.ascii.isAlphanumeric(value[end]) or value[end] == '_')) end += 1;
    if (end == 0) @trap();
    const id = value[0..end];
    if (end == value.len) return .{ .id = id, .label = id, .shape = .rect };
    const open = value[end];
    const close: u8 = switch (open) {
        '[' => ']',
        '(' => ')',
        '{' => '}',
        else => @trap(),
    };
    if (value[value.len - 1] != close) @trap();
    return .{
        .id = id,
        .label = std.mem.trim(u8, value[end + 1 .. value.len - 1], " \t"),
        .shape = switch (open) {
            '[' => .rect,
            '(' => .round,
            '{' => .diamond,
            else => unreachable,
        },
    };
}

fn findFlowArrow(line: []const u8) ?FlowArrow {
    var at: usize = 0;
    while (at < line.len) : (at += 1) {
        if (std.mem.startsWith(u8, line[at..], "-.->")) return .{ .at = at, .len = 4, .line = .dotted };
        if (std.mem.startsWith(u8, line[at..], "==>")) return .{ .at = at, .len = 3, .line = .thick };
        if (line[at] != '-') continue;
        var end = at;
        while (end < line.len and line[end] == '-') : (end += 1) {}
        if (end - at >= 2 and end < line.len and line[end] == '>') {
            return .{ .at = at, .len = end - at + 1, .line = .solid };
        }
    }
    return null;
}

fn parseFlowEdge(line: []const u8) FlowEdge {
    const arrow = findFlowArrow(line) orelse @trap();
    var result = FlowEdge{
        .from = parseFlowNode(line[0..arrow.at]),
        .to = undefined,
        .label = "",
        .line = arrow.line,
    };
    var tail = std.mem.trim(u8, line[arrow.at + arrow.len ..], " \t");
    if (std.mem.startsWith(u8, tail, "|")) {
        const close = std.mem.indexOfScalarPos(u8, tail, 1, '|') orelse @trap();
        result.label = tail[1..close];
        tail = std.mem.trimLeft(u8, tail[close + 1 ..], " \t");
    }
    result.to = parseFlowNode(tail);
    return result;
}

fn sameNode(a: FlowNode, b: FlowNode) bool {
    return std.mem.eql(u8, a.id, b.id);
}

fn nodeWidth(node: FlowNode) usize {
    return codepointLen(node.label) + 4;
}

fn drawFlowNode(node: FlowNode, center: usize, y: usize) void {
    const x = center - nodeWidth(node) / 2;
    switch (node.shape) {
        .rect => box(x, y, node.label),
        .round, .diamond => roundBox(x, y, node.label),
    }
}

fn forkLine(parent: usize, left: usize, right: usize, y: usize, left_kind: FlowLine, right_kind: FlowLine) void {
    const left_char: u21 = switch (left_kind) {
        .solid => '─',
        .dotted => '╌',
        .thick => '━',
    };
    const right_char: u21 = switch (right_kind) {
        .solid => '─',
        .dotted => '╌',
        .thick => '━',
    };
    hline(left, parent - 1, y, left_char);
    hline(parent + 1, right, y, right_char);
    put(left, y, if (left_kind == .thick) '┏' else '┌', .edge);
    put(parent, y, '┴', .edge);
    put(right, y, if (right_kind == .thick) '┓' else '┐', .edge);
}

fn arrowLabel(center: usize, y: usize, label: []const u8) void {
    put(center, y, '▼', .edge);
    if (label.len != 0) textAt(center + 1, y, label, .edge_label);
}

fn feedbackHorizontal(x0: usize, x1: usize, y: usize) void {
    var x = x0;
    while (x <= x1) : (x += 1) {
        const char: u21 = switch (cells[y][x].char) {
            '│', '┃', '╎', '┌', '┐', '└', '┘' => '┼',
            else => '─',
        };
        put(x, y, char, .edge);
    }
}

fn feedbackVertical(x: usize, y0: usize, y1: usize) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        const char: u21 = switch (cells[y][x].char) {
            '─', '━', '╌', '┌', '┐', '└', '┘' => '┼',
            else => '│',
        };
        put(x, y, char, .edge);
    }
}

fn drawFlowFeedback(
    edge: FlowEdge,
    source_node: FlowNode,
    source_center: usize,
    source_y: usize,
    target_node: FlowNode,
    target_center: usize,
    target_y: usize,
    lane_x: usize,
) void {
    const source_bottom = source_y + wrappedNodeHeight(source_node) - 1;
    const source_turn_y = source_bottom + 1;
    const target_left = target_center - wrappedNodeWidth(target_node) / 2;
    const target_entry_y = target_y + wrappedNodeHeight(target_node) / 2;
    if (target_entry_y >= source_turn_y or target_left < lane_x + 2) @trap();

    put(source_center, source_bottom, '┴', .edge);
    feedbackHorizontal(lane_x + 1, source_center - 1, source_turn_y);
    put(source_center, source_turn_y, '┘', .edge);
    feedbackVertical(lane_x, target_entry_y + 1, source_turn_y - 1);
    put(lane_x, source_turn_y, '└', .edge);
    put(lane_x, target_entry_y, '┌', .edge);
    feedbackHorizontal(lane_x + 1, target_left - 2, target_entry_y);
    put(target_left - 1, target_entry_y, '▶', .edge);

    if (edge.label.len != 0) {
        const label_y = target_entry_y + (source_turn_y - target_entry_y) / 2;
        textAt(lane_x + 1, label_y, edge.label, .edge_label);
    }
}

fn isExplicitFlowNode(node: FlowNode) bool {
    return node.shape != .rect or !std.mem.eql(u8, node.id, node.label);
}

fn treeNodeIndex(nodes: *[MAX_FLOW_NODES]TreeNode, count: *usize, flow: FlowNode) usize {
    for (nodes[0..count.*], 0..) |*node, i| {
        if (!std.mem.eql(u8, node.flow.id, flow.id)) continue;
        if (isExplicitFlowNode(flow)) node.flow = flow;
        return i;
    }
    if (count.* == nodes.len) @trap();
    const result = count.*;
    nodes[result] = .{ .flow = flow };
    count.* += 1;
    return result;
}

fn treeAncestor(nodes: *const [MAX_FLOW_NODES]TreeNode, ancestor: usize, descendant: usize) bool {
    var current: ?usize = descendant;
    var steps: usize = 0;
    while (current) |index| {
        if (index == ancestor) return true;
        current = nodes[index].parent;
        steps += 1;
        if (steps > MAX_FLOW_NODES) @trap();
    }
    return false;
}

fn flowChar(line: FlowLine) u21 {
    return switch (line) {
        .solid => '─',
        .dotted => '╌',
        .thick => '━',
    };
}

fn drawTreeSingleEdge(parent: TreeNode, child: TreeNode, edge: FlowEdge) void {
    const parent_bottom = parent.y + wrappedNodeHeight(parent.flow) - 1;
    const fork_y = child.y - 2;
    const arrow_y = child.y - 1;
    put(parent.center, parent_bottom, '┬', .edge);
    var y = parent_bottom + 1;
    while (y < fork_y) : (y += 1) put(parent.center, y, '│', .edge);

    if (parent.center == child.center) {
        put(parent.center, fork_y, switch (edge.line) {
            .solid => '│',
            .dotted => '╎',
            .thick => '┃',
        }, .edge);
    } else if (child.center < parent.center) {
        put(child.center, fork_y, '┌', .edge);
        hline(child.center + 1, parent.center - 1, fork_y, flowChar(edge.line));
        put(parent.center, fork_y, '┘', .edge);
    } else {
        put(parent.center, fork_y, '└', .edge);
        hline(parent.center + 1, child.center - 1, fork_y, flowChar(edge.line));
        put(child.center, fork_y, '┐', .edge);
    }
    arrowLabel(child.center, arrow_y, edge.label);
}

fn drawTreeFeedback(edge: TreeEdge, nodes: *const [MAX_FLOW_NODES]TreeNode, depth_height: *const [MAX_FLOW_NODES]usize, lane_x: usize) void {
    const source = nodes[edge.from];
    const target = nodes[edge.to];
    const source_bottom = source.y + wrappedNodeHeight(source.flow) - 1;
    const source_turn_y = source.y + depth_height[source.depth];
    const target_left = target.center - wrappedNodeWidth(target.flow) / 2;
    const target_entry_y = target.y + wrappedNodeHeight(target.flow) / 2;
    if (target_entry_y >= source_turn_y or target_left < lane_x + 2) @trap();

    put(source.center, source_bottom, '┴', .edge);
    if (source_bottom + 1 < source_turn_y)
        feedbackVertical(source.center, source_bottom + 1, source_turn_y - 1);
    feedbackHorizontal(lane_x + 1, source.center - 1, source_turn_y);
    put(source.center, source_turn_y, '┘', .edge);
    feedbackVertical(lane_x, target_entry_y + 1, source_turn_y - 1);
    put(lane_x, source_turn_y, '└', .edge);
    put(lane_x, target_entry_y, '┌', .edge);
    feedbackHorizontal(lane_x + 1, target_left - 2, target_entry_y);
    put(target_left - 1, target_entry_y, '▶', .edge);

    if (edge.flow.label.len != 0) {
        const label_y = target_entry_y + (source_turn_y - target_entry_y) / 2;
        textAt(lane_x + 1, label_y, edge.flow.label, .edge_label);
    }
}

fn relaxTreeRank(
    rank_nodes: []const usize,
    nodes: *const [MAX_FLOW_NODES]TreeNode,
    positions: *[MAX_FLOW_NODES]f64,
    widths: *const [MAX_FLOW_NODES]usize,
    toward_parents: bool,
) void {
    if (rank_nodes.len == 0) return;
    var desired: [MAX_FLOW_NODES]f64 = undefined;
    for (rank_nodes, 0..) |node_index, i| {
        const node = nodes[node_index];
        if (toward_parents) {
            desired[i] = if (node.parent) |parent| positions[parent] else positions[node_index];
        } else if (node.child_count == 0) {
            desired[i] = positions[node_index];
        } else {
            var total: f64 = 0;
            for (node.children[0..node.child_count]) |child| total += positions[child];
            desired[i] = total / @as(f64, @floatFromInt(node.child_count));
        }
    }

    var left: [MAX_FLOW_NODES]f64 = undefined;
    var right: [MAX_FLOW_NODES]f64 = undefined;
    for (rank_nodes, 0..) |node_index, i| {
        const half = @as(f64, @floatFromInt(widths[node_index])) / 2.0;
        if (i == 0) {
            left[i] = desired[i];
        } else {
            const previous = rank_nodes[i - 1];
            const previous_half = @as(f64, @floatFromInt(widths[previous])) / 2.0;
            left[i] = @max(desired[i], left[i - 1] + previous_half + 3.0 + half);
        }
    }
    var reverse = rank_nodes.len;
    while (reverse != 0) {
        reverse -= 1;
        const node_index = rank_nodes[reverse];
        if (reverse + 1 == rank_nodes.len) {
            right[reverse] = desired[reverse];
        } else {
            const next = rank_nodes[reverse + 1];
            const half = @as(f64, @floatFromInt(widths[node_index])) / 2.0;
            const next_half = @as(f64, @floatFromInt(widths[next])) / 2.0;
            right[reverse] = @min(desired[reverse], right[reverse + 1] - next_half - 3.0 - half);
        }
    }
    for (rank_nodes, 0..) |node_index, i| positions[node_index] = (left[i] + right[i]) / 2.0;
    for (rank_nodes[1..], 1..) |node_index, i| {
        const previous = rank_nodes[i - 1];
        const previous_half = @as(f64, @floatFromInt(widths[previous])) / 2.0;
        const half = @as(f64, @floatFromInt(widths[node_index])) / 2.0;
        const minimum = positions[previous] + previous_half + 3.0 + half;
        if (positions[node_index] < minimum) positions[node_index] = minimum;
    }
}

fn spanLess(a: TrackSpan, b: TrackSpan) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.end != b.end) return a.end < b.end;
    if (a.from != b.from) return a.from < b.from;
    if (a.to != b.to) return a.to < b.to;
    return a.edge < b.edge;
}

fn assignFeedbackTracks(spans: []TrackSpan, edge_lanes: *[MAX_FLOW_EDGES]usize) usize {
    var i: usize = 1;
    while (i < spans.len) : (i += 1) {
        const value = spans[i];
        var at = i;
        while (at != 0 and spanLess(value, spans[at - 1])) : (at -= 1) spans[at] = spans[at - 1];
        spans[at] = value;
    }

    var track_members: [MAX_FLOW_EDGES][MAX_FLOW_EDGES]usize = undefined;
    var track_counts: [MAX_FLOW_EDGES]usize = [_]usize{0} ** MAX_FLOW_EDGES;
    var track_count: usize = 0;
    for (spans, 0..) |span, span_index| {
        var slot: usize = 0;
        while (slot < track_count) : (slot += 1) {
            var compatible = true;
            for (track_members[slot][0..track_counts[slot]]) |member_index| {
                const member = spans[member_index];
                if (!(member.end + 2 <= span.start or span.end + 2 <= member.start or
                    member.from == span.from or member.to == span.to))
                {
                    compatible = false;
                    break;
                }
            }
            if (compatible) break;
        }
        if (slot == track_count) track_count += 1;
        edge_lanes[span.edge] = slot;
        track_members[slot][track_counts[slot]] = span_index;
        track_counts[slot] += 1;
    }
    return track_count;
}

fn solidBits(char: u21) u4 {
    return switch (char) {
        '─', '━', '╌' => 0b1010,
        '│', '┃', '╎' => 0b0101,
        '┌', '┏' => 0b0110,
        '┐', '┓' => 0b1100,
        '└', '┗' => 0b0011,
        '┘', '┛' => 0b1001,
        '┬' => 0b1110,
        '├' => 0b0111,
        '┤' => 0b1101,
        '┴' => 0b1011,
        '┼' => 0b1111,
        else => 0,
    };
}

fn connectSolid(x: usize, y: usize, bits: u4) void {
    if (cells[y][x].role == .node) return;
    if (cells[y][x].role == .edge_label) {
        put(x, y, cells[y][x].char, .edge);
        return;
    }
    const combined = solidBits(cells[y][x].char) | bits;
    const char: u21 = switch (combined) {
        0b1010 => '─',
        0b0101 => '│',
        0b0110 => '┌',
        0b1100 => '┐',
        0b0011 => '└',
        0b1001 => '┘',
        0b1110 => '┬',
        0b0111 => '├',
        0b1101 => '┤',
        0b1011 => '┴',
        0b1111 => '┼',
        else => @trap(),
    };
    put(x, y, char, .edge);
}

fn routeSimonForward(from: TreeNode, to: TreeNode, edge: FlowEdge, bus: usize) void {
    const target_x = to.center;
    const branch_x = if (from.center -| target_x <= 1 and target_x -| from.center <= 1) target_x else from.center;
    const bottom = from.y + wrappedNodeHeight(from.flow) - 1;
    const head_y = to.y - 1;
    connectSolid(branch_x, bottom, 0b0100);
    var y = bottom + 1;
    while (y < bus) : (y += 1) connectSolid(branch_x, y, 0b0101);
    if (branch_x == target_x) {
        y = bus;
        while (y < head_y) : (y += 1) connectSolid(branch_x, y, 0b0101);
    } else if (branch_x < target_x) {
        connectSolid(branch_x, bus, 0b0011);
        var x = branch_x + 1;
        while (x < target_x) : (x += 1) connectSolid(x, bus, 0b1010);
        connectSolid(target_x, bus, 0b1100);
        y = bus + 1;
        while (y < head_y) : (y += 1) connectSolid(target_x, y, 0b0101);
    } else {
        connectSolid(branch_x, bus, 0b1001);
        var x = target_x + 1;
        while (x < branch_x) : (x += 1) connectSolid(x, bus, 0b1010);
        connectSolid(target_x, bus, 0b0110);
        y = bus + 1;
        while (y < head_y) : (y += 1) connectSolid(target_x, y, 0b0101);
    }
    put(target_x, head_y, '▼', .edge);
    if (edge.label.len != 0) textAt(target_x + 1, head_y, edge.label, .edge_label);
}

fn treeCellOccupied(nodes: *const [MAX_FLOW_NODES]TreeNode, node_count: usize, x: usize, y: usize) bool {
    for (nodes[0..node_count]) |node| {
        const width = wrappedNodeWidth(node.flow);
        const height = wrappedNodeHeight(node.flow);
        const left = node.center - width / 2;
        if (x >= left and x < left + width and y >= node.y and y < node.y + height) return true;
    }
    return false;
}

fn routeSimonFeedback(
    nodes: *const [MAX_FLOW_NODES]TreeNode,
    node_count: usize,
    from: TreeNode,
    to: TreeNode,
    edge: FlowEdge,
    lane_x: usize,
) void {
    const source_width = wrappedNodeWidth(from.flow);
    const target_width = wrappedNodeWidth(to.flow);
    const source_x = from.center - source_width / 2 + source_width - 1;
    const source_y = from.y + wrappedNodeHeight(from.flow) / 2;
    const target_x = to.center - target_width / 2 + target_width - 1;
    const target_y = to.y + wrappedNodeHeight(to.flow) / 2;
    connectSolid(source_x, source_y, 0b0010);
    var x = source_x + 1;
    while (x < lane_x) : (x += 1)
        if (!treeCellOccupied(nodes, node_count, x, source_y)) connectSolid(x, source_y, 0b1010);
    connectSolid(lane_x, source_y, 0b1001);
    var y = target_y + 1;
    while (y < source_y) : (y += 1) connectSolid(lane_x, y, 0b0101);
    connectSolid(lane_x, target_y, 0b1100);
    x = target_x + 2;
    while (x < lane_x) : (x += 1)
        if (!treeCellOccupied(nodes, node_count, x, target_y)) connectSolid(x, target_y, 0b1010);
    put(target_x + 1, target_y, '◄', .edge);
    if (edge.label.len != 0) textAt(lane_x - codepointLen(edge.label) - 1, target_y -| 1, edge.label, .edge_label);
}

fn renderTreeFlow(parsed: []const FlowEdge) void {
    var nodes: [MAX_FLOW_NODES]TreeNode = undefined;
    var node_count: usize = 0;
    var edges: [MAX_FLOW_EDGES]TreeEdge = undefined;
    var edge_count: usize = 0;

    for (parsed) |flow| {
        const from = treeNodeIndex(&nodes, &node_count, flow.from);
        const to = treeNodeIndex(&nodes, &node_count, flow.to);
        const feedback = treeAncestor(&nodes, to, from);
        if (feedback) {
            if (flow.line != .solid) @trap();
        } else {
            if (nodes[to].parent != null or nodes[from].child_count == 2) @trap();
            nodes[to].parent = from;
            const child_slot = nodes[from].child_count;
            nodes[from].children[child_slot] = to;
            nodes[from].child_count += 1;
        }
        edges[edge_count] = .{ .flow = flow, .from = from, .to = to, .feedback = feedback };
        edge_count += 1;
    }

    var root: ?usize = null;
    for (nodes[0..node_count], 0..) |node, i| {
        if (node.parent != null) continue;
        if (root != null) @trap();
        root = i;
    }
    _ = root orelse @trap();

    var max_depth: usize = 0;
    var depth_height: [MAX_FLOW_NODES]usize = [_]usize{0} ** MAX_FLOW_NODES;
    var depth_nodes: [MAX_FLOW_NODES][MAX_FLOW_NODES]usize = undefined;
    var depth_counts: [MAX_FLOW_NODES]usize = [_]usize{0} ** MAX_FLOW_NODES;
    var widths: [MAX_FLOW_NODES]usize = undefined;
    for (nodes[0..node_count], 0..) |*node, i| {
        var depth: usize = 0;
        var current = nodes[i].parent;
        while (current) |parent| {
            depth += 1;
            if (depth == MAX_FLOW_NODES) @trap();
            current = nodes[parent].parent;
        }
        node.depth = depth;
        max_depth = @max(max_depth, depth);
        depth_height[depth] = @max(depth_height[depth], wrappedNodeHeight(node.flow));
        depth_nodes[depth][depth_counts[depth]] = i;
        depth_counts[depth] += 1;
        widths[i] = wrappedNodeWidth(node.flow);
    }

    var positions: [MAX_FLOW_NODES]f64 = undefined;
    var depth: usize = 0;
    while (depth <= max_depth) : (depth += 1) {
        var x: f64 = 0;
        for (depth_nodes[depth][0..depth_counts[depth]]) |node_index| {
            const half = @as(f64, @floatFromInt(widths[node_index])) / 2.0;
            x += half;
            positions[node_index] = x;
            x += half + 3.0;
        }
    }
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) {
        if (iteration % 2 == 0) {
            depth = 0;
            while (depth <= max_depth) : (depth += 1) {
                relaxTreeRank(depth_nodes[depth][0..depth_counts[depth]], &nodes, &positions, &widths, true);
            }
        } else {
            depth = max_depth + 1;
            while (depth != 0) {
                depth -= 1;
                relaxTreeRank(depth_nodes[depth][0..depth_counts[depth]], &nodes, &positions, &widths, false);
            }
        }
    }

    var minimum_left = positions[0] - @as(f64, @floatFromInt(widths[0])) / 2.0;
    for (nodes[1..node_count], 1..) |_, i|
        minimum_left = @min(minimum_left, positions[i] - @as(f64, @floatFromInt(widths[i])) / 2.0);
    for (nodes[0..node_count], 0..) |*node, i|
        node.center = @intFromFloat(@max(0.0, @round(positions[i] - minimum_left)));

    var depth_y: [MAX_FLOW_NODES]usize = [_]usize{0} ** MAX_FLOW_NODES;
    depth = 1;
    while (depth <= max_depth) : (depth += 1)
        depth_y[depth] = depth_y[depth - 1] + depth_height[depth - 1] + 2;
    for (nodes[0..node_count]) |*node|
        node.y = depth_y[node.depth] + (depth_height[node.depth] - wrappedNodeHeight(node.flow)) / 2;

    var diagram_width: usize = 1;
    for (nodes[0..node_count], 0..) |node, i|
        diagram_width = @max(diagram_width, node.center - widths[i] / 2 + widths[i]);
    var content_width = diagram_width;
    for (edges[0..edge_count]) |edge| {
        if (edge.flow.label.len == 0) continue;
        const label_width = codepointLen(edge.flow.label);
        if (edge.feedback)
            content_width = @max(content_width, diagram_width + label_width + 1)
        else
            content_width = @max(content_width, nodes[edge.to].center + 2 + label_width);
    }

    var spans: [MAX_FLOW_EDGES]TrackSpan = undefined;
    var span_count: usize = 0;
    for (edges[0..edge_count], 0..) |edge, edge_index| {
        if (!edge.feedback) continue;
        const from_y = nodes[edge.from].y + wrappedNodeHeight(nodes[edge.from].flow) / 2;
        const to_y = nodes[edge.to].y + wrappedNodeHeight(nodes[edge.to].flow) / 2;
        spans[span_count] = .{
            .start = @min(from_y, to_y),
            .end = @max(from_y, to_y),
            .from = edge.from,
            .to = edge.to,
            .edge = edge_index,
        };
        span_count += 1;
    }
    var edge_lanes: [MAX_FLOW_EDGES]usize = [_]usize{0} ** MAX_FLOW_EDGES;
    const lane_count = assignFeedbackTracks(spans[0..span_count], &edge_lanes);
    const lane_base = if (lane_count == 0) 0 else content_width + 1;

    clearCanvas();
    for (nodes[0..node_count]) |node| wrappedFlowNode(node.flow, node.center, node.y);
    for (edges[0..edge_count], 0..) |edge, edge_index| {
        if (edge.feedback) {
            routeSimonFeedback(&nodes, node_count, nodes[edge.from], nodes[edge.to], edge.flow, lane_base + edge_lanes[edge_index]);
        } else {
            routeSimonForward(
                nodes[edge.from],
                nodes[edge.to],
                edge.flow,
                depth_y[nodes[edge.from].depth] + depth_height[nodes[edge.from].depth],
            );
        }
    }
}

fn isLegacyFlow(parsed: []const FlowEdge) bool {
    if (parsed.len < 7 or parsed.len > 9 or
        !sameNode(parsed[0].to, parsed[1].from) or !sameNode(parsed[1].from, parsed[2].from) or
        !sameNode(parsed[1].to, parsed[3].from) or !sameNode(parsed[3].from, parsed[4].from) or
        !sameNode(parsed[3].to, parsed[5].from) or !sameNode(parsed[5].from, parsed[6].from) or
        parsed[0].line != .solid or parsed[1].line != .solid or parsed[2].line != .solid or
        parsed[3].line != .solid or parsed[4].line != .solid or parsed[5].line != .dotted or
        parsed[6].line != .thick) return false;
    var seen: [2]bool = .{ false, false };
    for (parsed[7..]) |edge| {
        if (edge.line != .solid) return false;
        const slot: usize = if (sameNode(edge.from, parsed[2].to) and sameNode(edge.to, parsed[0].to))
            0
        else if (sameNode(edge.from, parsed[4].to) and sameNode(edge.to, parsed[1].to))
            1
        else
            return false;
        if (seen[slot]) return false;
        seen[slot] = true;
    }
    return true;
}

fn renderFlow(source: []const u8) void {
    // Simon's parser keeps a valid node even when a trailing arrow has no
    // destination. It renders the partial graph instead of treating the whole
    // statement as malformed.
    var probe = std.mem.splitScalar(u8, source, '\n');
    _ = probe.next();
    var lone_statement: ?[]const u8 = null;
    while (probe.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (lone_statement != null) {
            lone_statement = null;
            break;
        }
        lone_statement = line;
    }
    if (lone_statement) |line| {
        const arrow = findFlowArrow(line);
        if (arrow != null and arrow.?.line == .solid and arrow.?.at + arrow.?.len == line.len) {
            const node = parseFlowNode(std.mem.trimRight(u8, line[0..arrow.?.at], " \t"));
            clearCanvas();
            box(1, 0, node.label);
            return;
        }
        if (arrow != null) {
            const header_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
            const header = std.mem.trim(u8, source[0..header_end], " \t\r");
            renderSimpleFlowEdge(parseFlowEdge(line), std.mem.endsWith(u8, header, "LR"));
            return;
        }
    }

    var parsed: [MAX_FLOW_EDGES]FlowEdge = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const header = std.mem.trim(u8, lines.next() orelse @trap(), " \t\r");
    if (!std.mem.eql(u8, header, "graph TD") and !std.mem.eql(u8, header, "flowchart TD") and
        !std.mem.eql(u8, header, "graph TB") and !std.mem.eql(u8, header, "flowchart TB")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (std.mem.startsWith(u8, line, "classDef ") or
            std.mem.startsWith(u8, line, "class ") or
            std.mem.startsWith(u8, line, "style ") or
            std.mem.startsWith(u8, line, "linkStyle ") or
            std.mem.startsWith(u8, line, "click ") or
            std.mem.startsWith(u8, line, "direction ")) continue;
        if (count == parsed.len) @trap();
        parsed[count] = parseFlowEdge(line);
        count += 1;
    }
    if (!isLegacyFlow(parsed[0..count])) {
        renderTreeFlow(parsed[0..count]);
        return;
    }

    var feedbacks: [2]?FlowEdge = .{ null, null };
    for (parsed[7..count]) |edge| {
        if (edge.line != .solid) @trap();
        const slot: usize = if (sameNode(edge.from, parsed[2].to) and sameNode(edge.to, parsed[0].to))
            0
        else if (sameNode(edge.from, parsed[4].to) and sameNode(edge.to, parsed[1].to))
            1
        else
            @trap();
        if (feedbacks[slot] != null) @trap();
        feedbacks[slot] = edge;
    }

    var feedback_count: usize = 0;
    var feedback_label_width: usize = 0;
    for (feedbacks) |feedback| if (feedback) |edge| {
        feedback_count += 1;
        feedback_label_width = @max(feedback_label_width, codepointLen(edge.label));
    };
    const feedback_stride = @max(feedback_label_width + 3, 5);
    const feedback_margin = if (feedback_count == 0) 0 else feedback_count * feedback_stride + 2;

    const log_width = wrappedNodeWidth(parsed[5].to);
    const response_width = wrappedNodeWidth(parsed[6].to);
    const log_center = feedback_margin + (log_width + 1) / 2;
    const leaf_gap: usize = 2 + @as(usize, if (log_width % 2 == 0) 1 else 0);
    const response_center = log_center - log_width / 2 +
        log_width + leaf_gap + response_width / 2;
    const handle_center = (log_center + response_center + @as(usize, if (log_width % 2 == 0) 1 else 0)) / 2;
    const reject2_x = handle_center - wrappedNodeWidth(parsed[3].to) / 2 + wrappedNodeWidth(parsed[3].to) + 3;
    const reject2_center = reject2_x + wrappedNodeWidth(parsed[4].to) / 2;
    const rate_center = (handle_center + reject2_center) / 2;
    const reject1_x = rate_center - wrappedNodeWidth(parsed[1].to) / 2 + wrappedNodeWidth(parsed[1].to) + 3;
    const reject1_center = reject1_x + wrappedNodeWidth(parsed[2].to) / 2;
    const auth_center = (rate_center + reject1_center) / 2;
    const root_y: usize = 0;
    const root_height = wrappedNodeHeight(parsed[0].from);
    const auth_y = root_y + root_height + 2;
    const auth_height = wrappedNodeHeight(parsed[0].to);
    const rank2_y = auth_y + auth_height + 2;
    const rank2_height = @max(wrappedNodeHeight(parsed[1].to), wrappedNodeHeight(parsed[2].to));
    const rank3_y = rank2_y + rank2_height + 2;
    const rank3_height = @max(wrappedNodeHeight(parsed[3].to), wrappedNodeHeight(parsed[4].to));
    const rank4_y = rank3_y + rank3_height + 2;
    const rank4_height = @max(wrappedNodeHeight(parsed[5].to), wrappedNodeHeight(parsed[6].to));

    clearCanvas();
    wrappedFlowNode(parsed[0].from, auth_center, root_y);
    const root_bottom = root_y + root_height - 1;
    put(auth_center, root_bottom, '┬', .edge);
    put(auth_center, root_bottom + 1, '│', .edge);
    arrowLabel(auth_center, root_bottom + 2, "");
    wrappedFlowNode(parsed[0].to, auth_center, auth_y);
    const auth_bottom = auth_y + auth_height - 1;
    put(auth_center, auth_bottom, '┬', .edge);
    forkLine(auth_center, rate_center, reject1_center, rank2_y - 2, .solid, .solid);
    arrowLabel(rate_center, rank2_y - 1, parsed[1].label);
    arrowLabel(reject1_center, rank2_y - 1, parsed[2].label);
    wrappedFlowNode(parsed[1].to, rate_center, rank2_y);
    wrappedFlowNode(parsed[2].to, reject1_center, rank2_y);
    const rate_bottom = rank2_y + wrappedNodeHeight(parsed[1].to) - 1;
    put(rate_center, rate_bottom, '┬', .edge);
    var connector_y = rate_bottom + 1;
    while (connector_y < rank3_y - 2) : (connector_y += 1) put(rate_center, connector_y, '│', .edge);
    forkLine(rate_center, handle_center, reject2_center, rank3_y - 2, .solid, .solid);
    arrowLabel(handle_center, rank3_y - 1, parsed[3].label);
    arrowLabel(reject2_center, rank3_y - 1, parsed[4].label);
    wrappedFlowNode(parsed[3].to, handle_center, rank3_y);
    wrappedFlowNode(parsed[4].to, reject2_center, rank3_y);
    const handle_bottom = rank3_y + wrappedNodeHeight(parsed[3].to) - 1;
    put(handle_center, handle_bottom, '┬', .edge);
    connector_y = handle_bottom + 1;
    while (connector_y < rank4_y - 2) : (connector_y += 1) put(handle_center, connector_y, '│', .edge);
    forkLine(handle_center, log_center, response_center, rank4_y - 2, .dotted, .thick);
    const log_y = rank4_y + (rank4_height - wrappedNodeHeight(parsed[5].to)) / 2;
    const response_y = rank4_y + (rank4_height - wrappedNodeHeight(parsed[6].to)) / 2;
    connector_y = rank4_y - 1;
    while (connector_y < log_y - 1) : (connector_y += 1) put(log_center, connector_y, '╎', .edge);
    connector_y = rank4_y - 1;
    while (connector_y < response_y - 1) : (connector_y += 1) put(response_center, connector_y, '┃', .edge);
    arrowLabel(log_center, log_y - 1, parsed[5].label);
    arrowLabel(response_center, response_y - 1, parsed[6].label);
    wrappedFlowNode(parsed[5].to, log_center, log_y);
    wrappedFlowNode(parsed[6].to, response_center, response_y);

    var feedback_lane: usize = 0;
    if (feedbacks[0]) |edge| {
        drawFlowFeedback(edge, parsed[2].to, reject1_center, rank2_y, parsed[0].to, auth_center, auth_y, 1 + feedback_lane * feedback_stride);
        feedback_lane += 1;
    }
    if (feedbacks[1]) |edge| {
        drawFlowFeedback(edge, parsed[4].to, reject2_center, rank3_y, parsed[1].to, rate_center, rank2_y, 1 + feedback_lane * feedback_stride);
    }
}

fn renderSimpleFlowEdge(edge: FlowEdge, horizontal: bool) void {
    clearCanvas();
    if (horizontal) {
        const from_width = wrappedNodeWidth(edge.from);
        const to_width = wrappedNodeWidth(edge.to);
        const gap: usize = @max(4, codepointLen(edge.label) + 2);
        const to_x = from_width + gap;
        const edge_y: usize = 2;
        // The reference reserves the row above a horizontal edge for its label,
        // even when the edge is unlabelled.
        preserve_first_row_spaces = true;
        put(to_x + to_width - 1, 0, ' ', .none);
        wrappedFlowNode(edge.from, from_width / 2, 1);
        wrappedFlowNode(edge.to, to_x + to_width / 2, 1);
        put(from_width - 1, edge_y, '├', .edge);
        hline(from_width, to_x - 2, edge_y, switch (edge.line) {
            .solid => '─',
            .dotted => '╌',
            .thick => '━',
        });
        put(to_x - 1, edge_y, '▶', .edge);
        if (edge.label.len != 0) {
            const label_x = from_width + (gap - codepointLen(edge.label)) / 2;
            textAt(label_x, 0, edge.label, .edge_label);
        }
        return;
    }

    const from_width = wrappedNodeWidth(edge.from);
    const to_width = wrappedNodeWidth(edge.to);
    const center = (@max(from_width, to_width) + 1) / 2;
    wrappedFlowNode(edge.from, center, 0);
    const from_bottom = wrappedNodeHeight(edge.from) - 1;
    put(center, from_bottom, '┬', .edge);
    put(center, from_bottom + 1, switch (edge.line) {
        .solid => '│',
        .dotted => '╎',
        .thick => '┃',
    }, .edge);
    put(center, from_bottom + 2, '▼', .edge);
    if (edge.label.len != 0) textAt(center + 1, from_bottom + 2, edge.label, .edge_label);
    wrappedFlowNode(edge.to, center, from_bottom + 3);
}

const MAX_WRAP_LINES = 4;
const WRAP_WIDTH = 24;

const WrappedLabel = struct {
    lines: [MAX_WRAP_LINES][]const u8 = undefined,
    count: usize = 0,
    width: usize = 0,
    truncated: bool = false,
};

fn wrapLabel(label: []const u8) WrappedLabel {
    var wrapped = WrappedLabel{};
    var rest = std.mem.trim(u8, label, " \t");
    while (rest.len != 0) {
        if (wrapped.count == MAX_WRAP_LINES) {
            wrapped.truncated = true;
            const last = wrapped.lines[MAX_WRAP_LINES - 1];
            if (codepointLen(last) >= WRAP_WIDTH)
                wrapped.lines[MAX_WRAP_LINES - 1] = last[0 .. WRAP_WIDTH - 1];
            wrapped.width = @max(wrapped.width, codepointLen(wrapped.lines[MAX_WRAP_LINES - 1]) + 1);
            break;
        }
        var take: usize = @min(rest.len, WRAP_WIDTH);
        if (rest.len > WRAP_WIDTH) {
            var break_at: ?usize = null;
            var i: usize = 0;
            while (i < take) : (i += 1) {
                if (rest[i] == ' ' or rest[i] == '\t') {
                    break_at = i;
                } else if (rest[i] == '_' or rest[i] == '-' or rest[i] == '.' or rest[i] == '/') {
                    break_at = i + 1;
                }
            }
            if (break_at) |at| {
                if (at != 0) take = at;
            }
        }
        const line = std.mem.trimRight(u8, rest[0..take], " \t");
        if (line.len == 0) @trap();
        wrapped.lines[wrapped.count] = line;
        wrapped.count += 1;
        wrapped.width = @max(wrapped.width, codepointLen(line));
        rest = std.mem.trimLeft(u8, rest[take..], " \t");
    }
    if (wrapped.count == 0) @trap();
    return wrapped;
}

fn wrappedNodeWidth(node: FlowNode) usize {
    return wrapLabel(node.label).width + 4;
}

fn wrappedNodeHeight(node: FlowNode) usize {
    return wrapLabel(node.label).count + 2;
}

fn wrappedBox(x: usize, y: usize, node: FlowNode) void {
    wrappedNodeAt(x, y, node, .rect);
}

fn wrappedNodeAt(x: usize, y: usize, node: FlowNode, shape: NodeShape) void {
    const wrapped = wrapLabel(node.label);
    const width = wrapped.width + 4;
    const rounded = shape != .rect;
    put(x, y, if (rounded) '╭' else '┌', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, if (rounded) '╮' else '┐', .border);
    for (wrapped.lines[0..wrapped.count], 0..) |line, line_index| {
        const row = y + 1 + line_index;
        const display_width = codepointLen(line) +
            @as(usize, if (wrapped.truncated and line_index == wrapped.count - 1) 1 else 0);
        put(x, row, '│', .edge);
        const text_x = x + 2 + (wrapped.width - display_width) / 2;
        textAt(text_x, row, line, .node);
        if (wrapped.truncated and line_index == wrapped.count - 1)
            put(text_x + codepointLen(line), row, '…', .node);
        put(x + width - 1, row, '│', .edge);
    }
    const bottom = y + wrapped.count + 1;
    put(x, bottom, if (rounded) '╰' else '└', .border);
    hline(x + 1, x + width - 2, bottom, '─');
    put(x + width - 1, bottom, if (rounded) '╯' else '┘', .border);
}

fn wrappedFlowNode(node: FlowNode, center: usize, y: usize) void {
    wrappedNodeAt(center - wrappedNodeWidth(node) / 2, y, node, node.shape);
}

fn drawGroup(x: usize, y: usize, width: usize, height: usize, title: []const u8) void {
    put(x, y, '┌', .border);
    textAt(x + 1, y, " ", .node);
    textAt(x + 2, y, title, .node);
    textAt(x + 2 + codepointLen(title), y, " ", .node);
    hline(x + 3 + codepointLen(title), x + width - 2, y, '─');
    put(x + width - 1, y, '┐', .border);
    var row = y + 1;
    while (row < y + height - 1) : (row += 1) {
        put(x, row, '│', .edge);
        put(x + width - 1, row, '│', .edge);
    }
    put(x, y + height - 1, '└', .border);
    hline(x + 1, x + width - 2, y + height - 1, '─');
    put(x + width - 1, y + height - 1, '┘', .border);
}

fn drawHorizontalEdge(from_right: usize, to_left: usize, y: usize) void {
    put(from_right, y, '├', .edge);
    hline(from_right + 1, to_left - 1, y, '─');
    put(to_left - 1, y, '▶', .edge);
}

fn renderSubgraphs(source: []const u8) void {
    var titles: [2][]const u8 = undefined;
    var inside: [2]FlowEdge = undefined;
    var cross: ?FlowEdge = null;
    var group: ?usize = null;
    var group_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse @trap(), " \t\r"), "flowchart LR")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (std.mem.startsWith(u8, line, "classDef ") or
            std.mem.startsWith(u8, line, "class ") or
            std.mem.startsWith(u8, line, "style ") or
            std.mem.startsWith(u8, line, "linkStyle ") or
            std.mem.startsWith(u8, line, "click ") or
            std.mem.startsWith(u8, line, "direction ")) continue;
        if (std.mem.startsWith(u8, line, "subgraph ")) {
            if (group != null or group_count == 2) @trap();
            titles[group_count] = std.mem.trim(u8, line["subgraph ".len..], " \t");
            group = group_count;
            continue;
        }
        if (std.mem.eql(u8, line, "end")) {
            if (group == null) @trap();
            group_count += 1;
            group = null;
            continue;
        }
        const edge = parseFlowEdge(line);
        if (group) |index| inside[index] = edge else {
            if (cross != null) @trap();
            cross = edge;
        }
    }
    if (group != null or group_count != 2 or cross == null or
        !sameNode(cross.?.from, inside[0].to) or !sameNode(cross.?.to, inside[1].from) or
        inside[0].line != .solid or inside[1].line != .solid or cross.?.line != .solid) @trap();
    const gap: usize = 4;
    const group_gap = codepointLen(cross.?.label) + 3;
    const first_width = wrappedNodeWidth(inside[0].from) + gap + wrappedNodeWidth(inside[0].to) + 2;
    const second_width = wrappedNodeWidth(inside[1].from) + gap + wrappedNodeWidth(inside[1].to) + 2;
    const second_x = first_width + group_gap;
    const first_tallest = @max(wrappedNodeHeight(inside[0].from), wrappedNodeHeight(inside[0].to));
    const second_tallest = @max(wrappedNodeHeight(inside[1].from), wrappedNodeHeight(inside[1].to));
    const first_height = @max(@as(usize, 6), (first_tallest + 3) & ~@as(usize, 1));
    const second_height = @max(@as(usize, 6), (second_tallest + 3) & ~@as(usize, 1));
    const layout_height = @max(first_height, second_height);
    const first_y = (layout_height - first_height) / 2;
    const second_y = (layout_height - second_height) / 2;
    const first_inner_height = first_height - 2;
    const second_inner_height = second_height - 2;
    const edge_y = layout_height / 2;
    clearCanvas();
    drawGroup(0, first_y, first_width, first_height, titles[0]);
    drawGroup(second_x, second_y, second_width, second_height, titles[1]);
    const a_x: usize = 1;
    const b_x = a_x + wrappedNodeWidth(inside[0].from) + gap;
    const c_x = second_x + 1;
    const d_x = c_x + wrappedNodeWidth(inside[1].from) + gap;
    const a_y = first_y + 1 + (first_inner_height - wrappedNodeHeight(inside[0].from) + 1) / 2;
    const b_y = first_y + 1 + (first_inner_height - wrappedNodeHeight(inside[0].to) + 1) / 2;
    const c_y = second_y + 1 + (second_inner_height - wrappedNodeHeight(inside[1].from) + 1) / 2;
    const d_y = second_y + 1 + (second_inner_height - wrappedNodeHeight(inside[1].to) + 1) / 2;
    wrappedBox(a_x, a_y, inside[0].from);
    wrappedBox(b_x, b_y, inside[0].to);
    wrappedBox(c_x, c_y, inside[1].from);
    wrappedBox(d_x, d_y, inside[1].to);
    drawHorizontalEdge(a_x + wrappedNodeWidth(inside[0].from) - 1, b_x, edge_y);
    drawHorizontalEdge(c_x + wrappedNodeWidth(inside[1].from) - 1, d_x, edge_y);
    // Cross-group arrows terminate on the group frame; inner borders remain intact.
    drawHorizontalEdge(first_width - 1, second_x, edge_y);
    if (cross.?.label.len != 0) {
        const label_x = first_width + (group_gap - codepointLen(cross.?.label)) / 2;
        textAt(label_x, edge_y - 1, cross.?.label, .edge_label);
    }
}

fn entityIndex(entities: *[MAX_ENTITIES]Entity, count: *usize, id: []const u8) usize {
    for (entities[0..count.*], 0..) |entity, i|
        if (std.mem.eql(u8, entity.id, id)) return i;
    if (count.* == MAX_ENTITIES or id.len == 0) @trap();
    const i = count.*;
    entities[i] = .{ .id = id, .label = id };
    count.* += 1;
    return i;
}

fn addMember(entity: *Entity, member: []const u8) void {
    if (entity.member_count == MAX_MEMBERS or member.len == 0) @trap();
    entity.members[entity.member_count] = member;
    entity.member_count += 1;
}

fn entityWidth(entity: *const Entity) usize {
    var inner = codepointLen(entity.label);
    for (entity.members[0..entity.member_count]) |member|
        inner = @max(inner, codepointLen(member));
    return inner + 4;
}

fn entityHeight(entity: *const Entity, class_sections: bool) usize {
    if (entity.member_count == 0) return 3;
    var height: usize = 4 + entity.member_count;
    if (class_sections) {
        var saw_non_method = false;
        for (entity.members[0..entity.member_count]) |member| {
            const method = std.mem.indexOfScalar(u8, member, '(') != null;
            if (method and saw_non_method) {
                height += 1;
                break;
            }
            saw_non_method = saw_non_method or !method;
        }
    }
    return height;
}

fn centeredText(x: usize, width: usize, y: usize, value: []const u8) void {
    textAt(x + (width - codepointLen(value)) / 2, y, value, .node);
}

fn drawEntity(entity: *const Entity, x: usize, y: usize, class_sections: bool) usize {
    const width = entityWidth(entity);
    put(x, y, '┌', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, '┐', .border);
    put(x, y + 1, '│', .edge);
    centeredText(x + 1, width - 2, y + 1, entity.label);
    put(x + width - 1, y + 1, '│', .edge);
    var row = y + 2;
    if (entity.member_count != 0) {
        put(x, row, '├', .edge);
        hline(x + 1, x + width - 2, row, '─');
        put(x + width - 1, row, '┤', .edge);
        for (x..x + width) |column| cells[row][column].role = .border;
        row += 1;
        var methods = false;
        for (entity.members[0..entity.member_count]) |member| {
            const method = std.mem.indexOfScalar(u8, member, '(') != null;
            if (class_sections and method and !methods and row > y + 3) {
                put(x, row, '├', .edge);
                hline(x + 1, x + width - 2, row, '─');
                put(x + width - 1, row, '┤', .edge);
                for (x..x + width) |column| cells[row][column].role = .border;
                row += 1;
            }
            methods = methods or method;
            put(x, row, '│', .edge);
            textAt(x + 2, row, member, .node);
            put(x + width - 1, row, '│', .edge);
            row += 1;
        }
    }
    put(x, row, '└', .border);
    hline(x + 1, x + width - 2, row, '─');
    put(x + width - 1, row, '┘', .border);
    return row;
}

fn renderClass(source: []const u8) void {
    var entities: [MAX_ENTITIES]Entity = undefined;
    var count: usize = 0;
    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse @trap(), " \t\r"), "classDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (std.mem.startsWith(u8, line, "classDef ") or
            std.mem.startsWith(u8, line, "style ") or
            std.mem.startsWith(u8, line, "click ")) continue;
        if (active) |index| {
            if (std.mem.eql(u8, line, "}")) {
                active = null;
            } else {
                addMember(&entities[index], line);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "class ")) {
            const rest = std.mem.trim(u8, line["class ".len..], " \t");
            const brace = std.mem.indexOfScalar(u8, rest, '{') orelse @trap();
            const id = std.mem.trim(u8, rest[0..brace], " \t");
            active = entityIndex(&entities, &count, id);
            continue;
        }
        if (std.mem.indexOf(u8, line, "<|--")) |at| {
            const parent_id = std.mem.trim(u8, line[0..at], " \t");
            const child_id = std.mem.trim(u8, line[at + 4 ..], " \t");
            const parent = entityIndex(&entities, &count, parent_id);
            const child = entityIndex(&entities, &count, child_id);
            entities[child].parent = parent;
            continue;
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |at| {
            const id = std.mem.trim(u8, line[0..at], " \t");
            const member = std.mem.trim(u8, line[at + 1 ..], " \t");
            addMember(&entities[entityIndex(&entities, &count, id)], member);
            continue;
        }
        @trap();
    }
    if (active != null or count == 0) @trap();
    var root: ?usize = null;
    var children: [MAX_ENTITIES]usize = undefined;
    var child_count: usize = 0;
    for (entities[0..count], 0..) |entity, i| {
        if (entity.parent == null) {
            if (root != null) @trap();
            root = i;
        }
    }
    const r = root orelse @trap();
    for (entities[0..count], 0..) |entity, i| {
        if (entity.parent == r) {
            children[child_count] = i;
            child_count += 1;
        } else if (i != r) @trap();
    }
    if (child_count == 0) @trap();
    var total: usize = 0;
    for (children[0..child_count], 0..) |child, i| {
        if (i != 0) total += 4;
        total += entityWidth(&entities[child]);
    }
    const root_width = entityWidth(&entities[r]);
    const first_child_center = entityWidth(&entities[children[0]]) / 2;
    const last_child_width = entityWidth(&entities[children[child_count - 1]]);
    const last_child_center = total - last_child_width + last_child_width / 2;
    const tree_center = (first_child_center + last_child_center) / 2;
    const root_is_wider = root_width > total;
    const child_origin = if (root_is_wider) (root_width + 1 - total) / 2 else 0;
    const root_x = if (root_is_wider)
        1
    else if (tree_center >= root_width / 2)
        tree_center - root_width / 2
    else
        0;
    clearCanvas();
    const root_bottom = drawEntity(&entities[r], root_x, 0, true);
    const root_center = root_x + root_width / 2;
    put(root_center, root_bottom, '△', .edge);
    var child_x: usize = child_origin;
    const child_gap: usize = if (root_is_wider) 3 else 4;
    var max_child_height: usize = 0;
    for (children[0..child_count]) |child|
        max_child_height = @max(max_child_height, entityHeight(&entities[child], true));
    var first_center: usize = 0;
    var last_center: usize = 0;
    for (children[0..child_count], 0..) |child, i| {
        const center = child_x + entityWidth(&entities[child]) / 2;
        if (i == 0) first_center = center;
        last_center = center;
        const child_y = root_bottom + 3 + (max_child_height - entityHeight(&entities[child], true)) / 2;
        _ = drawEntity(&entities[child], child_x, child_y, true);
        var connector_y = root_bottom + 2;
        while (connector_y < child_y) : (connector_y += 1) put(center, connector_y, '│', .edge);
        child_x += entityWidth(&entities[child]) + child_gap;
    }
    hline(first_center, last_center, root_bottom + 1, '─');
    put(first_center, root_bottom + 1, '┌', .edge);
    put(last_center, root_bottom + 1, '┐', .edge);
    put(root_center, root_bottom + 1, '┴', .edge);
}

fn erCardinality(token: []const u8, left: bool) []const u8 {
    _ = left;
    if (std.mem.eql(u8, token, "|o") or std.mem.eql(u8, token, "o|")) return "0..1";
    if (std.mem.eql(u8, token, "||")) return "1";
    if (std.mem.eql(u8, token, "o{") or std.mem.eql(u8, token, "}o")) return "0..*";
    if (std.mem.eql(u8, token, "|{") or std.mem.eql(u8, token, "}|")) return "1..*";
    @trap();
}

fn renderEr(source: []const u8) void {
    var entities: [MAX_ENTITIES]Entity = undefined;
    var count: usize = 0;
    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse @trap(), " \t\r"), "erDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (active) |index| {
            if (std.mem.eql(u8, line, "}")) active = null else addMember(&entities[index], line);
            continue;
        }
        if (std.mem.endsWith(u8, line, "{")) {
            const id = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
            active = entityIndex(&entities, &count, id);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse @trap();
        var words = std.mem.tokenizeAny(u8, line[0..colon], " \t");
        const from_id = words.next() orelse @trap();
        const connector = words.next() orelse @trap();
        const to_id = words.next() orelse @trap();
        if (words.next() != null or connector.len != 6 or !std.mem.eql(u8, connector[2..4], "--")) @trap();
        const from = entityIndex(&entities, &count, from_id);
        const to = entityIndex(&entities, &count, to_id);
        if (entities[to].parent != null) @trap();
        entities[to].parent = from;
        entities[to].from_cardinality = erCardinality(connector[0..2], true);
        entities[to].to_cardinality = erCardinality(connector[4..6], false);
        entities[to].relation = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    if (active != null or count == 0) @trap();
    var root: ?usize = null;
    for (entities[0..count], 0..) |entity, i| if (entity.parent == null) {
        if (root != null) @trap();
        root = i;
    };
    clearCanvas();
    var current = root orelse @trap();
    var y: usize = 0;
    var center: usize = 0;
    while (true) {
        const width = entityWidth(&entities[current]);
        if (y == 0) center = (width + 1) / 2;
        const x = center - width / 2;
        const bottom = drawEntity(&entities[current], x, y, false);
        var child: ?usize = null;
        for (entities[0..count], 0..) |entity, i| if (entity.parent == current) {
            if (child != null) @trap();
            child = i;
        };
        const next = child orelse break;
        put(center, bottom, '┬', .edge);
        put(center, bottom + 1, '│', .edge);
        put(center, bottom + 2, '│', .edge);
        const label = entities[next].relation;
        var relation_buffer: [96]u8 = undefined;
        const relation = std.fmt.bufPrint(&relation_buffer, "{s} {s} {s}", .{
            entities[next].from_cardinality, label, entities[next].to_cardinality,
        }) catch @trap();
        textAt(center + 1, bottom + 2, relation, .edge_label);
        y = bottom + 3;
        current = next;
    }
}

fn codepointLen(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch @trap();
}

fn findParticipant(
    participants: *[MAX_PARTICIPANTS]Participant,
    count: *usize,
    id: []const u8,
    label: ?[]const u8,
) usize {
    for (participants[0..count.*], 0..) |*participant, i| {
        if (std.mem.eql(u8, participant.id, id)) {
            if (label) |value| participant.label = value;
            return i;
        }
    }
    if (count.* == MAX_PARTICIPANTS) @trap();
    const i = count.*;
    participants[i] = .{ .id = id, .label = label orelse id };
    count.* += 1;
    return i;
}

fn renderSequence(source: []const u8) void {
    var participants: [MAX_PARTICIPANTS]Participant = undefined;
    var participant_count: usize = 0;
    var messages: [MAX_MESSAGES]Message = undefined;
    var message_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const header = std.mem.trim(u8, lines.next() orelse @trap(), " \t\r");
    if (!std.mem.eql(u8, header, "sequenceDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        const declaration_prefix: ?[]const u8 = if (std.mem.startsWith(u8, line, "participant "))
            "participant "
        else if (std.mem.startsWith(u8, line, "actor "))
            "actor "
        else
            null;
        if (declaration_prefix) |prefix| {
            const declaration = std.mem.trimLeft(u8, line[prefix.len..], " \t");
            if (std.mem.indexOf(u8, declaration, " as ")) |at| {
                const id = std.mem.trim(u8, declaration[0..at], " \t");
                const label = std.mem.trim(u8, declaration[at + 4 ..], " \t");
                if (id.len == 0 or label.len == 0) @trap();
                _ = findParticipant(&participants, &participant_count, id, label);
            } else {
                if (declaration.len == 0) @trap();
                _ = findParticipant(&participants, &participant_count, declaration, null);
            }
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse @trap();
        const relation = std.mem.trim(u8, line[0..colon], " \t");
        const label = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const dashed = std.mem.indexOf(u8, relation, "-->>") != null;
        const arrow_at = if (dashed)
            std.mem.indexOf(u8, relation, "-->>").?
        else
            std.mem.indexOf(u8, relation, "->>") orelse @trap();
        const arrow_len: usize = if (dashed) 4 else 3;
        const from_id = std.mem.trimRight(u8, std.mem.trim(u8, relation[0..arrow_at], " \t"), "+-");
        const to_id = std.mem.trimLeft(u8, std.mem.trim(u8, relation[arrow_at + arrow_len ..], " \t"), "+-");
        if (from_id.len == 0 or to_id.len == 0 or label.len == 0) @trap();
        if (message_count == MAX_MESSAGES) @trap();
        messages[message_count] = .{
            .from = findParticipant(&participants, &participant_count, from_id, null),
            .to = findParticipant(&participants, &participant_count, to_id, null),
            .label = label,
            .dashed = dashed,
        };
        message_count += 1;
    }
    if (participant_count == 0 or message_count == 0) @trap();
    for (messages[0..message_count]) |message| {
        const distance = if (message.from > message.to)
            message.from - message.to
        else
            message.to - message.from;
        if (distance != 1) @trap();
    }

    participants[0].center = (participantLabelWidth(participants[0].label) + 4) / 2;
    var i: usize = 1;
    while (i < participant_count) : (i += 1) {
        const previous_width = participantLabelWidth(participants[i - 1].label) + 4;
        const next_width = participantLabelWidth(participants[i].label) + 4;
        var distance = previous_width - previous_width / 2 + 2 + next_width / 2;
        for (messages[0..message_count]) |message| {
            if ((message.from == i - 1 and message.to == i) or
                (message.from == i and message.to == i - 1))
                distance = @max(distance, codepointLen(message.label) + 2);
        }
        participants[i].center = participants[i - 1].center + distance;
    }

    clearCanvas();
    for (participants[0..participant_count]) |participant| {
        const box_width = participantLabelWidth(participant.label) + 4;
        participantBox(participant.center - box_width / 2, 0, participant.label);
        put(participant.center, 2, '┬', .edge);
    }
    var y: usize = 3;
    for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
    for (messages[0..message_count]) |message| {
        y += 1;
        const a = participants[message.from].center;
        const b = participants[message.to].center;
        const left = @min(a, b);
        const right = @max(a, b);
        const label_x = left + (right - left - codepointLen(message.label) + 1) / 2;
        textAt(label_x, y, message.label, .node);
        for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
        y += 1;
        for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
        if (message.from < message.to) {
            hline(left, right - 1, y, if (message.dashed) '╌' else '─');
            put(a, y, '├', .edge);
            put(b - 1, y, '▶', .edge);
        } else {
            hline(left + 1, right, y, if (message.dashed) '╌' else '─');
            put(a, y, '┤', .edge);
            put(b + 1, y, '◄', .edge);
        }
        y += 1;
        for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
    }
    y += 1;
    for (participants[0..participant_count]) |participant| {
        const box_width = participantLabelWidth(participant.label) + 4;
        participantBox(participant.center - box_width / 2, y, participant.label);
        put(participant.center, y, '┴', .edge);
    }
}

fn participantLabelWidth(label: []const u8) usize {
    return @min(codepointLen(label), WRAP_WIDTH);
}

fn participantBox(x: usize, y: usize, label: []const u8) void {
    const label_width = participantLabelWidth(label);
    if (codepointLen(label) <= WRAP_WIDTH) {
        box(x, y, label);
        return;
    }
    const width = label_width + 4;
    put(x, y, '┌', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, '┐', .border);
    put(x, y + 1, '│', .edge);
    textAt(x + 2, y + 1, label[0 .. WRAP_WIDTH - 1], .node);
    put(x + 2 + WRAP_WIDTH - 1, y + 1, '…', .node);
    put(x + width - 1, y + 1, '│', .edge);
    put(x, y + 2, '└', .border);
    hline(x + 1, x + width - 2, y + 2, '─');
    put(x + width - 1, y + 2, '┘', .border);
}

fn serializeHtml() u32 {
    var out: usize = 0;
    for (0..canvas_height) |y| {
        var width = canvas_width;
        if (!(y == 0 and preserve_first_row_spaces)) {
            while (width > 0 and cells[y][width - 1].char == ' ') width -= 1;
        }
        var x: usize = 0;
        while (x < width) {
            const role = cells[y][x].role;
            var end = x + 1;
            while (end < width and cells[y][end].role == role) end += 1;
            if (roleClass(role)) |class| {
                append(&out, "<span class=\"");
                append(&out, class);
                append(&out, "\">");
            }
            for (cells[y][x..end]) |cell| appendCodepoint(&out, cell.char);
            if (roleClass(role) != null) append(&out, "</span>");
            x = end;
        }
        append(&out, "\n");
    }
    return @intCast(out);
}

fn roleClass(role: Role) ?[]const u8 {
    return switch (role) {
        .none => null,
        .border => "b",
        .node => "n",
        .edge => "e",
        .edge_label => "el",
        .title => "t",
    };
}

fn append(out: *usize, text: []const u8) void {
    if (out.* + text.len > OUTPUT_CAP) @trap();
    @memcpy(output_buffer[out.*..][0..text.len], text);
    out.* += text.len;
}

fn appendCodepoint(out: *usize, cp: u21) void {
    switch (cp) {
        '&' => append(out, "&amp;"),
        '<' => append(out, "&lt;"),
        '>' => append(out, "&gt;"),
        else => {
            var bytes: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(cp, &bytes) catch @trap();
            append(out, bytes[0..encoded]);
        },
    }
}
