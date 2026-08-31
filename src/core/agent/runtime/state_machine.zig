const std = @import("std");

pub const Generation = u64;

pub const Outcome = enum {
    completed,
    failed,
    cancelled,
    paused,
};

pub const Active = struct {
    generation: Generation,
};

pub const ToolBatch = struct {
    generation: Generation,
    count: u32,
};

pub const Terminal = struct {
    generation: Generation,
    outcome: Outcome,
};

pub const Phase = union(enum) {
    idle,
    model: Active,
    tools: ToolBatch,
    cancelling: Active,
    terminal: Terminal,
    closed,
};

pub const State = struct {
    phase: Phase = .idle,
    last_generation: Generation = 0,
};

pub const Event = union(enum) {
    begin_prompt: Generation,
    model_yielded_tools: ToolBatch,
    tools_settled: Generation,
    complete: Terminal,
    acknowledge: Generation,
    cancel,
    close,
};

pub const StaleReason = enum {
    generation_mismatch,
    generation_reused,
    phase_mismatch,
};

pub const InvalidReason = enum {
    zero_generation,
    empty_tool_batch,
    non_cancelled_completion_after_cancel,
};

/// Effects are represented as values. The caller performs them only after it
/// installs the returned state.
pub const Action = union(enum) {
    none,
    start_model: Generation,
    start_tools: ToolBatch,
    resume_model: Generation,
    cancel_active: Generation,
    publish_result: Terminal,
    close,
    cancel_and_close: Generation,
    reject_busy: Generation,
    stale: StaleReason,
    invalid: InvalidReason,
};

pub const Decision = struct {
    state: State,
    action: Action,
};

pub fn decide(state: State, event: Event) Decision {
    return switch (event) {
        .begin_prompt => |generation| beginPrompt(state, generation),
        .model_yielded_tools => |batch| modelYieldedTools(state, batch),
        .tools_settled => |generation| toolsSettled(state, generation),
        .complete => |terminal| complete(state, terminal),
        .acknowledge => |generation| acknowledge(state, generation),
        .cancel => cancel(state),
        .close => close(state),
    };
}

pub fn isBusy(state: State) bool {
    return switch (state.phase) {
        .model, .tools, .cancelling => true,
        .idle, .terminal, .closed => false,
    };
}

pub fn activeGeneration(state: State) ?Generation {
    return switch (state.phase) {
        .model, .cancelling => |active| active.generation,
        .tools => |batch| batch.generation,
        .terminal => |terminal| terminal.generation,
        .idle, .closed => null,
    };
}

fn beginPrompt(state: State, generation: Generation) Decision {
    if (generation == 0) return invalid(state, .zero_generation);
    if (generation <= state.last_generation) {
        return stale(state, .generation_reused);
    }
    return switch (state.phase) {
        .idle => .{
            .state = .{
                .phase = .{ .model = .{ .generation = generation } },
                .last_generation = generation,
            },
            .action = .{ .start_model = generation },
        },
        .model, .tools, .cancelling, .terminal => .{
            .state = state,
            .action = .{ .reject_busy = generation },
        },
        .closed => stale(state, .phase_mismatch),
    };
}

fn modelYieldedTools(state: State, batch: ToolBatch) Decision {
    if (batch.generation == 0) return invalid(state, .zero_generation);
    if (batch.count == 0) return invalid(state, .empty_tool_batch);
    return switch (state.phase) {
        .model => |active| if (active.generation == batch.generation)
            .{
                .state = .{
                    .phase = .{ .tools = batch },
                    .last_generation = state.last_generation,
                },
                .action = .{ .start_tools = batch },
            }
        else
            stale(state, .generation_mismatch),
        .idle, .tools, .cancelling, .terminal, .closed => stale(
            state,
            if (activeGeneration(state)) |generation|
                if (generation == batch.generation) .phase_mismatch else .generation_mismatch
            else
                .phase_mismatch,
        ),
    };
}

