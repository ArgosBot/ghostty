# RFC-006: Observability, Packaging, Release Strategy, and Rollout Governance
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | RFC-001, RFC-002, RFC-003, RFC-004, RFC-005 |
| Phase       | 3                                    |

---

## 1. Motivation

AI features are operationally complex: they add remote dependencies, streaming transports, secret management, safety controls, new UI states, and approval-driven workflows. A production-ready fork therefore needs strong observability, packaging discipline, release gating, and rollback controls before broad rollout. This RFC defines the operability model for the AI fork so the system can be debugged, packaged, tested, and released like a world-class product.

## 2. Operability Overview

This section defines the production control plane for the fork.

```text
┌──────────────────────────────────────────────────────────────┐
│ Build + Test Pipeline                                       │
│  unit │ integration │ UI │ packaging │ release verification │
└──────────────────────────┬───────────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ Rollout Controls                                             │
│  feature flags │ provider allowlist │ staged defaults        │
└──────────────────────────┬───────────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ Runtime Observability                                        │
│  health counters │ latency histograms │ audit trail │ logs    │
└──────────────────────────────────────────────────────────────┘
```

## 3. Shared Types and Protocols

This section defines the minimum shared observability model.

```zig
pub const AIRolloutStage = enum {
    disabled,
    internal,
    beta,
    general_availability,
};

pub const AIHealthSnapshot = struct {
    active_jobs: u32,
    queued_jobs: u32,
    failed_jobs_last_hour: u32,
    average_first_token_latency_ms: u32,
    average_completion_latency_ms: u32,
};

pub const AIAuditEvent = struct {
    timestamp_unix_ms: i64,
    category: Category,
    surface_id: ?u64,
    provider_id: ?[]const u8,
    decision: ?[]const u8,

    pub const Category = enum {
        request_started,
        request_completed,
        request_failed,
        approval_requested,
        approval_granted,
        approval_denied,
        policy_blocked,
    };
};
```

## 4. Implementation Details

This section defines the production hardening work needed outside the feature core.

### 4.1 Logging and Metrics

This section defines what is recorded.

| Signal | Recorded | Never Recorded |
|--------|----------|----------------|
| Request lifecycle | Provider id, model id, timestamps, success/failure classification | Prompt text, terminal content, API keys |
| Streaming health | First-token latency, total latency, cancel count | Stream payload text |
| Approval events | Tool name, decision type, risk level | Reviewed command output or private prompt text |
| Policy blocks | Block reason and scope | Raw blocked content |

### 4.2 Local Diagnostics

This section defines how users and developers inspect system state.

| Capability | Path |
|------------|------|
| Health report command | `ghostty +ai-status` in `src/cli/ghostty.zig` [modified] |
| Audit trail export | `ghostty +ai-audit` in `src/cli/ghostty.zig` [modified] |
| Runtime diagnostics panel | `src/inspector/` integration [modified] |
| Crash report enrichment | Existing crash report generation with redacted AI state summary [modified] |

### 4.3 Packaging

This section defines packaging rules.

1. Builds must remain compatible with the offline cache flow documented in `PACKAGING.md`.
2. AI support cannot introduce build-time dependence on provider connectivity.
3. Secrets, model defaults, and rollout stage are runtime configuration only.
4. Optional runtime dependencies for secret storage must degrade gracefully rather than breaking terminal startup.
5. Packages must be able to disable AI completely at compile time with a build option such as `-Denable-ai=false`.

### 4.4 Rollout Strategy

This section defines staged release behavior.

| Stage | Defaults | Intended Audience |
|-------|----------|-------------------|
| `disabled` | AI off, no shortcuts, no provider calls | Downstream packages and conservative users |
| `internal` | AI off by default, feature flag enabled for maintainers | Core team validation |
| `beta` | AI on behind explicit opt-in onboarding | Early adopters |
| `general_availability` | AI available in stable builds, still opt-in for agent execution | Broad production use |

### 4.5 Quality Gates

This section defines the release checklist.

| Gate | Requirement |
|------|-------------|
| Unit tests | Shared AI, policy, context, and agent tests pass |
| UI tests | macOS and GTK action flows pass for panel, review, and approvals |
| Packaging tests | Offline build and install flow passes with AI both enabled and disabled |
| Performance | No statistically meaningful regression in terminal startup, input latency, or rendering hot paths |
| Security review | Secrets, prompt injection defenses, and approval gates reviewed before stage promotion |

## 5. Error Handling

This section defines the major operability failure scenarios.

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| AI startup fails because a secret backend is unavailable | Startup health check reports missing backend | Disable AI features, keep terminal usable, and surface actionable diagnostics |
| Provider latency spikes or streaming flaps | Health snapshot exceeds thresholds | Degrade to non-streaming mode or recommend retry based on policy |
| Audit log grows too large | File size or event count threshold reached | Rotate logs and retain only bounded recent history |
| Packaging build fails with AI enabled | CI packaging step fails | Gate release promotion and verify `-Denable-ai=false` fallback still succeeds |
| Rollout stage misconfiguration exposes unfinished features | Stage guard mismatch found at startup | Force downgrade to the safest allowed stage and log the issue |
| Crash reports include sensitive AI payloads | Redaction verification fails in tests | Block release until crash enrichment is content-safe |

## 6. Security Considerations

This section defines operational security requirements.

Telemetry is strictly local by default and content-free. Any future optional remote telemetry must require explicit user opt-in and separate review. Audit exports are intended for the local operator and therefore remain redacted. Release promotion requires a manual review of approval gates, provider policy behavior, and prompt-injection defenses.

## 7. Testing Strategy

This section defines the end-to-end validation matrix.

| Area | Command | Expected Scope |
|------|---------|----------------|
| Zig unit and integration tests | `zig build test` | Shared runtime, policy, context, agent, diagnostics |
| Targeted Zig tests | `zig build test -Dtest-filter=ai` | Fast AI-focused iteration |
| macOS build and tests | `macos/build.nu --action test` | UI and unit tests |
| Build without AI | `zig build -Denable-ai=false` | Compile-time disable path |
| Packaging simulation | follow `PACKAGING.md` offline-cache flow | Distribution compatibility |

## 8. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| Treat AI as a purely experimental feature with minimal observability | It would delay the operational work required for safe production rollout. |
| Enable AI by default once the UI works | It would outpace packaging, policy, and safety maturity. |
| Rely only on provider-side logs for debugging | It would reduce local diagnosability and conflict with privacy goals. |

## 9. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the default rollout stage for shipped builds? | **`disabled` or explicit opt-in.** Availability expands only after the quality gates are met. |
| 2 | Can AI failures break normal terminal startup? | **No.** AI is an optional subsystem and must fail closed while preserving terminal functionality. |
| 3 | How is production readiness enforced? | **Through staged rollout, offline packaging compatibility, automated tests, and explicit security review gates.** |
