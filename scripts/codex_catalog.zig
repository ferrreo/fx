const std = @import("std");

pub const source_url = "https://raw.githubusercontent.com/openai/codex/main/codex-rs/models-manager/models.json";
pub const snapshot_path = "src/generated/codex_catalog.json";

pub const Catalog = struct {
    json: []const u8,
    default_model: []const u8,
};

/// Compact openai/codex `models-manager/models.json` into fx's picker catalog shape.
pub fn compact(allocator: std.mem.Allocator, raw: []const u8) !Catalog {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.MalformedCodexModels;
    const models_value = root.object.get("models") orelse return error.MalformedCodexModels;
    if (models_value != .array) return error.MalformedCodexModels;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"object\":\"list\",\"data\":[");

    var default_model: ?[]u8 = null;
    errdefer if (default_model) |owned| allocator.free(owned);
    var best_priority: i64 = std.math.maxInt(i64);
    var first = true;
    var count: usize = 0;

    for (models_value.array.items) |entry| {
        if (entry != .object) continue;
        const slug_value = entry.object.get("slug") orelse continue;
        if (slug_value != .string) continue;
        const slug = slug_value.string;
        if (slug.len == 0 or std.mem.eql(u8, slug, "codex-auto-review")) continue;

        const priority: i64 = switch (entry.object.get("priority") orelse .null) {
            .integer => |n| n,
            else => 0,
        };
        const context_window: i64 = switch (entry.object.get("context_window") orelse .null) {
            .integer => |n| n,
            else => 0,
        };
        const visibility = switch (entry.object.get("visibility") orelse .null) {
            .string => |s| s,
            else => "",
        };

        var efforts: std.ArrayList([]const u8) = .empty;
        defer efforts.deinit(allocator);
        if (entry.object.get("supported_reasoning_levels")) |levels| {
            if (levels == .array) {
                for (levels.array.items) |level| {
                    if (level != .object) continue;
                    const effort = level.object.get("effort") orelse continue;
                    if (effort != .string or effort.string.len == 0) continue;
                    try efforts.append(allocator, effort.string);
                }
            }
        }

        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(slug, .{}, &out.writer);
        try out.writer.print(",\"type\":\"language\",\"released\":{d},\"tags\":[\"tool-use\"", .{10000 - priority});
        if (efforts.items.len > 0) try out.writer.writeAll(",\"reasoning\"");
        try out.writer.print("],\"context_window\":{d}", .{context_window});
        if (efforts.items.len > 0) {
            try out.writer.writeAll(",\"reasoning_options\":[{\"type\":\"effort\",\"values\":[");
            for (efforts.items, 0..) |effort, i| {
                if (i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(effort, .{}, &out.writer);
            }
            try out.writer.writeAll("]}]");
        }
        try out.writer.writeByte('}');
        count += 1;

        if (std.mem.eql(u8, visibility, "list") and priority < best_priority) {
            best_priority = priority;
            if (default_model) |owned| allocator.free(owned);
            default_model = try allocator.dupe(u8, slug);
        }
    }

    if (count == 0) return error.EmptyCodexModels;
    try out.writer.writeAll("]}");

    const owned_default = default_model orelse try allocator.dupe(u8, "gpt-5.6-sol");
    default_model = null;

    return .{
        .json = try out.toOwnedSlice(),
        .default_model = owned_default,
    };
}

/// Snapshot is already picker-shaped `{object,data}`. First listed id is the default.
pub fn fromPickerJson(allocator: std.mem.Allocator, json: []const u8) !Catalog {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedCodexModels;
    const data = parsed.value.object.get("data") orelse return error.MalformedCodexModels;
    if (data != .array or data.array.items.len == 0) return error.EmptyCodexModels;
    const first = data.array.items[0];
    if (first != .object) return error.MalformedCodexModels;
    const id = first.object.get("id") orelse return error.MalformedCodexModels;
    if (id != .string or id.string.len == 0) return error.MalformedCodexModels;
    return .{
        .json = try allocator.dupe(u8, json),
        .default_model = try allocator.dupe(u8, id.string),
    };
}

pub fn generatedZigSource(allocator: std.mem.Allocator, catalog: Catalog) ![]u8 {
    for (catalog.default_model) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.')
            return error.UnsafeCodexDefaultModel;
    }
    return std.fmt.allocPrint(
        allocator,
        "pub const default_model = \"{s}\";\npub const catalog_json = @embedFile(\"codex_catalog.json\");\n",
        .{catalog.default_model},
    );
}

test "compact keeps listed slugs and skips auto-review" {
    const raw =
        \\{"models":[
        \\  {"slug":"gpt-5.6-sol","priority":1,"visibility":"list","context_window":272000,"supported_reasoning_levels":[{"effort":"low"}]},
        \\  {"slug":"codex-auto-review","priority":43,"visibility":"hide","context_window":1,"supported_reasoning_levels":[]}
        \\]}
    ;
    const catalog = try compact(std.testing.allocator, raw);
    defer std.testing.allocator.free(catalog.json);
    defer std.testing.allocator.free(catalog.default_model);
    try std.testing.expectEqualStrings("gpt-5.6-sol", catalog.default_model);
    try std.testing.expect(std.mem.find(u8, catalog.json, "gpt-5.6-sol") != null);
    try std.testing.expect(std.mem.find(u8, catalog.json, "codex-auto-review") == null);
}
