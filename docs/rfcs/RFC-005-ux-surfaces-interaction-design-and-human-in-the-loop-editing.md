# RFC-005: UX Surfaces, Interaction Design, and Human-in-the-Loop Editing
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | RFC-001, RFC-002, RFC-004            |
| Phase       | 2                                    |

---

## 1. Motivation

Production-grade AI features live or die on user experience. The fork needs native, low-friction assistant surfaces that feel at home in Ghostty on both macOS and GTK while preserving human review and editability. This RFC defines the cross-platform UX model, the macOS and GTK integration points, the review buffer workflow, and the command palette and shortcut affordances for the first AI release.

## 2. UX Overview

This section defines the target interaction model for the initial assistant experience.

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Terminal Window                                                    │
│ ┌────────────────────────────┬────────────────────────────────────┐ │
│ │ Terminal Surface           │ Assistant Panel                    │ │
│ │                            │                                    │ │
│ │ Selected output            │  Ask Ghostty AI                    │ │
│ │ Visible viewport           │  ───────────────────────────────    │ │
│ │                            │  • Explain selection               │ │
│ │                            │  • Summarize viewport              │ │
│ │                            │  • Suggest next command            │ │
│ │                            │                                    │ │
│ │                            │  Review Buffer                     │ │
│ │                            │  [editable content before send]    │ │
│ └────────────────────────────┴────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.1 First-Release Surfaces

The first release includes four primary surfaces: a side panel, a compact inline assistant overlay, command palette actions, and a review buffer editor. It does not include autonomous background agents or invisible execution flows.

## 3. Shared UX Model

This section defines the UI-independent view state used by both runtimes.

```zig
pub const AssistantPanelState = enum {
    hidden,
    idle,
    reviewing_context,
    streaming,
    awaiting_approval,
    showing_result,
    failed,
};

pub const ReviewBuffer = struct {
    original_context: AIContextEnvelope,
    edited_context_text: []const u8,
    prompt_text: []const u8,
    dirty: bool,
};
```

### 3.1 Shared Actions

This section defines the initial user-facing actions.

| Action | Scope | Description |
|--------|-------|-------------|
| `ai:open_panel` | app or surface | Opens the assistant panel for the focused context |
| `ai:close_panel` | app or surface | Closes the active panel or overlay |
| `ai:explain_selection` | surface | Captures selection and opens explain flow |
| `ai:summarize_viewport` | surface | Captures visible content and opens summarize flow |
| `ai:propose_command` | surface | Starts a proposal-first workflow for the current terminal state |
| `ai:retry_last` | surface | Replays the last request with the same editable review state |

## 4. Implementation Details

This section defines the runtime-specific UI work.

### 4.1 macOS

This section defines the production integration points for macOS.

| Path | Status | Purpose |
|------|--------|---------|
| `macos/Sources/Features/AI/AssistantPanel.swift` | [new file] | SwiftUI panel UI |
| `macos/Sources/Features/AI/AssistantPanelViewModel.swift` | [new file] | `@MainActor` view model that binds to shared AI events |
| `macos/Sources/Features/AI/ReviewBufferView.swift` | [new file] | Editable review and approval surface |
| `macos/Sources/Features/AI/InlineAssistantOverlay.swift` | [new file] | Compact overlay anchored to the active `SurfaceView` |
| `macos/Sources/Features/AI/AssistantPanelController.swift` | [new file] | Window-scoped coordinator owned by `BaseTerminalController` |

Existing files to modify:
- `macos/Sources/Features/Terminal/BaseTerminalController.swift`
- `macos/Sources/Features/Terminal/TerminalView.swift`
- `macos/Sources/Ghostty/Ghostty.App.swift`
- `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift`
- `macos/Sources/Helpers/PermissionRequest.swift`

The panel is window-scoped and bound to the focused surface. This aligns with existing controller ownership and command palette routing.

### 4.2 GTK

This section defines the production integration points for GTK.

| Path | Status | Purpose |
|------|--------|---------|
| `src/apprt/gtk/class/assistant_panel.zig` | [new file] | Panel widget or dialog content |
| `src/apprt/gtk/class/review_buffer.zig` | [new file] | Editable review widget |
| `src/apprt/gtk/class/assistant_overlay.zig` | [new file] | Surface-level inline assistant overlay |

