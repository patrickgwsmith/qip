const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 600;
const RENDER_H: usize = 450;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

const Color = [4]u8;

const PALETTE = [_]Color{
    .{ 0x8B, 0x5C, 0xFD, 0xFF }, // Purple / CEO / Root Accent (Electric violet)
    .{ 0x3B, 0x82, 0xF6, 0xFF }, // Blue / VP Accent (Vibrant blue)
    .{ 0x10, 0xB9, 0x81, 0xFF }, // Emerald / Lead Accent (Mint emerald)
    .{ 0xF5, 0x9E, 0x0B, 0xFF }, // Amber / Senior Accent (Glow orange)
    .{ 0xEC, 0x48, 0x99, 0xFF }, // Pink / Designer Accent (Neon pink)
};

const MAX_EMPLOYEES = 12;
const MAX_SCENARIOS = 4;

const Employee = struct {
    id: u8,
    name: [16]u8,
    name_len: u8,
    title: [16]u8,
    title_len: u8,
    reports_to: u8, // Employee ID of manager, 0 if reports to no one
    active: bool, // Fired employees are false
    color: Color, // Employee custom outline color
};

const Scenario = struct {
    active: bool,
    name: []const u8,
    employees: [MAX_EMPLOYEES]Employee,
    employee_count: usize,
};

const FocusField = enum {
    none,
    name,
    title,
};

// Global State
var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;
var scenarios: [MAX_SCENARIOS]Scenario = undefined;
var active_scenario_idx: usize = 0;

var selected_emp_id: u8 = 0;
var hovered_emp_id: u8 = 0;
var hovered_tab_idx: i32 = -1;

var reassign_mode: bool = false;
var focused_field: FocusField = .none;
var edit_buffer: [16]u8 = undefined;
var edit_len: usize = 0;

var cursor_blink: bool = true;
var last_blink_ms: i64 = 0;

// Coordinates from last layout calculation
var node_coords: [MAX_EMPLOYEES]struct { x: i32, y: i32 } = undefined;
var children_count: [MAX_EMPLOYEES]u8 = undefined;
var children: [MAX_EMPLOYEES][MAX_EMPLOYEES]u8 = undefined;
var subtree_width: [MAX_EMPLOYEES]i32 = undefined;