fn toolsSettled(state: State, generation: Generation) Decision {
    if (generation == 0) return invalid(state, .zero_generation);
    return switch (state.phase) {
        .tools => |batch| if (batch.generation == generation)
            .{
                .state = .{
                    .phase = .{ .model = .{ .generation = generation } },
                    .last_generation = state.last_generation,
                },
                .action = .{ .resume_model = generation },
            }
        else
            stale(state, .generation_mismatch),
        .idle, .model, .cancelling, .terminal, .closed => stale(
            state,
            if (activeGeneration(state)) |active|
                if (active == generation) .phase_mismatch else .generation_mismatch
            else
                .phase_mismatch,
        ),
    };
}

fn complete(state: State, terminal: Terminal) Decision {
    if (terminal.generation == 0) return invalid(state, .zero_generation);
    const active = activeGeneration(state) orelse return stale(state, .phase_mismatch);
    if (active != terminal.generation) return stale(state, .generation_mismatch);
    switch (state.phase) {
        .model, .tools => {},
        .cancelling => if (terminal.outcome != .cancelled) {
            return invalid(state, .non_cancelled_completion_after_cancel);
        },
        .idle, .terminal, .closed => return stale(state, .phase_mismatch),
    }
    return .{
        .state = .{
            .phase = .{ .terminal = terminal },
            .last_generation = state.last_generation,
        },
        .action = .{ .publish_result = terminal },
    };
}

fn acknowledge(state: State, generation: Generation) Decision {
    if (generation == 0) return invalid(state, .zero_generation);
    return switch (state.phase) {
        .terminal => |terminal| if (terminal.generation == generation)
            .{
                .state = .{
                    .phase = .idle,
                    .last_generation = state.last_generation,
                },
                .action = .none,
            }
        else
            stale(state, .generation_mismatch),
        .idle, .model, .tools, .cancelling, .closed => stale(state, .phase_mismatch),
    };
}

fn cancel(state: State) Decision {
    return switch (state.phase) {
        .model => |active| .{
            .state = .{
                .phase = .{ .cancelling = active },
                .last_generation = state.last_generation,
            },
            .action = .{ .cancel_active = active.generation },
        },
        .tools => |batch| .{
            .state = .{
                .phase = .{ .cancelling = .{ .generation = batch.generation } },
                .last_generation = state.last_generation,
            },
            .action = .{ .cancel_active = batch.generation },
        },
        .idle, .cancelling, .terminal, .closed => .{ .state = state, .action = .none },
    };
}

fn close(state: State) Decision {
    return switch (state.phase) {
        .closed => .{ .state = state, .action = .none },
        .model => |active| .{
            .state = .{ .phase = .closed, .last_generation = state.last_generation },
            .action = .{ .cancel_and_close = active.generation },
        },
        .tools => |batch| .{
            .state = .{ .phase = .closed, .last_generation = state.last_generation },
            .action = .{ .cancel_and_close = batch.generation },
        },
        .cancelling => |active| .{
            .state = .{ .phase = .closed, .last_generation = state.last_generation },
            .action = .{ .cancel_and_close = active.generation },
        },
        .idle, .terminal => .{
            .state = .{ .phase = .closed, .last_generation = state.last_generation },
            .action = .close,
        },
    };
}

fn stale(state: State, reason: StaleReason) Decision {
    return .{ .state = state, .action = .{ .stale = reason } };
}

fn invalid(state: State, reason: InvalidReason) Decision {
    return .{ .state = state, .action = .{ .invalid = reason } };
}

fn expectDecision(expected: Decision, actual: Decision) !void {
    try std.testing.expectEqualDeep(expected, actual);
}

test "agent lifecycle completes a model-only prompt and preserves generation" {
    const started = decide(.{}, .{ .begin_prompt = 1 });
    try expectDecision(.{
        .state = .{
            .phase = .{ .model = .{ .generation = 1 } },
            .last_generation = 1,
        },
        .action = .{ .start_model = 1 },
    }, started);
    try std.testing.expect(isBusy(started.state));

    const finished = decide(started.state, .{ .complete = .{
        .generation = 1,
        .outcome = .completed,
    } });
    try expectDecision(.{
        .state = .{
            .phase = .{ .terminal = .{ .generation = 1, .outcome = .completed } },
            .last_generation = 1,
        },
        .action = .{ .publish_result = .{ .generation = 1, .outcome = .completed } },
    }, finished);

    const acknowledged = decide(finished.state, .{ .acknowledge = 1 });
    try expectDecision(.{
        .state = .{ .phase = .idle, .last_generation = 1 },
        .action = .none,
    }, acknowledged);
}

