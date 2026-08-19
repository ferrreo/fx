const std = @import("std");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

const max_sse_line_bytes: usize = 32 * 1024 * 1024;

pub const StreamCallback = agent_stream_provider.StreamCallback;
pub const ToolStartCallback = agent_stream_provider.ToolStartCallback;

pub fn buildChatCompletionsBody(
    alloc: Allocator,
    model: []const u8,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    for (messages, 0..) |message, i| {
        if (i > 0) try writer.writeByte(',');
        try writeOpenAiMessage(writer, message);
    }
    try writer.writeByte(']');
    try writeOpenAiTools(alloc, writer, tools_json, tool_choice, .chat_completions);
    if (max_output_tokens) |value| try writer.print(",\"max_tokens\":{d}", .{value});
    if (options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn buildResponsesBody(
    alloc: Allocator,
    model: []const u8,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    var instructions: []const u8 = "";
    var start: usize = 0;
    if (messages.len > 0 and messages[0].role == .system) {
        instructions = messages[0].content orelse "";
        start = 1;
    }

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"store\":false,\"instructions\":");
    try std.json.Stringify.value(instructions, .{}, writer);
    try writer.writeAll(",\"input\":[");
    var wrote = false;
    var i = start;
    while (i < messages.len) {
        const message = messages[i];
        if (message.role == .assistant and message.tool_calls.len > 0) {
            if (message.content) |content| {
                if (content.len > 0) {
                    if (wrote) try writer.writeByte(',');
                    try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote = true;
                }
            }
            for (message.tool_calls) |call| {
                if (wrote) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                try std.json.Stringify.value(call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments_json, .{}, writer);
                try writer.writeByte('}');
                wrote = true;
            }
            i += 1;
            continue;
        }
        if (message.role == .tool) {
            if (wrote) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"output\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
            wrote = true;
            i += 1;
            continue;
        }
        if (wrote) try writer.writeByte(',');
        try writeResponsesMessage(writer, message);
        wrote = true;
        i += 1;
    }
    try writer.writeByte(']');
    try writeOpenAiTools(alloc, writer, tools_json, tool_choice, .responses);
    if (max_output_tokens) |value| try writer.print(",\"max_output_tokens\":{d}", .{value});
    if (options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

const ToolEncoding = enum { chat_completions, responses };

fn writeOpenAiTools(
    alloc: Allocator,
    writer: *std.Io.Writer,
    tools_json: []const u8,
    tool_choice: types.ToolChoice,
    encoding: ToolEncoding,
) !void {
    const trimmed = std.mem.trim(u8, tools_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGatewayHistory,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidGatewayHistory;

    try writer.writeAll(",\"tools\":[");
    var wrote = false;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const name = jsonString(tool.object.get("name")) orelse continue;
        const description = jsonString(tool.object.get("description")) orelse "";
        const schema = tool.object.get("inputSchema") orelse tool.object.get("parameters") orelse continue;
        if (wrote) try writer.writeByte(',');
        switch (encoding) {
            .chat_completions => {
                try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
                try std.json.Stringify.value(name, .{}, writer);
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description, .{}, writer);
                try writer.writeAll(",\"parameters\":");
                try std.json.Stringify.value(schema, .{}, writer);
                try writer.writeAll("}}");
            },
            .responses => {
                try writer.writeAll("{\"type\":\"function\",\"name\":");
                try std.json.Stringify.value(name, .{}, writer);
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description, .{}, writer);
                try writer.writeAll(",\"parameters\":");
                try std.json.Stringify.value(schema, .{}, writer);
                try writer.writeByte('}');
            },
        }
        wrote = true;
    }
    try writer.writeByte(']');
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(tool_choice.label(), .{}, writer);
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const selected = value orelse return null;
    if (selected != .string) return null;
    return selected.string;
}

fn writeOpenAiMessage(writer: *std.Io.Writer, message: ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);
    switch (message.role) {
        .system, .user => {
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
        .assistant => {
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            if (message.tool_calls.len > 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
        },
        .tool => {
            try writer.writeAll(",\"tool_call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
    }
    try writer.writeByte('}');
}

fn writeResponsesMessage(writer: *std.Io.Writer, message: ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(message.content orelse "", .{}, writer);
    try writer.writeByte('}');
}

const ToolAcc = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    index: i64 = 0,
    started: bool = false,

    fn deinit(self: *ToolAcc, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

pub fn consumeChatCompletionsSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(ToolAcc) = .empty;
    defer {
        for (tools.items) |*acc| acc.deinit(alloc);
        tools.deinit(alloc);
    }
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    defer if (generation_id) |id| alloc.free(id);

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) break;
        const line = readSseLine(alloc, reader, &line_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (line.len == 0) continue;
        if (line[0] == ':') continue;
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (std.mem.eql(u8, payload, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        if (object.get("id")) |id_val| {
            if (id_val == .string and generation_id == null) {
                generation_id = try alloc.dupe(u8, id_val.string);
            }
        }
        if (object.get("usage")) |usage_val| captureUsage(usage_val, &usage);
        const choices = object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;
        if (choice.object.get("finish_reason")) |reason| {
            if (reason == .string) finish_reason = types.ProviderFinishReason.parse_legacy(reason.string) orelse .other;
        }
        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;
        if (delta.object.get("content")) |content_val| {
            if (content_val == .string and content_val.string.len > 0) {
                try content.appendSlice(alloc, content_val.string);
                on_content_chunk(callback_ctx, content_val.string);
            }
        }
        if (on_reasoning_chunk) |cb| {
            if (delta.object.get("reasoning_content") orelse delta.object.get("reasoning")) |reasoning| {
                if (reasoning == .string and reasoning.string.len > 0) cb(callback_ctx, reasoning.string);
            }
        }
        if (delta.object.get("tool_calls")) |calls| {
            if (calls == .array) {
                try absorbOpenAiToolDeltas(alloc, &tools, calls.array.items, callback_ctx, on_tool_start);
            }
        }
    }

    return takeCompletion(alloc, &content, &tools, finish_reason, usage, &generation_id);
}

pub fn consumeResponsesSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(ToolAcc) = .empty;
    defer {
        for (tools.items) |*acc| acc.deinit(alloc);
        tools.deinit(alloc);
    }
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    defer if (generation_id) |id| alloc.free(id);

    var event_name: std.ArrayList(u8) = .empty;
    defer event_name.deinit(alloc);
    var data_buf: std.ArrayList(u8) = .empty;
    defer data_buf.deinit(alloc);
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) break;
        const line = readSseLine(alloc, reader, &line_buf) catch |err| switch (err) {
            error.EndOfStream => {
                if (data_buf.items.len > 0) {
                    try applyResponsesEvent(
                        alloc,
                        event_name.items,
                        data_buf.items,
                        &content,
                        &tools,
                        &finish_reason,
                        &usage,
                        &generation_id,
                        callback_ctx,
                        on_content_chunk,
                        on_tool_start,
                        on_reasoning_chunk,
                    );
                    data_buf.clearRetainingCapacity();
                }
                break;
            },
            else => return err,
        };
        if (line.len == 0) {
            if (data_buf.items.len == 0) {
                event_name.clearRetainingCapacity();
                continue;
            }
            try applyResponsesEvent(
                alloc,
                event_name.items,
                data_buf.items,
                &content,
                &tools,
                &finish_reason,
                &usage,
                &generation_id,
                callback_ctx,
                on_content_chunk,
                on_tool_start,
                on_reasoning_chunk,
            );
            event_name.clearRetainingCapacity();
            data_buf.clearRetainingCapacity();
            continue;
        }
        if (line[0] == ':') continue;
        if (std.mem.startsWith(u8, line, "event:")) {
            event_name.clearRetainingCapacity();
            try event_name.appendSlice(alloc, std.mem.trim(u8, line["event:".len..], " \t"));
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            const payload = std.mem.trim(u8, line["data:".len..], " \t");
            if (data_buf.items.len > 0) try data_buf.append(alloc, '\n');
            try data_buf.appendSlice(alloc, payload);
        }
    }

    if (finish_reason == null and (content.items.len > 0 or tools.items.len > 0)) {
        finish_reason = if (tools.items.len > 0) .tool_calls else .stop;
    }
    return takeCompletion(alloc, &content, &tools, finish_reason, usage, &generation_id);
}

fn applyResponsesEvent(
    alloc: Allocator,
    event_name: []const u8,
    payload: []const u8,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAcc),
    finish_reason: *?types.ProviderFinishReason,
    usage: *types.Usage,
    generation_id: *?[]u8,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;
    const kind = if (event_name.len > 0) event_name else jsonString(object.get("type")) orelse return;

    if (std.mem.eql(u8, kind, "response.output_text.delta") or
        std.mem.eql(u8, kind, "response.output_text.delta.done"))
    {
        const delta = jsonString(object.get("delta")) orelse return;
        if (delta.len == 0) return;
        try content.appendSlice(alloc, delta);
        on_content_chunk(callback_ctx, delta);
        return;
    }
    if (std.mem.eql(u8, kind, "response.reasoning_text.delta") or
        std.mem.eql(u8, kind, "response.reasoning.delta"))
    {
        if (on_reasoning_chunk) |cb| {
            const delta = jsonString(object.get("delta")) orelse return;
            if (delta.len > 0) cb(callback_ctx, delta);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "response.output_item.added")) {
        const item = object.get("item") orelse return;
        if (item != .object) return;
        const item_type = jsonString(item.object.get("type")) orelse return;
        if (!std.mem.eql(u8, item_type, "function_call")) return;
        var acc: ToolAcc = .{};
        errdefer acc.deinit(alloc);
        if (jsonString(item.object.get("call_id")) orelse jsonString(item.object.get("id"))) |id| {
            try acc.id.appendSlice(alloc, id);
        }
        if (jsonString(item.object.get("name"))) |name| try acc.name.appendSlice(alloc, name);
        if (on_tool_start) |cb| {
            if (acc.id.items.len > 0 and acc.name.items.len > 0) {
                cb(callback_ctx, acc.id.items, acc.name.items, null);
                acc.started = true;
            }
        }
        try tools.append(alloc, acc);
        return;
    }
    if (std.mem.eql(u8, kind, "response.function_call_arguments.delta")) {
        const delta = jsonString(object.get("delta")) orelse return;
        const item_id = jsonString(object.get("item_id")) orelse jsonString(object.get("call_id"));
        if (tools.items.len == 0) return;
        var acc = if (item_id) |id| findToolById(tools.items, id) else &tools.items[tools.items.len - 1];
        try acc.arguments.appendSlice(alloc, delta);
        return;
    }
    if (std.mem.eql(u8, kind, "response.completed")) {
        finish_reason.* = if (tools.items.len > 0) .tool_calls else .stop;
        if (object.get("response")) |response| {
            if (response == .object) {
                if (jsonString(response.object.get("id"))) |id| {
                    if (generation_id.* == null) generation_id.* = try alloc.dupe(u8, id);
                }
                if (response.object.get("usage")) |usage_val| captureUsage(usage_val, usage);
            }
        }
        return;
    }
    if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "error")) {
        finish_reason.* = .provider_error;
    }
}