var initialized = false;
var needs_redraw = true;

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const LifecycleState = enum { initializing, ready, updating };
var lifecycle_state: LifecycleState = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced = false;

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle_state != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    lifecycle_state = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    // ESC key cancels text edits or reassignments
    if (x11_key == 0xFF1B) { // Escape
        if (reassign_mode) {
            reassign_mode = false;
            needs_redraw = true;
            return 1;
        }
        if (focused_field != .none) {
            focused_field = .none;
            needs_redraw = true;
            return 1;
        }
        return 0;
    }

    if (focused_field != .none) {
        if (x11_key == 0xFF08) { // Backspace
            if (edit_len > 0) {
                edit_len -= 1;
                needs_redraw = true;
            }
            return 1;
        } else if (x11_key == 0xFF0D) { // Return/Enter
            commitEdit();
            needs_redraw = true;
            return 1;
        } else if (isPrintable(x11_key)) {
            if (edit_len < 15) {
                edit_buffer[edit_len] = @as(u8, @intCast(x11_key));
                edit_len += 1;
                needs_redraw = true;
            }
            return 1;
        }
    }

    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    const primary = (button_mask & BTN_PRIMARY) != 0;

    // Track hovered elements
    hovered_emp_id = 0;
    hovered_tab_idx = -1;

    // Check tab hover
    var t: i32 = 0;
    while (t < MAX_SCENARIOS) : (t += 1) {
        const tx = 10 + t * 105;
        if (x_px >= tx and x_px <= tx + 95 and y_px >= 8 and y_px <= 30) {
            hovered_tab_idx = t;
            break;
        }
    }

    // Check employee hover
    const sc = &scenarios[active_scenario_idx];
    var i: usize = 0;
    while (i < sc.employee_count) : (i += 1) {
        const coord = node_coords[i];
        if (x_px >= coord.x - 30 and x_px <= coord.x + 30 and y_px >= coord.y - 18 and y_px <= coord.y + 18) {
            hovered_emp_id = sc.employees[i].id;
            break;
        }
    }

    if (primary) {
        // --- CLICK ON TAB BAR ---
        if (hovered_tab_idx != -1) {
            const idx = @as(usize, @intCast(hovered_tab_idx));
            if (scenarios[idx].active) {
                active_scenario_idx = idx;
                // Try to keep selection if the same ID exists in new scenario
                if (selected_emp_id != 0) {
                    if (findEmployeeIndexById(selected_emp_id) == null) {
                        selected_emp_id = 0;
                        focused_field = .none;
                    }
                }
            } else {
                // Fork current scenario into this tab!
                forkScenario(idx);
            }
            reassign_mode = false;
            focused_field = .none;
            needs_redraw = true;
            return 1;
        }

        // --- CLICK ON TREE AREA ---
        if (x_px >= 10 and x_px < 410 and y_px >= 35 and y_px < 440) {
            if (hovered_emp_id != 0) {
                if (reassign_mode) {
                    // Do not allow cyclic assignments
                    if (hovered_emp_id != selected_emp_id and !isDescendant(selected_emp_id, hovered_emp_id)) {
                        const sel_idx = findEmployeeIndexById(selected_emp_id).?;
                        sc.employees[sel_idx].reports_to = hovered_emp_id;
                    }
                    reassign_mode = false;
                } else {
                    if (focused_field != .none) {
                        commitEdit();
                    }
                    selected_emp_id = hovered_emp_id;
                }
                needs_redraw = true;
                return 1;
            } else {
                // Clicked on blank space in tree area
                if (reassign_mode) {
                    reassign_mode = false;
                    needs_redraw = true;
                    return 1;
                }
                if (focused_field != .none) {
                    commitEdit();
                }
                selected_emp_id = 0;
                needs_redraw = true;
                return 1;
            }
        }

        // --- CLICK ON SIDEBAR ---
        if (x_px >= 420 and x_px < 590 and y_px >= 40 and y_px < 440) {
            if (selected_emp_id != 0) {
                const idx = findEmployeeIndexById(selected_emp_id).?;
                const emp = &sc.employees[idx];

                // Name Box: x = 430, y = 80, w = 150, h = 24
                if (x_px >= 430 and x_px <= 580 and y_px >= 80 and y_px <= 104) {
                    if (focused_field != .name) {
                        commitEdit();
                        focused_field = .name;
                        @memcpy(edit_buffer[0..emp.name_len], emp.name[0..emp.name_len]);
                        edit_len = emp.name_len;
                        needs_redraw = true;
                    }
                    return 1;
                }

                // Title Box: x = 430, y = 130, w = 150, h = 24
                if (x_px >= 430 and x_px <= 580 and y_px >= 130 and y_px <= 154) {
                    if (focused_field != .title) {
                        commitEdit();
                        focused_field = .title;
                        @memcpy(edit_buffer[0..emp.title_len], emp.title[0..emp.title_len]);
                        edit_len = emp.title_len;
                        needs_redraw = true;
                    }
                    return 1;
                }

                // Reassign button: x = 430, y = 185, w = 150, h = 22
                if (x_px >= 430 and x_px <= 580 and y_px >= 185 and y_px <= 207) {
                    commitEdit();
                    reassign_mode = !reassign_mode;
                    needs_redraw = true;
                    return 1;
                }

                // Color Selection Circles: y = 232, 5 circles x = 440 + c * 25, radius 8
                var c: usize = 0;
                while (c < 5) : (c += 1) {
                    const cx = 440 + @as(i32, @intCast(c * 25));
                    const cy = 232;
                    const dx = x_px - cx;
                    const dy = y_px - cy;
                    if (dx * dx + dy * dy <= 64) {
                        commitEdit();
                        emp.color = PALETTE[c];
                        needs_redraw = true;
                        return 1;
                    }
                }

                // Fire/Rehire button: x = 430, y = 265, w = 150, h = 24
                if (x_px >= 430 and x_px <= 580 and y_px >= 265 and y_px <= 289) {
                    commitEdit();
                    emp.active = !emp.active;
                    needs_redraw = true;
                    return 1;
                }

                // Hire report button: x = 430, y = 315, w = 150, h = 24
                if (x_px >= 430 and x_px <= 580 and y_px >= 315 and y_px <= 339) {
                    commitEdit();
                    hireWorker(emp.id);
                    needs_redraw = true;
                    return 1;
                }

                // Delete button: x = 430, y = 355, w = 150, h = 24
                if (x_px >= 430 and x_px <= 580 and y_px >= 355 and y_px <= 379) {
                    commitEdit();
                    deleteWorker(emp.id);
                    needs_redraw = true;
                    return 1;
                }
            } else {
                // No worker selected. Glass inspect hire worker button: x = 430, y = 315, w = 150, h = 24
                if (x_px >= 430 and x_px <= 580 and y_px >= 315 and y_px <= 339) {
                    commitEdit();
                    hireWorker(0); // Add a root worker
                    needs_redraw = true;
                    return 1;
                }
            }
        }
    }

    return 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    // Blink cursor every 400ms when focused
    if (focused_field != .none) {
        if (begun_at_ms - last_blink_ms >= 400) {
            cursor_blink = !cursor_blink;
            last_blink_ms = begun_at_ms;
            needs_redraw = true;
        }
    }
}

export fn finish_update() i64 {
    requireUpdate();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    return if (begun_at_ms <= std.math.maxInt(i64) - 100) begun_at_ms + 100 else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or (lifecycle_state != .initializing and lifecycle_state != .ready)) @trap();
    ensureInit();
    calculateLayout();
    drawFrame();
    needs_redraw = false;
    _ = ktx.writeHeader(&ktx_buf, RENDER_W, RENDER_H) orelse @trap();
    @memcpy(ktx_buf[ktx.HEADER_SIZE..], output_buf[0..]);
    lifecycle_state = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&ktx_buf[0])),
        .failed = 0,
    };
}

