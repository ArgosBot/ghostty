# RFC-001: AI Platform Core and Provider Abstraction
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | —                                    |
| Phase       | 1                                    |

---

## 1. Motivation

Ghostty already has strong shared application and surface abstractions, but it has no shared runtime for model requests, streaming responses, or long-lived AI jobs. Implementing AI separately inside each runtime would create platform drift, inconsistent policy enforcement, and expensive future migrations. This RFC defines the shared AI platform layer, provider abstraction, OpenRouter-first transport, and action plumbing that every later AI feature will build on.

## 2. Platform Overview

This section defines the shared execution model and the boundary between the Zig core and native runtimes.

```text
┌──────────────────────────────────────────────────────────────────────┐
│                         Ghostty Shared Core                         │
├──────────────────────────────────────────────────────────────────────┤
│ AIPlatform                                                          │
│  ├── AIJobRegistry                                                  │
│  ├── AIProviderRegistry                                             │
│  ├── AIContextBroker                                                │
│  ├── AIStreamMux                                                    │
│  └── AIPolicyGate                                                   │
└───────────────┬──────────────────────────────────────────────────────┘
                │ app/surface actions
     ┌──────────┴──────────┐
     │                     │
┌────▼─────┐         ┌─────▼─────┐
│ macOS UI │         │ GTK UI    │
│ Swift    │         │ Zig/GTK   │
└────┬─────┘         └─────┬─────┘
     │                     │
     └──────────┬──────────┘
                │ provider requests
         ┌──────▼──────┐
         │ OpenRouter  │
         │ HTTP/SSE    │
         └─────────────┘
```

### 2.1 Architectural Boundaries

The shared AI runtime lives in Zig under `src/ai/` and owns request orchestration, provider selection, streaming, cancellation, and job state. Native runtimes own presentation, focus management, and platform-specific credential accessors.

### 2.2 Non-Goals

This RFC does not define agent tooling, command execution, or UI design beyond the minimum action hooks needed to expose jobs to runtimes. Those concerns are defined in RFC-003 and RFC-005.

## 3. Shared Types and Protocols

This section defines the canonical shared types for the AI platform.

```zig
pub const AIJobID = u128;

pub const AIRequestTarget = union(enum) {
    app,
    surface: *Surface,
};

pub const AIMessageRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const AIMessage = struct {
    role: AIMessageRole,
    content: []const u8,
};

pub const AIModelRef = struct {
    provider_id: []const u8,
    model_id: []const u8,
};

pub const AIRequest = struct {
    id: AIJobID,
    target: AIRequestTarget,
    model: AIModelRef,
    messages: []const AIMessage,
    context: AIContextEnvelope,
    mode: Mode,
    stream: bool,

    pub const Mode = enum {
        assistant,
        summarize,
        explain,
        propose,
        agent,
    };
};

pub const AIStreamEvent = union(enum) {
    started,
    delta: []const u8,
    tool_call: AIToolCall,
    completed: AIResponse,
    failed: AIPlatformError,
    cancelled,
};

pub const AIResponse = struct {
    text: []const u8,
    finish_reason: FinishReason,
    usage: TokenUsage,

    pub const FinishReason = enum {
        stop,
        length,
        tool_call,
        content_filter,
        provider_error,
    };
};

pub const TokenUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub const AIProvider = struct {
    id: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (*const AIProvider) ProviderCapabilities,
        start: *const fn (*AIProviderSession, AIRequest, *AIEventSink) anyerror!void,
        cancel: *const fn (*AIProviderSession, AIJobID) void,
    };
};
```

### 3.1 Error Model

This section defines the shared error model used across provider transports and job orchestration.

```zig
pub const AIPlatformError = error{
    ProviderNotFound,
    ProviderUnavailable,
    AuthenticationRequired,
    RequestRejectedByPolicy,
    RequestTooLarge,
    TransportFailed,
    StreamProtocolInvalid,
    Cancelled,
    UnsupportedModel,
    RateLimited,
};
```

### 3.2 OpenRouter Transport Types

This section defines the provider-specific objects needed for OpenRouter-first support.

```zig
pub const OpenRouterProviderConfig = struct {
    base_url: []const u8,
    default_model: []const u8,
    app_name_header: []const u8,
    app_url_header: ?[]const u8,
    enable_reasoning_summaries: bool,
};

pub const ProviderCapabilities = struct {
    supports_streaming: bool,
    supports_tools: bool,
    supports_reasoning_controls: bool,
    supports_images: bool,
};
```

## 4. Implementation Details

This section defines how the shared runtime integrates with the existing Ghostty architecture.

### 4.1 New Files and Modules

The platform is implemented as the following new files.

| Path | Status | Purpose |
|------|--------|---------|
| `src/ai/Platform.zig` | [new file] | Root coordinator for job submission, cancellation, and action routing |
| `src/ai/JobRegistry.zig` | [new file] | In-memory lifecycle registry keyed by `AIJobID` |
| `src/ai/ProviderRegistry.zig` | [new file] | Runtime provider lookup and capability exposure |
| `src/ai/provider/OpenRouter.zig` | [new file] | OpenRouter HTTP and server-sent event transport |
| `src/ai/StreamMux.zig` | [new file] | Stream fan-out into UI-safe app/surface messages |
| `src/ai/types.zig` | [new file] | Shared request, response, event, and error types |

### 4.2 Existing Files to Modify

The following existing files require changes.

| Path | Purpose |
|------|---------|
| `src/App.zig` | Add AI job submission, cancellation, and app-scoped notifications |
| `src/Surface.zig` | Add surface-scoped AI entrypoints and result delivery hooks |
| `src/apprt/action.zig` | Add ABI-safe AI actions for runtimes |
| `src/input/Binding.zig` | Add new assistant-related actions addressable by keybindings and command palette entries |
| `src/input/command.zig` | Add human-readable command names for AI actions |
| `build.zig` | Register new shared modules and tests |

