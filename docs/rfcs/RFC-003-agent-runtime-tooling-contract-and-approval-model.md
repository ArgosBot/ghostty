# RFC-003: Agent Runtime, Tooling Contract, and Approval Model
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | RFC-001, RFC-002, RFC-004            |
| Phase       | 2                                    |

---

## 1. Motivation

A chat-style assistant becomes meaningfully more useful when it can receive an explicit handoff, understand the current terminal session, and then propose, stage, and optionally execute structured terminal actions. That same capability also creates the largest safety risk in an AI-enabled terminal. This RFC defines a constrained agent runtime with structured tools, configurable approval gates, deterministic command proposals, ambient session awareness, and auditable execution state so Ghostty can support Warp-like agent workflows without sacrificing trust.

## 2. Agent Runtime Overview

This section defines the lifecycle of an agent session.

```text
┌──────────────┐ prompt ┌──────────────┐ tool call ┌──────────────────┐
│ Agent Session│ ─────▶ │ Model Turn   │ ────────▶ │ Approval Gate     │
└──────┬───────┘        └──────┬───────┘           └────────┬─────────┘
       │                        │ approved                    │ denied
       │                        ▼                             ▼
       │                 ┌──────────────┐              ┌──────────────┐
       └────────────────▶│ Tool Runtime │─────────────▶│ Agent Halted  │
                         └──────┬───────┘              └──────────────┘
                                │ result
                                ▼
                         ┌──────────────┐
                         │ Next Model   │
                         │ Turn         │
                         └──────────────┘
```

### 2.1 Scope

The initial agent runtime supports explicit handoff into shell workflows that remain bound to the active terminal surface and working directory. It supports both approval-gated execution and an optional trusted auto-execute mode controlled by RFC-002 policy. It does not permit arbitrary filesystem mutation, package installation, or background service management without explicit future tool definitions.

## 3. Shared Types and Protocols

This section defines the core agent contracts.

```zig
pub const AgentSessionID = u128;

pub const AgentToolName = enum {
    propose_command,
    run_approved_command,
    read_terminal_context,
    write_review_buffer,
    copy_to_clipboard,
};

pub const AgentToolCall = struct {
    id: []const u8,
    name: AgentToolName,
    payload_json: []const u8,
};

pub const ProposedCommand = struct {
    command_line: []const u8,
    working_directory: ?[]const u8,
    environment_overrides: []const EnvOverride,
    risk_level: RiskLevel,
    explanation: []const u8,

    pub const RiskLevel = enum {
        low,
        medium,
        high,
    };
};

pub const AgentExecutionMode = enum {
    review_before_execute,
    auto_execute_trusted,
};

pub const ApprovalDecision = enum {
    approve_once,
    approve_session,
    deny,
};

pub const PendingApproval = struct {
    session_id: AgentSessionID,
    tool_call: AgentToolCall,
    proposed_command: ?ProposedCommand,
    summary: []const u8,
};

pub const AgentHandoff = struct {
    mode: AgentExecutionMode,
    awareness: AISessionAwareness,
    objective: []const u8,
};

pub const AgentRuntime = struct {
    pub fn start(self: *AgentRuntime, request: AIRequest, handoff: AgentHandoff) !AgentSessionID;
    pub fn respondApproval(
        self: *AgentRuntime,
        approval: PendingApproval,
        decision: ApprovalDecision,
    ) !void;
};
```

### 3.1 Tool Contract

This section defines the strict structure required for model tool usage.

All agent tools use explicit JSON payload schemas validated before execution. Free-form tool names or arbitrary shell snippets emitted outside the `propose_command` contract are rejected locally and surfaced as tool errors back to the model.

## 4. Implementation Details

This section defines the implementation shape of the agent runtime.

### 4.1 New Files and Modules

| Path | Status | Purpose |
|------|--------|---------|
| `src/ai/agent/Runtime.zig` | [new file] | Orchestrates session turns, tool calls, and approvals |
| `src/ai/agent/ToolRegistry.zig` | [new file] | Static registry of allowed tools and payload validators |
| `src/ai/agent/ApprovalQueue.zig` | [new file] | Holds pending user decisions |
| `src/ai/agent/CommandProposal.zig` | [new file] | Command normalization, quoting checks, and risk classification |
| `src/ai/agent/SessionLog.zig` | [new file] | Structured, redacted session audit trail |

### 4.2 Existing Files to Modify

| Path | Purpose |
|------|---------|
| `src/termio/Exec.zig` | Accept approved command launches through an explicit safe entrypoint |
| `src/App.zig` | Add approval queue events and session lifecycle controls |
| `src/Surface.zig` | Bind session scope to the focused terminal surface |
| `src/apprt/action.zig` | Add approval and execution actions |
| `src/input/Binding.zig` | Add start-agent and approve/deny actions |

### 4.3 Handoff Modes and Approval Gates

This section defines how the user hands work off to the agent and when the user must intervene.

| Handoff Mode | Behavior | Intended Use |
|--------------|----------|--------------|
| `review_before_execute` | The agent can inspect context and propose commands, but every command execution is review-gated | Default production mode |
| `auto_execute_trusted` | The agent can execute low-risk and medium-risk commands without per-command approval when RFC-002 policy explicitly allows it | Trusted personal environments and power users |