fn ensureInit() void {
    if (initialized) return;
    initialized = true;

    var sc = &scenarios[0];
    sc.active = true;
    sc.name = "Original";
    sc.employee_count = 7;

    const default_team = [_]struct {
        id: u8,
        name: []const u8,
        title: []const u8,
        reports_to: u8,
        color: Color,
    }{
        .{ .id = 1, .name = "Alice", .title = "CEO", .reports_to = 0, .color = PALETTE[0] },
        .{ .id = 2, .name = "Bob", .title = "VP Eng", .reports_to = 1, .color = PALETTE[1] },
        .{ .id = 3, .name = "Charlie", .title = "VP Product", .reports_to = 1, .color = PALETTE[1] },
        .{ .id = 4, .name = "Dave", .title = "Tech Lead", .reports_to = 2, .color = PALETTE[2] },
        .{ .id = 5, .name = "Eve", .title = "Senior Dev", .reports_to = 4, .color = PALETTE[3] },
        .{ .id = 6, .name = "Frank", .title = "Designer", .reports_to = 3, .color = PALETTE[4] },
        .{ .id = 7, .name = "Grace", .title = "QA Lead", .reports_to = 4, .color = PALETTE[2] },
    };

    for (default_team, 0..) |member, i| {
        var emp = &sc.employees[i];
        emp.id = member.id;
        emp.reports_to = member.reports_to;
        emp.active = true;
        emp.color = member.color;

        @memcpy(emp.name[0..member.name.len], member.name);
        emp.name_len = @as(u8, @intCast(member.name.len));

        @memcpy(emp.title[0..member.title.len], member.title);
        emp.title_len = @as(u8, @intCast(member.title.len));
    }

    var t: usize = 1;
    while (t < MAX_SCENARIOS) : (t += 1) {
        scenarios[t].active = false;
    }
}

// Subtree width and coordinate calculations for dynamic layout
fn calculateLayout() void {
    const sc = &scenarios[active_scenario_idx];
    const count = sc.employee_count;

    // 1. Reset relationships
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        children_count[idx] = 0;
    }

    // 2. Map direct reports
    idx = 0;
    while (idx < count) : (idx += 1) {
        const emp = &sc.employees[idx];
        if (emp.reports_to != 0) {
            if (findEmployeeIndexById(emp.reports_to)) |p_idx| {
                const c_count = children_count[p_idx];
                if (c_count < MAX_EMPLOYEES) {
                    children[p_idx][c_count] = @as(u8, @intCast(idx));
                    children_count[p_idx] += 1;
                }
            }
        }
    }

    // 3. Find all roots (no manager or parent index is missing)
    var root_indices: [MAX_EMPLOYEES]u8 = undefined;
    var root_count: usize = 0;

    idx = 0;
    while (idx < count) : (idx += 1) {
        const emp = &sc.employees[idx];
        var is_root = false;
        if (emp.reports_to == 0) {
            is_root = true;
        } else {
            if (findEmployeeIndexById(emp.reports_to) == null) {
                is_root = true;
            }
        }
        if (is_root) {
            root_indices[root_count] = @as(u8, @intCast(idx));
            root_count += 1;
        }
    }

    // 4. Compute widths of each subtree
    idx = 0;
    while (idx < count) : (idx += 1) {
        _ = computeSubtreeWidth(idx);
    }

    // 5. Position subtrees centered inside the tree pane (x = 10 to 410)
    var total_roots_width: i32 = 0;
    var r: usize = 0;
    while (r < root_count) : (r += 1) {
        total_roots_width += subtree_width[root_indices[r]];
    }
    if (root_count > 1) {
        total_roots_width += @as(i32, @intCast(root_count - 1)) * 18;
    }

    const tree_pane_width: i32 = 400;
    const start_x = 10 + @divTrunc(tree_pane_width - total_roots_width, 2);

    var current_x = start_x;
    r = 0;
    while (r < root_count) : (r += 1) {
        const root_idx = root_indices[r];
        positionSubtree(root_idx, current_x, 0);
        current_x += subtree_width[root_idx] + 18;
    }
}

fn computeSubtreeWidth(u: usize) i32 {
    const c_count = children_count[u];
    if (c_count == 0) {
        subtree_width[u] = 72; // Width of a node box (60) + minimum siblings spacing
        return 72;
    }
    var total: i32 = 0;
    var i: usize = 0;
    while (i < c_count) : (i += 1) {
        const child_idx = children[u][i];
        total += computeSubtreeWidth(child_idx);
    }
    total += @as(i32, @intCast(c_count - 1)) * 12; // Siblings gap
    subtree_width[u] = @max(total, 72);
    return subtree_width[u];
}

fn positionSubtree(u: usize, x_left: i32, depth: i32) void {
    const w = subtree_width[u];
    const x = x_left + @divTrunc(w, 2);
    const y = 80 + depth * 80;

    node_coords[u] = .{ .x = x, .y = y };

    const c_count = children_count[u];
    if (c_count > 0) {
        var current_x = x_left;
        var i: usize = 0;
        while (i < c_count) : (i += 1) {
            const child_idx = children[u][i];
            const child_width = subtree_width[child_idx];
            positionSubtree(child_idx, current_x, depth + 1);
            current_x += child_width + 12;
        }
    }
}