fn findToolById(tools: []ToolAcc, id: []const u8) *ToolAcc {
    for (tools) |*acc| {
        if (std.mem.eql(u8, acc.id.items, id)) return acc;
    }
    return &tools[tools.len - 1];
}

fn absorbOpenAiToolDeltas(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAcc),
    deltas: []const std.json.Value,
    callback_ctx: *anyopaque,
    on_tool_start: ?ToolStartCallback,
) !void {
    for (deltas) |delta| {
        if (delta != .object) continue;
        const index: i64 = if (delta.object.get("index")) |value|
            switch (value) {
                .integer => value.integer,
                else => @as(i64, @intCast(tools.items.len)),
            }
        else
            @as(i64, @intCast(tools.items.len));
        var acc = blk: {
            for (tools.items) |*existing| {
                if (existing.index == index) break :blk existing;
            }
            try tools.append(alloc, .{ .index = index });
            break :blk &tools.items[tools.items.len - 1];
        };
        if (jsonString(delta.object.get("id"))) |id| {
            if (acc.id.items.len == 0) try acc.id.appendSlice(alloc, id);
        }
        if (delta.object.get("function")) |function| {
            if (function == .object) {
                if (jsonString(function.object.get("name"))) |name| {
                    if (acc.name.items.len == 0) try acc.name.appendSlice(alloc, name);
                }
                if (jsonString(function.object.get("arguments"))) |arguments| {
                    try acc.arguments.appendSlice(alloc, arguments);
                }
            }
        }
        if (!acc.started and acc.id.items.len > 0 and acc.name.items.len > 0) {
            if (on_tool_start) |cb| cb(callback_ctx, acc.id.items, acc.name.items, null);
            acc.started = true;
        }
    }
}

