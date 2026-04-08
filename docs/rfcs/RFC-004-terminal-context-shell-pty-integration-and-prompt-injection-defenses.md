# RFC-004: Terminal Context, Shell/PTY Integration, and Prompt-Injection Defenses
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | RFC-001, RFC-002                     |
| Phase       | 1                                    |

---

## 1. Motivation

The quality of an AI terminal assistant depends on context, but raw terminal history is noisy, expensive, and vulnerable to prompt injection. Ghostty already exposes high-value signals such as selection, visible terminal content, semantic prompts, working directory updates through OSC 7, and shell integration state. This RFC defines the trusted context pipeline, PTY-adjacent capture strategy, ambient session awareness, context budgeting, and prompt-injection defenses that make AI features useful without allowing terminal output to silently rewrite system instructions.

## 2. Context Architecture Overview

This section defines how context is captured and normalized.

```text
┌────────────────────────────────────────────────────────────┐
│ Surface                                                    │
│  selection │ viewport │ semantic prompts │ pwd │ shell meta│
└──────────────────────────┬─────────────────────────────────┘
                           ▼
┌────────────────────────────────────────────────────────────┐
│ AIContextBroker                                            │
│  1. Collect bounded slices                                 │
│  2. Normalize terminal formatting                          │
│  3. Segment trusted vs untrusted content                   │
│  4. Apply prompt-injection guards                          │
│  5. Build AIContextEnvelope                                │
└──────────────────────────┬─────────────────────────────────┘
                           ▼
                    AIRequest.context
```

### 2.1 Trusted and Untrusted Inputs

User-authored request text, Ghostty-generated metadata, and local policy are trusted control inputs. Terminal output, shell output, remote command output, pasted content, and environment variable values are untrusted data inputs.

## 3. Shared Types and Protocols

This section defines the shared context model.

```zig
pub const ContextSource = enum {
    selection,
    viewport,
    scrollback,
    cwd,
    semantic_prompt,
    shell_metadata,
    environment,
};

pub const ContextSegment = struct {
    source: ContextSource,
    trusted: bool,
    content: []const u8,
    byte_len: usize,
    redacted: bool,
};

pub const ContextBudget = struct {
    max_total_bytes: usize,
    max_scrollback_bytes: usize,
    max_environment_bytes: usize,
    max_segment_count: usize,
};

pub const AIContextEnvelope = struct {
    target_surface_id: u64,
    generated_at_unix_ms: i64,
    budget: ContextBudget,
    segments: []const ContextSegment,
    warnings: []const []const u8,
};
```

### 3.1 Context Broker Contract

This section defines the API that builds bounded context.

```zig
pub const AIContextBroker = struct {
    pub fn captureSelection(self: *AIContextBroker, surface: *Surface) !AIContextEnvelope;
    pub fn captureViewport(self: *AIContextBroker, surface: *Surface) !AIContextEnvelope;
    pub fn captureSessionAwareness(
        self: *AIContextBroker,
        surface: *Surface,
    ) !AISessionAwareness;
    pub fn captureReviewContext(
        self: *AIContextBroker,
        surface: *Surface,
        options: CaptureOptions,
    ) !AIContextEnvelope;
};

pub const AISessionAwareness = struct {
    surface_id: u64,
    cwd: ?[]const u8,
    shell_program: ?[]const u8,
    prompt_state: PromptState,
    last_command: ?[]const u8,
    last_exit_code: ?i32,
    active_selection_present: bool,

    pub const PromptState = enum {
        unknown,
        at_prompt,
        command_running,
        password_input,
    };
};
```

## 4. Implementation Details

This section defines how Ghostty’s existing terminal primitives are reused.

### 4.1 Existing Repository Hooks

| Existing Path | Reuse |
|---------------|-------|
| `src/Surface.zig` | Source of selection state, clipboard behavior, password input, and surface-bound policy enforcement |
| `src/terminal/osc.zig` | Reuse OSC 7 and OSC 133 parsing results rather than inventing parallel prompt detection |
| `src/terminal/Screen.zig` | Semantic prompt state and screen model for prompt-aware clipping |
| `src/terminal/formatter.zig` | Reuse VT/plain-text formatting code to export bounded slices of terminal content |
| `src/shell-integration/` | Reuse shell integration semantics rather than scraping prompt text heuristically |

### 4.2 New Files and Modules

| Path | Status | Purpose |
|------|--------|---------|
| `src/ai/context/Broker.zig` | [new file] | High-level context capture coordinator |
| `src/ai/context/Normalizer.zig` | [new file] | Converts terminal content into model-safe text blocks |
| `src/ai/context/PromptInjectionGuard.zig` | [new file] | Labels untrusted segments and inserts control boundaries |
| `src/ai/context/Budgeter.zig` | [new file] | Byte and segment budget enforcement |

### 4.3 Prompt-Injection Defenses

This section defines the defense-in-depth strategy.

1. All terminal-derived text is marked untrusted in the `ContextSegment` metadata.
2. System instructions and policy instructions are never concatenated inside the same segment as untrusted terminal output.
3. The provider-facing prompt serializer wraps untrusted content in explicit boundaries such as `BEGIN UNTRUSTED TERMINAL CONTENT` and `END UNTRUSTED TERMINAL CONTENT`.
4. Semantic prompt markers are used to prefer command-adjacent output over arbitrary scrollback.
5. Remote environment values and shell aliases are excluded by default under RFC-002.