// Rendering Core
fn drawFrame() void {
    // 1. Dark glowing space background (Nebula shader layout)
    drawVerticalGradient(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), .{ 0x0D, 0x0A, 0x1B, 0xFF }, .{ 0x04, 0x03, 0x08, 0xFF });

    // Background glow spots (electric cyber-nebula look)
    drawGlow(120, 360, 140, .{ 0x06, 0xB6, 0xD4, 0xFF }); // Cyan spot bottom left
    drawGlow(460, 100, 160, .{ 0xEC, 0x48, 0x99, 0xFF }); // Neon pink spot top right
    drawGlow(250, 200, 150, .{ 0x4F, 0x46, 0xE5, 0xFF }); // Deep indigo glow in tree center

    // 2. Draw pane borders
    // Tree Area border
    drawRect(10, 40, 400, 400, .{ 0xFF, 0xFF, 0xFF, 0x14 });
    // Sidebar inspect pane (glass)
    drawGlassRect(420, 40, 170, 400, .{ 0xFF, 0xFF, 0xFF, 0x22 });

    const sc = &scenarios[active_scenario_idx];

    // 3. Draw Orthogonal Connection lines
    var i: usize = 0;
    while (i < sc.employee_count) : (i += 1) {
        const emp = &sc.employees[i];
        if (emp.reports_to != 0) {
            if (findEmployeeIndexById(emp.reports_to)) |p_idx| {
                const parent = &sc.employees[p_idx];
                const p_coord = node_coords[p_idx];
                const c_coord = node_coords[i];

                // Right angle route coordinates
                const p_bottom_x = p_coord.x;
                const p_bottom_y = p_coord.y + 18;
                const c_top_x = c_coord.x;
                const c_top_y = c_coord.y - 18;

                const mid_y = p_bottom_y + @divTrunc(c_top_y - p_bottom_y, 2);

                const is_active_connection = emp.active and parent.active;
                const line_color = if (is_active_connection) Color{ 0x81, 0x8C, 0xFB, 0xFF } else Color{ 0x47, 0x55, 0x69, 0xFF };
                const line_opacity: f32 = if (is_active_connection) 0.65 else 0.35;

                // Vertical down from parent
                blendVLine(p_bottom_x, p_bottom_y, mid_y, line_color, line_opacity);
                // Horizontal link
                blendHLine(p_bottom_x, c_top_x, mid_y, line_color, line_opacity);
                // Vertical down to child
                blendVLine(c_top_x, mid_y, c_top_y, line_color, line_opacity);
            }
        }
    }

    // 4. Draw Employee Node Boxes
    i = 0;
    while (i < sc.employee_count) : (i += 1) {
        const emp = &sc.employees[i];
        const coord = node_coords[i];

        const is_selected = (emp.id == selected_emp_id);
        const is_hovered = (emp.id == hovered_emp_id);

        // Fill background
        var yy: i32 = coord.y - 18;
        while (yy < coord.y + 18) : (yy += 1) {
            var xx: i32 = coord.x - 30;
            while (xx < coord.x + 30) : (xx += 1) {
                blendPixel(xx, yy, .{ 0x13, 0x11, 0x24, 0xFF }, if (emp.active) 0.85 else 0.4);
            }
        }

        // Draw borders
        var b_color = emp.color;
        var b_opacity: f32 = 0.5;
        if (!emp.active) {
            b_color = .{ 0x47, 0x55, 0x69, 0xFF };
            b_opacity = 0.25;
        } else if (is_selected) {
            b_color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
            b_opacity = 1.0;
            // Draw neon active border shadow/glow
            blendRect(coord.x - 31, coord.y - 19, 62, 38, emp.color, 0.4);
        } else if (is_hovered) {
            b_color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
            b_opacity = 0.8;
        }
        blendRect(coord.x - 30, coord.y - 18, 60, 36, b_color, b_opacity);

        // Render Names & Titles inside Node
        const name_color = if (emp.active) Color{ 0xFF, 0xFF, 0xFF, 0xFF } else Color{ 0x64, 0x74, 0x8B, 0xFF };
        const title_color = if (emp.active) Color{ 0x94, 0xA3, 0xB8, 0xFF } else Color{ 0x47, 0x55, 0x69, 0xFF };

        drawCenteredText(coord.x, coord.y - 10, emp.name[0..emp.name_len], name_color, 2);
        drawCenteredText(coord.x, coord.y + 3, emp.title[0..emp.title_len], title_color, 1);

        // Fired indicator strike-through
        if (!emp.active) {
            // Diagonal Red strike cross
            blendLine(coord.x - 24, coord.y - 12, coord.x + 24, coord.y + 12, .{ 0xEF, 0x44, 0x44, 0xFF }, 0.6);
            blendLine(coord.x - 24, coord.y + 12, coord.x + 24, coord.y - 12, .{ 0xEF, 0x44, 0x44, 0xFF }, 0.6);
        }
    }

    // 5. Render Tab Bar Elements
    var t: i32 = 0;
    while (t < MAX_SCENARIOS) : (t += 1) {
        const tx = 10 + t * 105;
        const is_active_tab = (active_scenario_idx == @as(usize, @intCast(t)));
        const is_hovered_tab = (hovered_tab_idx == t);

        const tab_scenario = &scenarios[@as(usize, @intCast(t))];

        if (tab_scenario.active) {
            // Draw regular tab
            if (is_active_tab) {
                // Indigo glossy active tab
                var ty: i32 = 8;
                while (ty < 30) : (ty += 1) {
                    const grad_ratio = @as(f32, @floatFromInt(ty - 8)) / 22.0;
                    const r = @as(u8, @intFromFloat(79.0 * (1.0 - grad_ratio) + 67.0 * grad_ratio));
                    const g = @as(u8, @intFromFloat(70.0 * (1.0 - grad_ratio) + 56.0 * grad_ratio));
                    const b = @as(u8, @intFromFloat(229.0 * (1.0 - grad_ratio) + 202.0 * grad_ratio));
                    blendHLine(tx, tx + 95, ty, .{ r, g, b, 0xFF }, 0.9);
                }
                drawRect(tx, 8, 95, 22, .{ 0xA5, 0xB4, 0xFC, 0xFF });
            } else {
                // Inactive scenario tab
                drawGlassRect(tx, 8, 95, 22, .{ 0xFF, 0xFF, 0xFF, if (is_hovered_tab) 0x40 else 0x15 });
            }
            // Draw Scenario Name inside tab
            const tab_name = tab_scenario.name;
            drawCenteredText(tx + 47, 12, tab_name, .{ 0xFF, 0xFF, 0xFF, 0xFF }, 1);
        } else {
            // Blank / Create fork tab
            drawGlassRect(tx, 8, 95, 22, .{ 0xFF, 0xFF, 0xFF, if (is_hovered_tab) 0x25 else 0x0F });
            const fork_lbl = "+ FORK PLAN";
            drawCenteredText(tx + 47, 12, fork_lbl, .{ 0x94, 0xA3, 0xB8, 0x88 }, 1);
        }
    }

    // 6. Draw Right Sidebar Inspect / Command Center
    drawCenteredText(505, 50, "COMMAND PORTAL", .{ 0x81, 0x8C, 0xFB, 0xFF }, 2);
    fillRectI32(430, 65, 150, 1, .{ 0x81, 0x8C, 0xFB, 0x33 });

    if (selected_emp_id == 0) {
        // Empty Inspection Placeholder
        drawCenteredText(505, 120, "NO WORKER SELECTED", .{ 0x94, 0xA3, 0xB8, 0xFF }, 1);

        const hints = [_][]const u8{ "Click on any team member", "in the tree to inspect", "them, update details,", "reassign manager,", "fire or rehire.", "", "Create Scenario plans", "using tabs at the top", "to compare fork models." };
        var h_idx: i32 = 0;
        while (h_idx < hints.len) : (h_idx += 1) {
            drawCenteredText(505, 150 + h_idx * 14, hints[@as(usize, @intCast(h_idx))], .{ 0x47, 0x55, 0x69, 0xFF }, 1);
        }

        // Add root hire button
        drawGlassRect(430, 315, 150, 24, .{ 0x10, 0xB9, 0x81, 0x66 });
        drawCenteredText(505, 321, "+ HIRE WORKER", .{ 0x10, 0xB9, 0x81, 0xFF }, 1);
    } else {
        // Detailed Inspect Panel for Selected Worker
        const sel_idx = findEmployeeIndexById(selected_emp_id).?;
        const emp = &sc.employees[sel_idx];

        // --- NAME FIELD ---
        drawTextScaled(430, 71, "NAME", .{ 0x47, 0x55, 0x69, 0xFF }, 1);
        const name_border = if (focused_field == .name) Color{ 0xFF, 0xFF, 0xFF, 0xFF } else Color{ 0xFF, 0xFF, 0xFF, 0x1A };
        drawGlassRect(430, 80, 150, 24, name_border);
        if (focused_field == .name) {
            drawTextScaled(438, 86, edit_buffer[0..edit_len], .{ 0xFF, 0xFF, 0xFF, 0xFF }, 2);
            if (cursor_blink) {
                const text_w = @as(i32, @intCast(edit_len)) * 8;
                fillRectI32(438 + text_w, 84, 1, 12, .{ 0xFF, 0xFF, 0xFF, 0xFF });
            }
        } else {
            drawTextScaled(438, 86, emp.name[0..emp.name_len], .{ 0xFF, 0xFF, 0xFF, 0xFF }, 2);
        }

        // --- TITLE FIELD ---
        drawTextScaled(430, 121, "ROLE / TITLE", .{ 0x47, 0x55, 0x69, 0xFF }, 1);
        const title_border = if (focused_field == .title) Color{ 0xFF, 0xFF, 0xFF, 0xFF } else Color{ 0xFF, 0xFF, 0xFF, 0x1A };
        drawGlassRect(430, 130, 150, 24, title_border);
        if (focused_field == .title) {
            drawTextScaled(438, 138, edit_buffer[0..edit_len], .{ 0xFF, 0xFF, 0xFF, 0xFF }, 1);
            if (cursor_blink) {
                const text_w = @as(i32, @intCast(edit_len)) * 4;
                fillRectI32(438 + text_w, 137, 1, 6, .{ 0xFF, 0xFF, 0xFF, 0xFF });
            }
        } else {
            drawTextScaled(438, 138, emp.title[0..emp.title_len], .{ 0xFF, 0xFF, 0xFF, 0xFF }, 1);
        }

        // --- REPORTING MANAGER LINE ---
        drawTextScaled(430, 171, "REPORTS TO", .{ 0x47, 0x55, 0x69, 0xFF }, 1);

        const reassign_border = if (reassign_mode) Color{ 0xEF, 0x44, 0x44, 0xFF } else Color{ 0xFF, 0xFF, 0xFF, 0x1A };
        drawGlassRect(430, 185, 150, 22, reassign_border);
        if (reassign_mode) {
            drawCenteredText(505, 191, "SELECT IN TREE...", .{ 0xEF, 0x44, 0x44, 0xFF }, 1);
        } else {
            if (emp.reports_to == 0) {
                drawCenteredText(505, 191, "ROOT / CEO", .{ 0x94, 0xA3, 0xB8, 0x99 }, 1);
            } else {
                if (findEmployeeIndexById(emp.reports_to)) |p_idx| {
                    const parent = &sc.employees[p_idx];
                    drawCenteredText(505, 191, parent.name[0..parent.name_len], .{ 0xFF, 0xFF, 0xFF, 0xFF }, 1);
                } else {
                    drawCenteredText(505, 191, "ROOT / CEO", .{ 0x94, 0xA3, 0xB8, 0x99 }, 1);
                }
            }
        }

        // --- THEME COLOR ACCENTS ---
        drawTextScaled(430, 218, "THEME", .{ 0x47, 0x55, 0x69, 0xFF }, 1);
        var c: usize = 0;
        while (c < 5) : (c += 1) {
            const cx = 440 + @as(i32, @intCast(c * 25));
            const cy = 232;
            fillCircle(cx, cy, 6, PALETTE[c]);
            const matches_color = (emp.color[0] == PALETTE[c][0] and emp.color[1] == PALETTE[c][1] and emp.color[2] == PALETTE[c][2]);
            if (matches_color) {
                // Draw selection ring
                drawCircle(cx, cy, 8, .{ 255, 255, 255, 255 });
            }
        }

        // --- FIRE / REHIRE BUTTON ---
        if (emp.active) {
            drawGlassRect(430, 265, 150, 24, .{ 0xEF, 0x44, 0x44, 0x4D });
            drawCenteredText(505, 271, "FIRE WORKER", .{ 0xEF, 0x44, 0x44, 0xFF }, 1);
        } else {
            drawGlassRect(430, 265, 150, 24, .{ 0x10, 0xB9, 0x81, 0x4D });
            drawCenteredText(505, 271, "REHIRE WORKER", .{ 0x10, 0xB9, 0x81, 0xFF }, 1);
        }

        // --- ACTION BUTTONS (HIRE REPORT, DELETE) ---
        drawGlassRect(430, 315, 150, 24, .{ 0x10, 0xB9, 0x81, 0x66 });
        drawCenteredText(505, 321, "+ HIRE REPORT", .{ 0x10, 0xB9, 0x81, 0xFF }, 1);

        drawGlassRect(430, 355, 150, 24, .{ 0xEF, 0x44, 0x44, 0x66 });
        drawCenteredText(505, 361, "DELETE WORKER", .{ 0xEF, 0x44, 0x44, 0xFF }, 1);
    }

    // 7. Render reassign helper banner overlay
    if (reassign_mode) {
        fillRectI32(18, 410, 384, 24, .{ 0xEF, 0x44, 0x44, 0xCC });
        drawCenteredText(210, 417, "REASSIGN: CLICK NEW MANAGER IN TREE (ESC TO CANCEL)", .{ 0xFF, 0xFF, 0xFF, 0xFF }, 1);
    }
}