| Tool | Approval Required | Notes |
|------|-------------------|-------|
| `read_terminal_context` | No, if RFC-002 policy already allows the requested scope | Read-only and bounded by context policy |
| `write_review_buffer` | No | Writes only to the local editable review buffer |
| `copy_to_clipboard` | Ask by default | Clipboard mutation is user-visible and can be sensitive |
| `propose_command` | No | Proposal generation is non-executing |
| `run_approved_command` | Always in `review_before_execute`; policy-driven in `auto_execute_trusted` | High-risk commands always require explicit approval |

### 4.4 Command Execution Rules

This section defines the execution constraints.

1. Every agent session begins with an explicit `AgentHandoff` that binds the agent to the current surface, working directory, and prompt state.
2. In `review_before_execute`, the model may only execute a command that was previously normalized into a `ProposedCommand` and displayed to the user.
3. In `auto_execute_trusted`, low-risk and medium-risk commands may execute without per-command approval only when policy explicitly allows the handoff mode for the active profile.
4. The user may edit any command before approval; edited commands become a new reviewed proposal.
5. Session approval does not bypass high-risk commands. Commands classified as `high` always require one-time confirmation.
6. No hidden environment overrides are allowed. Every override must be listed in the approval view.
7. Background execution is out of scope for the first implementation.

### 4.5 Risk Classification

This section defines the initial risk model.

| Signal | Risk Impact |
|--------|-------------|
| Contains shell metacharacter chaining (`&&`, `||`, `;`) | Upgrade to at least `medium` |
| Redirects to file (`>`, `>>`) | Upgrade to at least `medium` |
| Uses recursive deletion, system package management, privilege escalation, or network download execution | Upgrade to `high` |
| Leaves the current working directory or targets a different path than the handoff surface | Upgrade to at least `medium` |
| Targets current working directory only with a read-only command | Eligible for `low` |

## 5. User Experience

This section defines the handoff, review, and approval flows.

```text
┌──────────────────────────────────────────────────────────────┐
│ Hand off to Agent                                            │
│                                                              │
│ Objective: Fix the failing build in this repo                │
│ Surface: current tab                                         │
│ Working directory: /repo                                     │
│ Agent mode: Review Before Execute                            │
│                                                              │
│ [Start Agent] [Start in Auto Mode] [Cancel]                  │
└──────────────────────────────────────────────────────────────┘
```

```text
┌──────────────────────────────────────────────────────────────┐
│ AI wants to run a command                                   │
│                                                              │
│ Command: git status --short                                  │
│ Working directory: /repo                                     │
│ Risk: low                                                    │
│ Reason: Inspect modified files before proposing a patch      │
│                                                              │
│ [Edit Command] [Deny] [Approve Once] [Approve for Session]   │
└──────────────────────────────────────────────────────────────┘
```

The agent never writes directly into the terminal input buffer without user-visible review. The user can accept insertion without execution, execute once, deny, or explicitly hand work off in a trusted auto-execute mode when local policy allows it.

## 6. Error Handling

This section defines the primary agent failure scenarios.

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Model emits an unsupported tool name | Tool registry validation fails | Return structured tool error to the model and keep the session alive |
| Tool payload is malformed JSON | Schema validation fails before execution | Reject the call, log sanitized diagnostics, and prompt the model to retry |
| User denies an approval | Approval queue records denial | Halt the requested action and continue or terminate the session based on policy |
| Approved command exits with non-zero status | PTY execution reports failure | Return exit code and bounded stderr/output summary to the agent |
| Session loses its bound surface | Surface close or detach event invalidates session scope | Halt the session and offer to reopen in a new surface |
| Agent exceeds turn budget | Session turn counter crosses configured maximum | Stop the session and preserve the transcript in the review buffer |

## 7. Security Considerations

This section defines the safety requirements for agent execution.

The model is not a trusted executor. Tool names, payloads, working directories, and environment overrides are all untrusted inputs until validated locally. Commands are displayed exactly as executed, without hidden wrappers beyond Ghostty’s normal subprocess launch path. Approval logs must redact terminal content while preserving timestamps, tool names, and final decisions for auditability.

## 8. Testing Strategy

This section defines the minimum coverage for the agent runtime.

| Test Area | Command | Expected Scope |
|-----------|---------|----------------|
| Tool schema validation | `zig build test -Dtest-filter=agent-tool` | Malformed payloads and unknown tools |
| Risk classifier | `zig build test -Dtest-filter=command-risk` | High-risk and low-risk command classification |
| Approval queue | `zig build test -Dtest-filter=approval` | Session, once, and denial semantics |
| PTY integration | `zig build test -Dtest-filter=agent-exec` | Approved execution path and result mapping |

## 9. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| Let the model emit arbitrary shell commands directly into the PTY | It would remove structure, eliminate auditability, and make approvals unreliable. |
| Allow session-wide auto-execution after one approval | It would create a trust cliff that is too steep for a terminal product. |
| Delay all tooling support until after full chat UI ships | It would postpone the core value of agent workflows and force a later redesign of the runtime. |

## 10. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Must the product support explicit handoff into an executing agent in the current terminal session? | **Yes.** Agent sessions start from a structured handoff bound to the active surface and working directory. |
| 2 | Is the first execution model approval-only or does it support optional auto mode? | **Both.** `review_before_execute` is the default, and `auto_execute_trusted` exists only behind explicit policy opt-in. |
| 3 | Can session approval bypass all future prompts? | **No.** High-risk commands always require one-time confirmation. |
| 4 | What is the source of truth for tool safety? | **Local validation and policy gates inside Ghostty.** Model intent alone never authorizes execution. |
