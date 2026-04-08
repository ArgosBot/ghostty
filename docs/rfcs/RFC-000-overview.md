# RFC-000: AI Fork RFC Overview
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | —                                    |
| Phase       | 0                                    |

---

## 1. Motivation

This document establishes the RFC set for adding production-grade AI and agent capabilities to the Ghostty fork. The fork must remain fast, native, secure, and adaptable while introducing OpenRouter-first assistant workflows, provider abstraction, approval-gated automation, and cross-platform user experience. This RFC defines the index, dependency graph, implementation order, and shared vocabulary for RFC-001 through RFC-006.

## 2. RFC Set Overview

This section defines the complete RFC set and the responsibility boundary of each document.

| RFC | Title | Purpose | Primary Areas |
|-----|-------|---------|---------------|
| RFC-001 | AI Platform Core and Provider Abstraction | Shared AI runtime, jobs, streaming, provider abstraction, OpenRouter-first transport | `src/ai/`, `src/App.zig`, `src/Surface.zig`, `src/apprt/action.zig` |
| RFC-002 | AI Auth, Secrets, Privacy, and Policy Controls | API keys, config, redaction, consent, network and data policy | `src/config/Config.zig`, `src/config/file_load.zig`, runtime-specific secret storage |
| RFC-003 | Agent Runtime, Tooling Contract, and Approval Model | Structured tools, handoff-to-agent execution, approval checkpoints, autonomous session lifecycle | `src/ai/agent/`, `src/termio/`, runtime action plumbing |
| RFC-004 | Terminal Context, Shell/PTY Integration, and Prompt-Injection Defenses | Ambient terminal awareness, semantic prompts, OSC 7, selection/scrollback policy, injection resistance | `src/Surface.zig`, `src/terminal/`, `src/shell-integration/` |
| RFC-005 | UX Surfaces, Interaction Design, and Human-in-the-Loop Editing | AI panel, inline assistant, command palette actions, handoff flows, review/edit flows on macOS and GTK | `macos/Sources/Features/AI/`, `src/apprt/gtk/class/` |
| RFC-006 | Observability, Packaging, Release Strategy, and Rollout Governance | Telemetry, diagnostics, offline packaging, test matrix, staged rollout, operability | build/test/docs/release pipeline |

## 3. Dependency Graph

This section defines the required implementation order and dependency rules.

```text
RFC-001 ──▶ RFC-002 ──▶ RFC-004 ──▶ RFC-005 ──▶ RFC-006
   │            │            │
   └────────────┴────────────┴──────▶ RFC-003 ──▶ RFC-006
```

### 3.1 Dependency Rules

The dependency graph is intentionally shallow so that shared types stabilize before UI and agent execution work begins.

| RFC | Depends on | Rationale |
|-----|------------|-----------|
| RFC-001 | — | Defines the shared platform runtime and canonical AI types. |
| RFC-002 | RFC-001 | Policy objects, provider profiles, and secret references extend the core runtime. |
| RFC-003 | RFC-001, RFC-002, RFC-004 | Agent execution requires stable runtime contracts, policy controls, and trusted context capture. |
| RFC-004 | RFC-001, RFC-002 | Context capture must use the core runtime and obey privacy policy. |
| RFC-005 | RFC-001, RFC-002, RFC-004 | UI flows must reflect policy and context capture rules. |
| RFC-006 | RFC-001, RFC-002, RFC-003, RFC-004, RFC-005 | Operability and release governance depend on the full feature shape. |

## 4. Shared Vocabulary

This section defines canonical terminology used across the RFC set.

| Term | Meaning |
|------|---------|
| AI Platform | The shared orchestration layer that handles requests, jobs, streaming, provider selection, and policy enforcement. |
| Provider | A model backend implementation behind a stable interface, such as OpenRouter. |
| Agent Session | A multi-step AI workflow that can inspect context, propose actions, and request approvals. |
| Agent Handoff | An explicit transition from assistant mode into execution mode where the agent continues operating in the current terminal session. |
| Context Envelope | A bounded, structured bundle of terminal-derived context attached to a request. |
| Session Awareness | The agent's structured knowledge of the active surface, working directory, semantic prompt state, and recent command/result context. |
| Approval Gate | A mandatory user confirmation checkpoint before a sensitive action occurs. |
| Tool Invocation | A structured request from the model to use a local capability, such as proposing a command. |
| Review Buffer | An editable output artifact that the user can inspect before insertion or execution. |
| Rollout Stage | A feature flag or release channel stage controlling AI exposure and default behavior. |