// Layout helper / data operations
fn commitEdit() void {
    if (selected_emp_id == 0) return;
    const sc = &scenarios[active_scenario_idx];
    const idx_opt = findEmployeeIndexById(selected_emp_id);
    if (idx_opt) |idx| {
        const emp = &sc.employees[idx];
        if (focused_field == .name) {
            if (edit_len > 0) {
                @memcpy(emp.name[0..edit_len], edit_buffer[0..edit_len]);
                emp.name_len = @as(u8, @intCast(edit_len));
            }
        } else if (focused_field == .title) {
            @memcpy(emp.title[0..edit_len], edit_buffer[0..edit_len]);
            emp.title_len = @as(u8, @intCast(edit_len));
        }
    }
    focused_field = .none;
}

fn forkScenario(target_idx: usize) void {
    if (target_idx == 0 or target_idx >= MAX_SCENARIOS) return;
    scenarios[target_idx] = scenarios[active_scenario_idx];
    scenarios[target_idx].active = true;
    scenarios[target_idx].name = switch (target_idx) {
        1 => "Plan A",
        2 => "Plan B",
        3 => "Plan C",
        else => "Plan Copy",
    };
    active_scenario_idx = target_idx;
}

fn hireWorker(reports_to_id: u8) void {
    const sc = &scenarios[active_scenario_idx];
    if (sc.employee_count >= MAX_EMPLOYEES) return;

    var new_id: u8 = 1;
    while (true) {
        var id_exists = false;
        var i: usize = 0;
        while (i < sc.employee_count) : (i += 1) {
            if (sc.employees[i].id == new_id) {
                id_exists = true;
                break;
            }
        }
        if (!id_exists) break;
        new_id += 1;
    }

    const pool = [_][]const u8{ "Harry", "Ivy", "Jack", "Karen", "Leo", "Mia", "Noah", "Olivia", "Peter", "Quinn", "Ruby", "Sam", "Tina", "Uma" };
    const name_idx = sc.employee_count % pool.len;
    const picked_name = pool[name_idx];

    var new_emp: Employee = .{
        .id = new_id,
        .name = undefined,
        .name_len = @as(u8, @intCast(picked_name.len)),
        .title = undefined,
        .title_len = 10,
        .reports_to = reports_to_id,
        .active = true,
        .color = PALETTE[2], // Default Mint accent
    };
    @memcpy(new_emp.name[0..picked_name.len], picked_name);

    const default_title = "Specialist";
    @memcpy(new_emp.title[0..default_title.len], default_title);
    new_emp.title_len = @as(u8, @intCast(default_title.len));

    sc.employees[sc.employee_count] = new_emp;
    sc.employee_count += 1;

    selected_emp_id = new_id;
    focused_field = .name;
    @memcpy(edit_buffer[0..picked_name.len], picked_name);
    edit_len = picked_name.len;
}