fn captureUsage(value: std.json.Value, usage: *types.Usage) void {
    if (value != .object) return;
    if (intField(value.object.get("prompt_tokens") orelse value.object.get("input_tokens"))) |n| {
        usage.input_tokens = n;
    }
    if (intField(value.object.get("completion_tokens") orelse value.object.get("output_tokens"))) |n| {
        usage.output_tokens = n;
    }
}

fn intField(value: ?std.json.Value) ?u64 {
    const selected = value orelse return null;
    return switch (selected) {
        .integer => std.math.cast(u64, selected.integer),
        .float => if (selected.float >= 0) @intFromFloat(selected.float) else null,
        else => null,
    };
}

fn takeCompletion(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAcc),
    finish_reason: ?types.ProviderFinishReason,
    usage: types.Usage,
    generation_id: *?[]u8,
) !types.GatewayCompletion {
    const owned_id = generation_id.*;
    generation_id.* = null;
    return finishCompletion(alloc, content, tools, finish_reason, usage, owned_id);
}

fn finishCompletion(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAcc),
    finish_reason: ?types.ProviderFinishReason,
    usage: types.Usage,
    generation_id: ?[]u8,
) !types.GatewayCompletion {
    var tool_calls: []types.ToolCall = &.{};
    if (tools.items.len > 0) {
        tool_calls = try alloc.alloc(types.ToolCall, tools.items.len);
        errdefer alloc.free(tool_calls);
        for (tools.items, 0..) |*acc, i| {
            const id = try acc.id.toOwnedSlice(alloc);
            errdefer alloc.free(id);
            const name = try acc.name.toOwnedSlice(alloc);
            errdefer alloc.free(name);
            const arguments = try acc.arguments.toOwnedSlice(alloc);
            errdefer alloc.free(arguments);
            const integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, arguments);
            tool_calls[i] = .{
                .id = id,
                .name = name,
                .arguments_json = arguments,
                .argument_integrity = integrity,
            };
        }
        tools.clearRetainingCapacity();
    }

    const owned_content = if (content.items.len == 0) null else try content.toOwnedSlice(alloc);
    return .{
        .content = owned_content,
        .tool_calls = tool_calls,
        .generation_id = generation_id,
        .finish_reason = finish_reason orelse if (tool_calls.len > 0) .tool_calls else .stop,
        .usage = usage,
    };
}