## 5. Repository Alignment

This section records the repository facts that shaped the RFC boundaries.

| Existing Path | Relevant Fact |
|---------------|---------------|
| `src/App.zig` | Shared application coordinator already dispatches app and surface actions. |
| `src/Surface.zig` | Surface state already tracks clipboard, password input, semantic prompt interaction, and shell integration settings. |
| `src/apprt/action.zig` | Runtime action ABI exists and is the clean cross-platform hook for new shared actions. |
| `src/config/Config.zig` | Central configuration system is the correct home for AI config and policy flags. |
| `src/terminal/osc.zig` | OSC 7 and OSC 133 handling already exist and can seed trusted context capture. |
| `src/termio/Termio.zig` and `src/termio/Exec.zig` | PTY and subprocess paths are latency-sensitive and must not block on AI work. |
| `src/apprt/gtk/class/command_palette.zig` | GTK already has a command palette integration point. |
| `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift` | macOS already has a command palette and window-scoped interaction model. |
| `macos/Sources/Helpers/PermissionRequest.swift` | macOS already has a reusable consent prompt primitive suitable for AI permissions. |
| `PACKAGING.md` | Packaging assumes offline builds after cache prefetch and must remain compatible with downstream distribution. |

## 6. Suggested Implementation Order

This section translates the dependency graph into workstreams.

1. Implement RFC-001 to create the shared runtime and OpenRouter transport.
2. Implement RFC-002 to secure credentials, policy defaults, and redaction before any broad feature exposure.
3. Implement RFC-004 to create trusted context capture primitives and prompt-injection boundaries.
4. Implement RFC-005 to ship non-executing user-facing assistant surfaces.
5. Implement RFC-003 to add agent execution flows with approval gates after policy and context systems are stable.
6. Implement RFC-006 to harden observability, packaging, release controls, and production operations.

## 7. Files Introduced by This RFC Set

This section lists the RFC documents created in this fork.

| File | Status |
|------|--------|
| `docs/rfcs/RFC-000-overview.md` | New file |
| `docs/rfcs/RFC-001-ai-platform-core-and-provider-abstraction.md` | New file |
| `docs/rfcs/RFC-002-ai-auth-secrets-privacy-and-policy-controls.md` | New file |
| `docs/rfcs/RFC-003-agent-runtime-tooling-contract-and-approval-model.md` | New file |
| `docs/rfcs/RFC-004-terminal-context-shell-pty-integration-and-prompt-injection-defenses.md` | New file |
| `docs/rfcs/RFC-005-ux-surfaces-interaction-design-and-human-in-the-loop-editing.md` | New file |
| `docs/rfcs/RFC-006-observability-packaging-release-strategy-and-rollout-governance.md` | New file |

## 8. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| One monolithic RFC for the entire AI fork | It would blur ownership, increase review load, and make future amendments unsafe. |
| Splitting transport, policy, and UX into more than ten RFCs | The project would gain coordination overhead before any implementation value is realized. |
| Starting with agent execution before context and policy design | That would increase security risk and make provider integration harder to audit. |

## 9. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | How many RFCs are required for a production-ready AI fork? | **Six implementation RFCs plus this overview.** This is the smallest set that isolates core runtime, policy, context, UX, agent execution, and operability. |
| 2 | Which provider is the first-class initial backend? | **OpenRouter is the first production provider.** The runtime remains provider-agnostic so future backends can be added without redesign. |
| 3 | Must the product support Warp-like handoff into an executing agent that already knows the current session? | **Yes.** The design explicitly includes an execution-mode handoff backed by structured session awareness and configurable approval policy. |