fn deleteWorker(id: u8) void {
    const sc = &scenarios[active_scenario_idx];
    const idx_opt = findEmployeeIndexById(id);
    if (idx_opt) |idx| {
        const emp = &sc.employees[idx];
        const parent_id = emp.reports_to;

        // Reassign direct reports to parent to prevent tree orphans
        var i: usize = 0;
        while (i < sc.employee_count) : (i += 1) {
            if (sc.employees[i].reports_to == id) {
                sc.employees[i].reports_to = parent_id;
            }
        }

        // Shift remaining employees down
        var j = idx;
        while (j < sc.employee_count - 1) : (j += 1) {
            sc.employees[j] = sc.employees[j + 1];
        }
        sc.employee_count -= 1;

        selected_emp_id = 0;
        focused_field = .none;
    }
}

fn findEmployeeIndexById(id: u8) ?usize {
    const sc = &scenarios[active_scenario_idx];
    var i: usize = 0;
    while (i < sc.employee_count) : (i += 1) {
        if (sc.employees[i].id == id) return i;
    }
    return null;
}

fn isDescendant(u_id: u8, potential_descendant_id: u8) bool {
    if (u_id == potential_descendant_id) return true;
    const sc = &scenarios[active_scenario_idx];
    var curr_id = potential_descendant_id;
    var visited_count: usize = 0; // Prevent infinite loops
    while (curr_id != 0 and visited_count < MAX_EMPLOYEES) : (visited_count += 1) {
        var found_parent = false;
        var i: usize = 0;
        while (i < sc.employee_count) : (i += 1) {
            if (sc.employees[i].id == curr_id) {
                if (sc.employees[i].reports_to == u_id) return true;
                curr_id = sc.employees[i].reports_to;
                found_parent = true;
                break;
            }
        }
        if (!found_parent) break;
    }
    return false;
}