test "agent lifecycle sequences tools before the next model step" {
    const started = decide(.{}, .{ .begin_prompt = 4 });
    const tools = decide(started.state, .{ .model_yielded_tools = .{
        .generation = 4,
        .count = 2,
    } });
    try expectDecision(.{
        .state = .{
            .phase = .{ .tools = .{ .generation = 4, .count = 2 } },
            .last_generation = 4,
        },
        .action = .{ .start_tools = .{ .generation = 4, .count = 2 } },
    }, tools);

    const resumed = decide(tools.state, .{ .tools_settled = 4 });
    try expectDecision(.{
        .state = .{
            .phase = .{ .model = .{ .generation = 4 } },
            .last_generation = 4,
        },
        .action = .{ .resume_model = 4 },
    }, resumed);
}

test "agent lifecycle rejects concurrent and reused prompts without mutation" {
    const started = decide(.{}, .{ .begin_prompt = 8 });
    try expectDecision(.{
        .state = started.state,
        .action = .{ .reject_busy = 9 },
    }, decide(started.state, .{ .begin_prompt = 9 }));

    const finished = decide(started.state, .{ .complete = .{
        .generation = 8,
        .outcome = .completed,
    } });
    const idle = decide(finished.state, .{ .acknowledge = 8 });
    try expectDecision(.{
        .state = idle.state,
        .action = .{ .stale = .generation_reused },
    }, decide(idle.state, .{ .begin_prompt = 8 }));
}

test "agent lifecycle makes cancellation absorbing for successful completion" {
    const started = decide(.{}, .{ .begin_prompt = 12 });
    const cancelling = decide(started.state, .cancel);
    try expectDecision(.{
        .state = .{
            .phase = .{ .cancelling = .{ .generation = 12 } },
            .last_generation = 12,
        },
        .action = .{ .cancel_active = 12 },
    }, cancelling);

    try expectDecision(.{
        .state = cancelling.state,
        .action = .{ .invalid = .non_cancelled_completion_after_cancel },
    }, decide(cancelling.state, .{ .complete = .{
        .generation = 12,
        .outcome = .completed,
    } }));

    const cancelled = decide(cancelling.state, .{ .complete = .{
        .generation = 12,
        .outcome = .cancelled,
    } });
    try std.testing.expectEqualDeep(
        Phase{ .terminal = .{ .generation = 12, .outcome = .cancelled } },
        cancelled.state.phase,
    );
}

test "agent lifecycle keeps stale results and duplicate close inert" {
    const started = decide(.{}, .{ .begin_prompt = 20 });
    try expectDecision(.{
        .state = started.state,
        .action = .{ .stale = .generation_mismatch },
    }, decide(started.state, .{ .model_yielded_tools = .{
        .generation = 19,
        .count = 1,
    } }));

    const closed = decide(started.state, .close);
    try expectDecision(.{
        .state = .{ .phase = .closed, .last_generation = 20 },
        .action = .{ .cancel_and_close = 20 },
    }, closed);
    try expectDecision(.{ .state = closed.state, .action = .none }, decide(closed.state, .close));
    try expectDecision(.{
        .state = closed.state,
        .action = .{ .stale = .phase_mismatch },
    }, decide(closed.state, .{ .begin_prompt = 21 }));
}

test "agent lifecycle rejects invalid inputs without publishing state" {
    const state = State{};
    try expectDecision(.{
        .state = state,
        .action = .{ .invalid = .zero_generation },
    }, decide(state, .{ .begin_prompt = 0 }));

    const started = decide(state, .{ .begin_prompt = 1 });
    try expectDecision(.{
        .state = started.state,
        .action = .{ .invalid = .empty_tool_batch },
    }, decide(started.state, .{ .model_yielded_tools = .{
        .generation = 1,
        .count = 0,
    } }));
}