### 4.3 Action Plumbing

This section defines the new shared actions exposed through the runtime ABI.

```zig
pub const AIAction = union(enum) {
    open_panel,
    close_panel,
    explain_selection,
    summarize_viewport,
    propose_command,
    retry_last,
    cancel_job: AIJobID,
};
```

Runtime-specific code must translate these actions into native UI events without performing provider calls directly. `src/apprt/action.zig` remains the only ABI boundary for these user actions.

### 4.4 Job Lifecycle

This section defines the job state machine.

```text
┌─────────┐ submit ┌───────────┐ first byte ┌───────────┐ complete ┌──────────┐
│ queued  │ ─────▶ │ starting  │ ─────────▶ │ streaming │ ───────▶ │ done     │
└────┬────┘        └────┬──────┘            └────┬──────┘          └──────────┘
     │ reject/policy     │ transport error        │ cancel/error
     ▼                   ▼                        ▼
┌──────────┐       ┌──────────┐             ┌──────────┐
│ rejected │       │ failed   │             │ cancelled│
└──────────┘       └──────────┘             └──────────┘
```

Every transition emits an `AIStreamEvent` so the native runtime can render deterministic UI state.

### 4.5 OpenRouter Request Mapping

This section defines the initial provider transport behavior.

| OpenRouter Concern | Ghostty Behavior |
|--------------------|------------------|
| API endpoint | Use configurable `base_url`, defaulting to `https://openrouter.ai/api/v1` |
| Auth | Bearer token provided by RFC-002 secret resolution |
| Streaming | Use server-sent events and emit `AIStreamEvent.delta` chunks |
| Model selection | Prefer explicit request model, otherwise fallback to provider default |
| Headers | Send app identification headers configured by the fork |
| Tool support | Advertise only capabilities implemented by RFC-003 |
| Retries | Retry idempotent transport failures with bounded backoff; never retry after first streamed delta |

### 4.6 Threading and Performance

This section defines concurrency requirements.

Provider network I/O must execute outside the UI thread, render thread, and PTY read/write paths. The implementation uses dedicated worker threads or async executors owned by the AI platform and returns results through app or surface mailbox messages.

## 5. Configuration

This section defines the core configuration surface introduced by the platform layer.

| Key | Default | Description |
|-----|---------|-------------|
| `ai-enabled` | `false` | Global enable switch for all AI features |
| `ai-provider` | `openrouter` | Provider identifier resolved through `ProviderRegistry` |
| `ai-model` | `openrouter/auto` | Default model used when the request does not override it |
| `ai-endpoint` | `https://openrouter.ai/api/v1` | Base API URL |
| `ai-streaming` | `true` | Enables streaming responses when supported |
| `ai-max-concurrent-jobs` | `4` | Per-process concurrency ceiling |

These keys are defined in `src/config/Config.zig` and documented via existing docs generation under `src/build/webgen/`.

## 6. Error Handling

This section defines the runtime-visible failure scenarios for the platform.

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| No provider matches `ai-provider` | Registry lookup fails before request dispatch | Show provider configuration error and keep the review buffer intact |
| OpenRouter returns 401 or 403 | HTTP status mapping during request start | Prompt for credential repair through RFC-002 secret flows |
| Request exceeds configured context budget | Request assembly computes byte or token overage | Reject locally, display truncation guidance, and avoid network transmission |
| Streaming payload is malformed | SSE decoder cannot parse event framing | Fail the job, log sanitized provider diagnostics, and allow retry |
| User cancels a running job | Runtime issues `cancel_job` action | Stop stream consumption, release buffers, and emit `cancelled` |
| Provider rate limits the request | HTTP 429 or provider error payload | Mark job failed with retry-after information and exponential backoff recommendation |

## 7. Security Considerations

This section defines the minimum security properties of the shared runtime.

The platform does not read secrets directly from plaintext config files. It resolves credentials only through RFC-002 secret providers. The runtime never streams terminal content automatically; it only receives a pre-built `AIContextEnvelope` that has already passed policy validation. Logs emitted by `src/ai/` must exclude prompt content, terminal output, bearer tokens, and provider payloads unless a separate redacted debug mode is enabled.

## 8. Testing Strategy

This section defines the minimum automated coverage for RFC-001.

| Test Area | Command | Expected Scope |
|-----------|---------|----------------|
| Shared Zig unit tests | `zig build test -Dtest-filter=ai` | Request assembly, registry behavior, error mapping, SSE parsing |
| Transport contract tests | `zig build test -Dtest-filter=openrouter` | Header mapping, retry policy, stream framing |
| ABI action tests | `zig build test -Dtest-filter=apprt` | Stable action serialization and routing |
| Documentation generation | `zig build` | Config and command docs compile successfully |

## 9. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| Implement provider calls separately in Swift and GTK code | It would duplicate logic, split policy enforcement, and create inconsistent future provider support. |
| Bind directly to OpenRouter without an internal provider abstraction | It would make future provider support expensive and entangle request lifecycle with one backend. |
| Execute provider calls on the PTY or render execution paths | It would violate Ghostty performance constraints and create visible latency regressions. |

## 10. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Where does the AI runtime live? | **In a new shared Zig layer under `src/ai/`.** This keeps policy, provider behavior, and job orchestration consistent across macOS and GTK. |
| 2 | Which backend is implemented first? | **OpenRouter.** It becomes the production-first provider while preserving an internal provider abstraction. |
| 3 | How are native runtimes notified of job progress? | **Through explicit app and surface actions plus streamed events.** This aligns with Ghostty’s existing runtime boundary instead of inventing a parallel signaling path. |