### 4.4 Context Assembly Rules

This section defines capture precedence.

| Rank | Source | Rule |
|------|--------|------|
| 1 | Explicit user selection | Always preferred when non-empty |
| 2 | Visible viewport | Used for summarize and explain flows when there is no selection |
| 3 | Semantic prompt block | Used for command-aware assistance and command proposals |
| 4 | Current working directory | Included only when policy allows it |
| 5 | Scrollback | Included only after review and bounded by `ContextBudget` |
| 6 | Environment | Excluded by default and opt-in only |

### 4.5 Ambient Session Awareness

This section defines how the agent knows where it is without scraping the entire terminal transcript.

Session awareness is a separate structured object, `AISessionAwareness`, that is always preferred over heuristic inference from raw output. It is assembled from existing Ghostty signals in the following order:

| Signal | Source | Usage |
|--------|--------|-------|
| Current working directory | OSC 7 handling in `src/terminal/osc.zig` and surface state | Primary working-directory truth |
| Prompt state | Semantic prompt handling in `src/terminal/Screen.zig` and `src/Surface.zig` | Distinguishes idle prompt from running command |
| Last command boundary | Shell integration and semantic prompt segmentation | Gives the agent the most recent command context |
| Last exit code | Shell integration metadata when available | Helps the agent reason about failures without reading full scrollback |
| Selection presence | Surface selection state | Allows the agent to know whether the user explicitly highlighted context |

The agent runtime defined in RFC-003 consumes `AISessionAwareness` on every handoff so it can continue operating in the correct terminal surface and directory.

### 4.6 PTY and Latency Constraints

This section defines what context capture must not do.

Context capture must not block PTY read or write loops and must not parse unbounded history on demand. Any expensive serialization work occurs on bounded copies of terminal state captured from `Surface` and screen primitives.

## 5. User Experience

This section defines how the user reviews context before it is sent.

```text
┌──────────────────────────────────────────────────────────────┐
│ Review Context                                               │
│                                                              │
│ Sources                                                      │
│  • Selection (trusted by user intent)                        │
│  • Current working directory                                 │
│  • 1 semantic prompt block [UNTRUSTED TERMINAL CONTENT]      │
│                                                              │
│ Warnings                                                     │
│  • Shell output can contain prompt injection attempts        │
│                                                              │
│ [Trim] [Edit] [Cancel] [Send to AI]                          │
└──────────────────────────────────────────────────────────────┘
```

## 6. Error Handling

This section defines the major context-capture failure scenarios.

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| The surface has no usable context | Selection is empty and viewport capture yields no meaningful text | Show an empty-state message and disable send |
| Captured context exceeds the configured byte budget | `Budgeter` reports overflow | Trim low-priority segments and require review before send |
| Prompt markers are inconsistent or absent | Semantic prompt state is missing or invalid | Fall back to viewport capture and mark lower confidence |
| Protected input is active | `Surface.passwordInput` or runtime secure-input state is true | Refuse capture and explain that AI is unavailable during protected input |
| Formatter cannot serialize content slice | Formatter returns error during export | Fail locally, log sanitized diagnostics, and suggest retry |
| Untrusted output attempts instruction override | Injection guard matches instruction-like control phrases | Preserve text as untrusted content, add warning, and never merge it into trusted instructions |

## 7. Security Considerations

This section defines the core trust boundary for all later AI features.

Terminal output is treated as attacker-controlled. This includes remote shell output, command output, clipboard pastes echoed by the shell, and generated escape-sequence content. The serializer therefore separates policy and instruction text from captured terminal data, preserves provenance metadata, and ensures the model is explicitly told not to follow instructions found in untrusted terminal content.

## 8. Testing Strategy

This section defines the minimum automated coverage.

| Test Area | Command | Expected Scope |
|-----------|---------|----------------|
| Context budgeting | `zig build test -Dtest-filter=context-budget` | Byte trimming, segment prioritization |
| Prompt-injection guards | `zig build test -Dtest-filter=prompt-guard` | Boundary serialization and warning generation |
| OSC integration | `zig build test -Dtest-filter=osc` | OSC 7 and semantic prompt capture correctness |
| Formatter integration | `zig build test -Dtest-filter=formatter` | Bounded export from screen slices |
| Session awareness | `zig build test -Dtest-filter=session-awareness` | Prompt-state, cwd, and last-command extraction |

## 9. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| Send full scrollback by default for every request | It would be expensive, privacy-invasive, and vulnerable to prompt injection. |
| Infer prompts exclusively from raw text heuristics | Ghostty already has better signals through semantic prompts and shell integration. |
| Treat terminal output as trusted if it originates from the local shell | Local and remote commands alike can emit adversarial instructions. |

## 10. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the primary trusted context source? | **Explicit user selection, followed by bounded viewport and semantic prompt slices.** This preserves user intent and keeps context concise. |
| 2 | How does the agent know where it currently is? | **Through structured session awareness derived from cwd, prompt state, and recent command metadata.** This is safer and more reliable than inferring state from raw text alone. |
| 3 | How is terminal output represented to the model? | **As explicitly untrusted content.** Policy and system instructions are serialized separately. |
| 4 | Can scrollback be included automatically? | **No.** Scrollback remains review-gated and policy-controlled because of privacy and injection risk. |