// Drawing Utilities / Bresenham Math / Font Renderer
fn isPrintable(key: i32) bool {
    return key >= 32 and key <= 126;
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = @max(0, x0);
    const sy = @max(0, y0);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x0 + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y0 + h);
    if (sx >= ex or sy >= ey) return;
    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) setPixelI32(x, y, c);
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

fn blendPixel(x: i32, y: i32, src: Color, alpha: f32) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;

    const r = @as(f32, @floatFromInt(output_buf[idx + 0]));
    const g = @as(f32, @floatFromInt(output_buf[idx + 1]));
    const b = @as(f32, @floatFromInt(output_buf[idx + 2]));

    const sr = @as(f32, @floatFromInt(src[0]));
    const sg = @as(f32, @floatFromInt(src[1]));
    const sb = @as(f32, @floatFromInt(src[2]));

    output_buf[idx + 0] = @as(u8, @intFromFloat(clampF32(r * (1.0 - alpha) + sr * alpha, 0.0, 255.0)));
    output_buf[idx + 1] = @as(u8, @intFromFloat(clampF32(g * (1.0 - alpha) + sg * alpha, 0.0, 255.0)));
    output_buf[idx + 2] = @as(u8, @intFromFloat(clampF32(b * (1.0 - alpha) + sb * alpha, 0.0, 255.0)));
}

fn clampF32(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn drawGlassRect(x: i32, y: i32, w: i32, h: i32, border_color: Color) void {
    const sx = @max(0, x);
    const sy = @max(0, y);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y + h);
    var yy = sy;
    while (yy < ey) : (yy += 1) {
        var xx = sx;
        while (xx < ex) : (xx += 1) {
            blendPixel(xx, yy, .{ 0x11, 0x0E, 0x22, 0xFF }, 0.5);
        }
    }
    drawRect(x, y, w, h, border_color);
}

fn drawVerticalGradient(x0: i32, y0: i32, w: i32, h: i32, top: Color, bottom: Color) void {
    if (w <= 0 or h <= 0) return;
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        const t = @divTrunc(yy * 255, @max(1, h - 1));
        const c: Color = .{
            lerpU8(top[0], bottom[0], t),
            lerpU8(top[1], bottom[1], t),
            lerpU8(top[2], bottom[2], t),
            0xFF,
        };
        fillRectI32(x0, y0 + yy, w, 1, c);
    }
}

