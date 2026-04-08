const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const types = @import("types.zig");

const Platform = @This();
const Surface = surfaceTargetType();

pub const BuildError = error{
    SurfaceRequired,
    InvalidSurfaceTarget,
};

pub fn resolveExecutionMode(config: *const configpkg.Config) types.AgentExecutionMode {
    return switch (config.@"ai-agent-handoff-mode") {
        .review_before_execute => .review_before_execute,
        .auto_execute_trusted => if (config.@"ai-agent-auto-execute")
            .auto_execute_trusted
        else
            .review_before_execute,
    };
}

pub fn resolveHandoff(
    config: *const configpkg.Config,
    awareness: types.AISessionAwareness,
    objective: []const u8,
) types.AgentHandoff {
    return .init(resolveExecutionMode(config), awareness, objective);
}

pub fn buildHandoffForTarget(
    alloc: Allocator,
    target: apprt.Target,
    config: *const configpkg.Config,
    objective: []const u8,
    awareness_provider: anytype,
) !types.AgentHandoff {
    const surface = switch (target) {
        .app => return error.SurfaceRequired,
        .surface => |surface| surface,
    };
    const awareness = try awareness_provider(alloc, surface);
    return resolveHandoff(config, awareness, objective);
}

fn surfaceTargetType() type {
    inline for (@typeInfo(apprt.Target).@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, "surface")) return field.type;
    }
    unreachable;
}

test "handoff: can build a handoff from a target surface" {
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();

    const target_surface: Surface = @ptrFromInt(64);
    const handoff = try Platform.buildHandoffForTarget(
        testing.allocator,
        .{ .surface = target_surface },
        &config,
        "investigate recent failure",
        struct {
            fn provide(_: Allocator, surface: Surface) !types.AISessionAwareness {
                try testing.expectEqual(@as(Surface, @ptrFromInt(64)), surface);
                return .{
                    .prompt_state = .at_prompt,
                    .working_directory = "/workspace/project",
                    .last_command = "zig build test",
                    .last_exit_code = 1,
                    .has_selection = true,
                };
            }
        }.provide,
    );

    try testing.expectEqual(types.AgentExecutionMode.auto_execute_trusted, handoff.mode);
    try testing.expectEqual(types.AISessionAwareness.PromptState.at_prompt, handoff.awareness.prompt_state);
    try testing.expectEqualStrings("investigate recent failure", handoff.objective);
    try testing.expectEqualStrings("/workspace/project", handoff.awareness.working_directory.?);
    try testing.expectEqualStrings("zig build test", handoff.awareness.last_command.?);
    try testing.expectEqual(@as(?u8, 1), handoff.awareness.last_exit_code);
    try testing.expect(handoff.awareness.has_selection);
}

test "handoff: app target without surface is rejected cleanly" {
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();

    try testing.expectError(
        error.SurfaceRequired,
        Platform.buildHandoffForTarget(
            testing.allocator,
            .app,
            &config,
            "summarize session",
            struct {
                fn provide(_: Allocator, _: Surface) !types.AISessionAwareness {
                    return .{};
                }
            }.provide,
        ),
    );
}

test "handoff: contains objective session awareness and effective execution mode" {
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    config.@"ai-agent-handoff-mode" = .auto_execute_trusted;
    config.@"ai-agent-auto-execute" = false;

    const awareness: types.AISessionAwareness = .{
        .prompt_state = .command_running,
        .working_directory = "/workspace/ghostty",
        .last_command = "git status",
        .last_exit_code = 0,
        .has_selection = false,
    };
    const handoff = Platform.resolveHandoff(&config, awareness, "review repository state");

    try testing.expectEqual(types.AgentExecutionMode.review_before_execute, handoff.mode);
    try testing.expectEqualDeep(awareness, handoff.awareness);
    try testing.expectEqualStrings("review repository state", handoff.objective);
}