fn readSseLine(
    alloc: Allocator,
    reader: anytype,
    buf: *std.ArrayList(u8),
) ![]const u8 {
    buf.clearRetainingCapacity();
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (buf.items.len == 0) return error.EndOfStream;
                return std.mem.trimEnd(u8, buf.items, "\r");
            },
            else => return err,
        };
        if (byte == '\n') return std.mem.trimEnd(u8, buf.items, "\r");
        if (buf.items.len >= max_sse_line_bytes) return error.StreamTooLong;
        try buf.append(alloc, byte);
    }
}

test "chat completions builder emits OpenAI tools and stream flag" {
    const messages = [_]ChatMessage{.{ .role = .user, .content = "hi" }};
    const tools =
        \\[{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object"}}]
    ;
    const body = try buildChatCompletionsBody(
        std.testing.allocator,
        "openai/gpt-5",
        tools,
        &messages,
        .{},
        .auto,
        128,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":128") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"function\":{\"name\":\"read_file\"") != null);
}

test "responses builder uses instructions and function_call history" {
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content = "hi" },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "c1", .name = "read_file", .arguments_json = "{\"path\":\"a\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "c1", .tool_name = "read_file", .content = "ok" },
    };
    const body = try buildResponsesBody(
        std.testing.allocator,
        "gpt-5.3-codex",
        "[]",
        &messages,
        .{},
        .auto,
        null,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"be terse\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
}

test "chat completions SSE accumulates content and tool calls" {
    const payload =
        \\data: {"id":"gen_1","choices":[{"delta":{"content":"Hel"}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"lo"}}]}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"p"}}]}}]}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ath\":\"a\"}"}}]},"finish_reason":"tool_calls"}]}
        \\
        \\data: [DONE]
        \\
    ;
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Capture = struct {
        chunks: usize = 0,
        fn on_chunk(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks += 1;
        }
        fn on_tool(raw: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks += 10;
        }
    };
    var capture: Capture = .{};
    const completion = try consumeChatCompletionsSse(
        std.testing.allocator,
        &reader,
        @ptrCast(&capture),
        Capture.on_chunk,
        Capture.on_tool,
        null,
        &cancel,
    );
    defer {
        if (completion.content) |text| std.testing.allocator.free(@constCast(text));
        if (completion.generation_id) |id| std.testing.allocator.free(@constCast(id));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("Hello", completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "responses SSE maps function call arguments" {
    const payload =
        \\event: response.output_text.delta
        \\data: {"delta":"hi"}
        \\
        \\event: response.output_item.added
        \\data: {"item":{"type":"function_call","call_id":"c1","name":"read_file"}}
        \\
        \\event: response.function_call_arguments.delta
        \\data: {"call_id":"c1","delta":"{\"path\":\"a\"}"}
        \\
        \\event: response.completed
        \\data: {"response":{"id":"resp_1","usage":{"input_tokens":3,"output_tokens":2}}}
        \\
    ;
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Capture = struct {
        fn on_chunk(_: *anyopaque, _: []const u8) void {}
        fn on_tool(_: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {}
    };
    var capture: u8 = 0;
    const completion = try consumeResponsesSse(
        std.testing.allocator,
        &reader,
        @ptrCast(&capture),
        Capture.on_chunk,
        Capture.on_tool,
        null,
        &cancel,
    );
    defer {
        if (completion.content) |text| std.testing.allocator.free(@constCast(text));
        if (completion.generation_id) |id| std.testing.allocator.free(@constCast(id));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("hi", completion.content.?);
    try std.testing.expectEqualStrings("c1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.input_tokens);
}