fn lerpU8(a: u8, b: u8, t255: i32) u8 {
    const inv = 255 - t255;
    const v = @divTrunc(@as(i32, a) * inv + @as(i32, b) * t255 + 127, 255);
    return @as(u8, @intCast(clampI32(v, 0, 255)));
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn drawGlow(cx: i32, cy: i32, r: i32, color: Color) void {
    const x_start = @max(0, cx - r);
    const x_end = @min(@as(i32, @intCast(RENDER_W)), cx + r);
    const y_start = @max(0, cy - r);
    const y_end = @min(@as(i32, @intCast(RENDER_H)), cy + r);

    const r_sq = r * r;
    const r_sq_f = @as(f32, @floatFromInt(r_sq));

    var y = y_start;
    while (y < y_end) : (y += 1) {
        const dy = y - cy;
        const dy_sq = dy * dy;
        var x = x_start;
        while (x < x_end) : (x += 1) {
            const dx = x - cx;
            const dist_sq = dx * dx + dy_sq;
            if (dist_sq < r_sq) {
                const dist_sq_f = @as(f32, @floatFromInt(dist_sq));
                const intensity = (1.0 - dist_sq_f / r_sq_f) * 0.16; // Soft aura
                blendPixel(x, y, color, intensity);
            }
        }
    }
}

fn blendRect(x: i32, y: i32, w: i32, h: i32, c: Color, alpha: f32) void {
    blendHLine(x, x + w - 1, y, c, alpha);
    blendHLine(x, x + w - 1, y + h - 1, c, alpha);
    blendVLine(x, y, y + h - 1, c, alpha);
    blendVLine(x + w - 1, y, y + h - 1, c, alpha);
}

fn blendHLine(x1: i32, x2: i32, y: i32, c: Color, alpha: f32) void {
    const start = @min(x1, x2);
    const end = @max(x1, x2);
    var x = start;
    while (x <= end) : (x += 1) {
        blendPixel(x, y, c, alpha);
    }
}

fn blendVLine(x: i32, y1: i32, y2: i32, c: Color, alpha: f32) void {
    const start = @min(y1, y2);
    const end = @max(y1, y2);
    var y = start;
    while (y <= end) : (y += 1) {
        blendPixel(x, y, c, alpha);
    }
}

fn blendLine(x1: i32, y1: i32, x2: i32, y2: i32, c: Color, alpha: f32) void {
    const dx = @abs(x2 - x1);
    const dy = @abs(y2 - y1);
    const sx: i32 = if (x1 < x2) 1 else -1;
    const sy: i32 = if (y1 < y2) 1 else -1;
    var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

    var x = x1;
    var y = y1;
    while (true) {
        blendPixel(x, y, c, alpha);
        if (x == x2 and y == y2) break;
        const e2 = 2 * err;
        if (e2 > -@as(i32, @intCast(dy))) {
            err -= @as(i32, @intCast(dy));
            x += sx;
        }
        if (e2 < @as(i32, @intCast(dx))) {
            err += @as(i32, @intCast(dx));
            y += sy;
        }
    }
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) {
                blendPixel(x, y, c, 1.0);
            }
        }
    }
}

fn drawCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq >= (r - 1) * (r - 1) and dist_sq <= r * r) {
                blendPixel(x, y, c, 1.0);
            }
        }
    }
}

// Custom 3x5 font scaled rendering identical to textedit
fn drawCenteredText(cx: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    if (text.len == 0) return;
    const text_w = @as(i32, @intCast(text.len)) * (4 * scale) - scale;
    const x = cx - @divTrunc(text_w, 2);
    drawTextScaled(x, y, text, c, scale);
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
    }
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            fillRectI32(
                x + @as(i32, @intCast(rx)) * scale,
                y + @as(i32, @intCast(ry)) * scale,
                scale,
                scale,
                c,
            );
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G', 'g' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q', 'q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z', 'z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        ',' => .{ 0b000, 0b000, 0b000, 0b010, 0b100 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        ';' => .{ 0b000, 0b010, 0b000, 0b010, 0b100 },
        '!' => .{ 0b010, 0b010, 0b010, 0b000, 0b010 },
        '?' => .{ 0b111, 0b001, 0b011, 0b000, 0b010 },
        '"' => .{ 0b101, 0b101, 0b000, 0b000, 0b000 },
        '\'' => .{ 0b010, 0b010, 0b000, 0b000, 0b000 },
        '(' => .{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => .{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '[' => .{ 0b011, 0b010, 0b010, 0b010, 0b011 },
        ']' => .{ 0b110, 0b010, 0b010, 0b010, 0b110 },
        '{' => .{ 0b001, 0b010, 0b110, 0b010, 0b001 },
        '}' => .{ 0b100, 0b010, 0b011, 0b010, 0b100 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '\\' => .{ 0b100, 0b100, 0b010, 0b001, 0b001 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => .{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '=' => .{ 0b000, 0b111, 0b000, 0b111, 0b000 },
        '_' => .{ 0b000, 0b000, 0b000, 0b000, 0b111 },
        '|' => .{ 0b010, 0b010, 0b010, 0b010, 0b010 },
        '#' => .{ 0b101, 0b111, 0b101, 0b111, 0b101 },
        '$' => .{ 0b010, 0b111, 0b110, 0b011, 0b111 },
        '%' => .{ 0b101, 0b001, 0b010, 0b100, 0b101 },
        '&' => .{ 0b010, 0b101, 0b010, 0b101, 0b011 },
        '@' => .{ 0b111, 0b101, 0b111, 0b100, 0b111 },
        '^' => .{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '`' => .{ 0b010, 0b001, 0b000, 0b000, 0b000 },
        '~' => .{ 0b000, 0b011, 0b110, 0b000, 0b000 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}