Existing files to modify:
- `src/apprt/gtk/class/window.zig`
- `src/apprt/gtk/class/command_palette.zig`
- `src/apprt/gtk/class/application.zig`
- `src/apprt/gtk/class/surface.zig`

The GTK implementation mirrors the shared state machine while remaining idiomatic to Ghostty’s current `Window` and command palette architecture.

### 4.3 Command Palette and Shortcuts

This section defines discoverability and invocation paths.

Assistant actions are registered as keybinding actions in `src/input/Binding.zig`, surfaced as command names in `src/input/command.zig`, and included in command palette sources for both runtimes. Default shortcuts are conservative and disabled unless `ai-enabled` is true.

## 5. Human-in-the-Loop Editing

This section defines the review buffer behavior.

The review buffer is the default staging area between context capture and network send. It shows the prompt, captured context summary, applied redactions, and any warnings from RFC-004. Users can edit prompt and context text before submission and can copy assistant output into the terminal, clipboard, or a scratch editor without immediate execution.

### 5.1 Review Buffer States

```text
┌──────────────────────────────────────────────────────────────┐
│ Review Buffer                                                │
│ Prompt                                                       │
│ [ editable text ]                                            │
│                                                              │
│ Context                                                      │
│ [ editable normalized context ]                              │
│                                                              │
│ Warnings: 1 injection risk boundary inserted                 │
│                                                              │
│ [Cancel] [Save Draft] [Send to AI]                           │
└──────────────────────────────────────────────────────────────┘
```

### 5.2 Output Actions

This section defines the initial output affordances.

| Result Action | Behavior |
|---------------|----------|
| Insert into terminal input | Paste result into the terminal input buffer without auto-execution |
| Copy to clipboard | Copies result through existing clipboard primitives |
| Save as note | Writes to a local scratch artifact defined by the fork, not to upstream Ghostty |
| Run proposed command | Hand off to RFC-003 approval flow |

## 6. Error Handling

This section defines the main user-facing UX failures.

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Panel opens with no active surface | Window controller lacks focused surface | Show empty state and disable context-bound actions |
| Review buffer cannot render current context | Shared state build fails or data is missing | Show error banner, allow retry, and preserve user prompt text |
| Streaming result is interrupted | `AIStreamEvent.failed` or `cancelled` | Keep partial output visible with retry affordance |
| User switches surface mid-request | Focus change invalidates bound target | Keep the request pinned to its original surface and clearly label it |
| Approval dialog is dismissed | Window closes or dialog is cancelled | Leave the request pending only if the surface still exists, otherwise cancel cleanly |
| Keyboard shortcut collides with existing config | Accelerator registration detects conflict | Do not bind the default and surface a config warning |

## 7. Security Considerations

This section defines UX requirements that reinforce trust.

The UI must always show what context will be sent and what command will be executed. Streaming output is never inserted into the terminal automatically. Approval prompts must be attached to the owning window and reference the precise surface, working directory, and command involved. No hidden prompt augmentation is allowed outside clearly described system policy generated by the shared core.

## 8. Testing Strategy

This section defines minimum UI coverage.

| Test Area | Command | Expected Scope |
|-----------|---------|----------------|
| macOS unit tests | `macos/build.nu --action test` | View model transitions, review buffer state, command palette actions |
| macOS UI tests | `macos/build.nu --action test` | Panel toggling, review flow, command proposal approval |
| GTK tests | `zig build test -Dtest-filter=gtk-ai` | Window/panel lifecycle, action routing |
| Shared action tests | `zig build test -Dtest-filter=ai-action` | Cross-runtime command naming and dispatch |

## 9. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| A single global assistant window detached from all terminal windows | It would weaken surface affinity and make context provenance harder to understand. |
| Inline-only UX with no side panel | It would not provide enough room for review, editing, and approval flows. |
| Sending context immediately from command palette actions | It would remove a crucial human review step for a terminal product. |

## 10. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the primary UX surface? | **A window-scoped assistant panel with a review buffer.** This gives enough space for transparent, editable workflows. |
| 2 | How are quick actions exposed? | **Through command palette entries and keybindings backed by shared actions.** This fits Ghostty’s existing interaction model. |
| 3 | Does assistant output auto-run or auto-insert? | **No.** Output remains user-controlled and execution is delegated to RFC-003 approval flows. |
