const std = @import("std");
const testing = std.testing;
const ai = @import("../types.zig");

pub const RawSessionState = struct {
    pub const PromptTracking = enum {
        unknown,
        semantic,
    };

    prompt_tracking: PromptTracking = .unknown,
    at_prompt: bool = false,
    password_input: bool = false,
    working_directory: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    last_exit_code: ?u8 = null,
    has_selection: bool = false,
};

pub fn buildSessionAwareness(raw: RawSessionState) ai.AISessionAwareness {
    return .{
        .prompt_state = if (raw.password_input)
            .password_input
        else switch (raw.prompt_tracking) {
            // Stay conservative when prompt tracking is unavailable: a true
            // cursor-at-prompt signal alone is not strong enough to prove the
            // shell is idle, so we preserve `.unknown`.
            .unknown => .unknown,
            .semantic => if (raw.at_prompt) .at_prompt else .command_running,
        },
        .working_directory = raw.working_directory,
        .last_command = raw.last_command,
        .last_exit_code = raw.last_exit_code,
        .has_selection = raw.has_selection,
    };
}

test "session-awareness: build maps idle prompt state and preserves fields" {
    const awareness = buildSessionAwareness(.{
        .prompt_tracking = .semantic,
        .password_input = false,
        .at_prompt = true,
        .working_directory = "/tmp/project",
        .last_command = "git status",
        .last_exit_code = 0,
        .has_selection = true,
    });

    try testing.expectEqual(ai.AISessionAwareness.PromptState.at_prompt, awareness.prompt_state);
    try testing.expectEqualStrings("/tmp/project", awareness.working_directory.?);
    try testing.expectEqualStrings("git status", awareness.last_command.?);
    try testing.expectEqual(@as(?u8, 0), awareness.last_exit_code);
    try testing.expect(awareness.has_selection);
}

test "session-awareness: build maps running command when semantic prompt tracking is active" {
    const awareness = buildSessionAwareness(.{
        .prompt_tracking = .semantic,
        .password_input = false,
        .at_prompt = false,
    });

    try testing.expectEqual(ai.AISessionAwareness.PromptState.command_running, awareness.prompt_state);
    try testing.expectEqual(@as(?[]const u8, null), awareness.working_directory);
    try testing.expectEqual(@as(?[]const u8, null), awareness.last_command);
    try testing.expectEqual(@as(?u8, null), awareness.last_exit_code);
    try testing.expect(!awareness.has_selection);
}

test "session-awareness: build prioritizes password input over prompt detection" {
    const awareness = buildSessionAwareness(.{
        .prompt_tracking = .semantic,
        .password_input = true,
        .at_prompt = true,
    });

    try testing.expectEqual(ai.AISessionAwareness.PromptState.password_input, awareness.prompt_state);
}

test "session-awareness: build returns unknown when prompt tracking is unavailable" {
    const awareness = buildSessionAwareness(.{
        .prompt_tracking = .unknown,
        .at_prompt = false,
    });

    try testing.expectEqual(ai.AISessionAwareness.PromptState.unknown, awareness.prompt_state);
}

test "session-awareness: build stays conservative without prompt tracking even when cursor is at prompt" {
    const awareness = buildSessionAwareness(.{
        .prompt_tracking = .unknown,
        .at_prompt = true,
    });

    try testing.expectEqual(ai.AISessionAwareness.PromptState.unknown, awareness.prompt_state);
}
