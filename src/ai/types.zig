const std = @import("std");

const testing = std.testing;

pub const AgentExecutionMode = enum {
    review_before_execute,
    auto_execute_trusted,
};

pub const AISessionAwareness = struct {
    pub const PromptState = enum {
        unknown,
        at_prompt,
        command_running,
        password_input,
    };

    /// String fields are plain slices. APIs that duplicate them into owned
    /// memory transfer that ownership to the caller, which can release those
    /// fields with `deinit`. Do not call `deinit` for borrowed slices.
    prompt_state: PromptState = .unknown,
    working_directory: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    last_exit_code: ?u8 = null,
    has_selection: bool = false,

    pub fn deinit(self: *AISessionAwareness, alloc: std.mem.Allocator) void {
        if (self.working_directory) |value| alloc.free(value);
        if (self.last_command) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const AgentHandoff = struct {
    mode: AgentExecutionMode = .review_before_execute,
    awareness: AISessionAwareness = .{},
    objective: []const u8,

    pub fn init(
        mode: AgentExecutionMode,
        awareness: AISessionAwareness,
        objective: []const u8,
    ) AgentHandoff {
        return .{
            .mode = mode,
            .awareness = awareness,
            .objective = objective,
        };
    }
};

test "AgentHandoff: AgentExecutionMode enum contains expected values" {
    const review = @intFromEnum(AgentExecutionMode.review_before_execute);
    const trusted = @intFromEnum(AgentExecutionMode.auto_execute_trusted);

    try testing.expect(review != trusted);
}

test "AgentHandoff: AISessionAwareness.PromptState contains expected values" {
    const prompt_states = [_]AISessionAwareness.PromptState{
        .unknown,
        .at_prompt,
        .command_running,
        .password_input,
    };

    try testing.expectEqual(@as(usize, 4), prompt_states.len);
}

test "AgentHandoff: can be instantiated with awareness and objective" {
    const awareness = AISessionAwareness{
        .prompt_state = .at_prompt,
    };
    const handoff = AgentHandoff{
        .mode = .review_before_execute,
        .awareness = awareness,
        .objective = "inspect repository state",
    };

    try testing.expectEqual(AgentExecutionMode.review_before_execute, handoff.mode);
    try testing.expectEqual(AISessionAwareness.PromptState.at_prompt, handoff.awareness.prompt_state);
    try testing.expectEqualStrings("inspect repository state", handoff.objective);
}

test "AgentHandoff: init preserves fields exactly" {
    const awareness = AISessionAwareness{
        .prompt_state = .password_input,
        .working_directory = "/tmp/demo",
        .last_command = "sudo true",
        .last_exit_code = 1,
        .has_selection = true,
    };
    const handoff = AgentHandoff.init(
        .auto_execute_trusted,
        awareness,
        "retry install",
    );

    try testing.expectEqual(AgentExecutionMode.auto_execute_trusted, handoff.mode);
    try testing.expectEqualDeep(awareness, handoff.awareness);
    try testing.expectEqualStrings("retry install", handoff.objective);
}

test "AgentHandoff: AISessionAwareness.deinit releases owned strings" {
    var awareness = AISessionAwareness{
        .working_directory = try testing.allocator.dupe(u8, "/tmp/demo"),
        .last_command = try testing.allocator.dupe(u8, "git status"),
        .last_exit_code = 1,
        .has_selection = true,
    };

    awareness.deinit(testing.allocator);

    try testing.expectEqual(AISessionAwareness.PromptState.unknown, awareness.prompt_state);
    try testing.expectEqual(@as(?[]const u8, null), awareness.working_directory);
    try testing.expectEqual(@as(?[]const u8, null), awareness.last_command);
    try testing.expectEqual(@as(?u8, null), awareness.last_exit_code);
    try testing.expect(!awareness.has_selection);
}
