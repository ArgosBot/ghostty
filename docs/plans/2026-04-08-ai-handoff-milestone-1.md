# Ghostty AI Handoff Milestone 1 Implementation Plan

> For Hermes: Use subagent-driven-development skill to implement this plan task-by-task.

Goal: Build the first production-quality implementation slice for Ghostty AI handoff by adding shared AI core scaffolding, session awareness primitives, config and action wiring, and a tested non-UI handoff path.

Architecture: This milestone stays mostly in the shared Zig core. It introduces a new `src/ai/` module with stable types and a lightweight orchestration skeleton, adds structured session awareness derived from existing surface and terminal state, and wires new AI actions/config so macOS and GTK can bind UI later without redesign. The milestone intentionally avoids full provider transport and full native UI implementation; instead it establishes the execution spine and proves it with targeted Zig tests at every step.

Tech Stack: Zig, Ghostty shared core (`src/`), existing app/runtime action ABI, existing terminal/OSC/shell-integration state, Zig unit tests via `zig build test -Dtest-filter=...`.

---

### Task 1: Create shared AI type module

Objective: Introduce the core AI and handoff data structures in a standalone module with tests before any wiring.

Files:
- Create: `src/ai/types.zig`
- Create: `src/ai/main.zig`
- Modify: `build.zig`
- Test: `src/ai/types.zig`

Step 1: Write failing tests

Add Zig tests in `src/ai/types.zig` covering:
- `AgentExecutionMode` enum contains `review_before_execute` and `auto_execute_trusted`
- `AISessionAwareness.PromptState` contains `unknown`, `at_prompt`, `command_running`, `password_input`
- `AgentHandoff` can be instantiated with awareness + objective
- default helpers or constructors preserve fields exactly

Step 2: Run test to verify failure

Run: `zig build test -Dtest-filter=AgentHandoff`
Expected: FAIL — module or types do not exist yet

Step 3: Write minimal implementation

Implement in `src/ai/types.zig`:
- `pub const AgentExecutionMode = enum { review_before_execute, auto_execute_trusted };`
- `pub const AISessionAwareness = struct { ... }`
- `pub const AgentHandoff = struct { mode, awareness, objective }`
- any small helper constructors needed by later tasks

Implement `src/ai/main.zig` exporting the new types module.

Update `build.zig` only as needed so tests compile with the new module files.

Step 4: Run test to verify pass

Run: `zig build test -Dtest-filter=AgentHandoff`
Expected: PASS

Step 5: Run local regression tests

Run: `zig build test -Dtest-filter=action`
Expected: PASS or pre-existing unrelated skips only

Step 6: Commit

```bash
git add src/ai/types.zig src/ai/main.zig build.zig
git commit -m "feat: add AI handoff core types"
```

### Task 2: Add session awareness capture helpers

Objective: Add a tested shared helper that derives structured session awareness from existing surface state without introducing UI.

Files:
- Create: `src/ai/context/session_awareness.zig`
- Modify: `src/ai/main.zig`
- Modify: `src/Surface.zig`
- Test: `src/ai/context/session_awareness.zig`

Step 1: Write failing tests

Add Zig tests for a pure helper API that maps lightweight input state to `AISessionAwareness`, including:
- prompt state detection for idle prompt / running command / password input
- cwd preservation
- last command and exit code propagation
- selection presence propagation

Design the tests so they do not require full runtime startup. Use a small pure struct for the raw inputs if needed.

Step 2: Run test to verify failure

Run: `zig build test -Dtest-filter=session-awareness`
Expected: FAIL — helper module missing

Step 3: Write minimal implementation

Implement a pure builder in `src/ai/context/session_awareness.zig` plus the smallest `Surface` helper needed for future runtime consumption, such as:
- `pub fn buildSessionAwareness(raw: RawSessionState) AISessionAwareness`
- `pub fn aiSessionAwareness(self: *const Surface) AISessionAwareness` or an equivalent non-invasive accessor

Do not guess unavailable shell metadata; use `null` or `unknown` where the current codebase has no stable source yet.

Step 4: Run test to verify pass

Run: `zig build test -Dtest-filter=session-awareness`
Expected: PASS

Step 5: Run nearby regression tests

Run: `zig build test -Dtest-filter=semantic prompt`
Expected: PASS or pre-existing unrelated skips only

Step 6: Commit

```bash
git add src/ai/context/session_awareness.zig src/ai/main.zig src/Surface.zig
git commit -m "feat: add session awareness capture helpers"
```

### Task 3: Add AI handoff and assistant actions to keybinding parsing

Objective: Make the new AI actions first-class shared actions that can be referenced by config, command palette, and runtimes later.

Files:
- Modify: `src/input/Binding.zig`
- Modify: `src/input/command.zig`
- Test: `src/input/Binding.zig`

Step 1: Write failing tests

Add parsing tests in `src/input/Binding.zig` covering:
- `ai:open_panel`
- `ai:handoff_to_agent`
- `ai:propose_command`
- `ai:retry_last`

Also add tests for any enum/string conversion in `src/input/command.zig` if that file has existing test patterns.

Step 2: Run test to verify failure

Run: `zig build test -Dtest-filter="parse: action"`
Expected: FAIL for the new AI actions

Step 3: Write minimal implementation

Add the new actions to `Binding.Action` and command name formatting/parsing in `src/input/command.zig` using existing conventions.

Step 4: Run test to verify pass

Run: `zig build test -Dtest-filter="parse: action"`
Expected: PASS

Step 5: Run local regression tests

Run: `zig build test -Dtest-filter=command`
Expected: PASS or pre-existing unrelated skips only

Step 6: Commit

```bash
git add src/input/Binding.zig src/input/command.zig
git commit -m "feat: add AI handoff keybinding actions"
```

### Task 4: Add runtime action ABI for AI actions

Objective: Extend the apprt action ABI with minimal AI-related actions in a way that keeps future macOS/GTK wiring straightforward.

Files:
- Modify: `src/apprt/action.zig`
- Modify: `include/ghostty.h`
- Test: `src/apprt/action.zig`

Step 1: Write failing tests

Add tests validating:
- new action enum values exist at the end of the ABI list
- C header enum sync still passes
- any new non-void action payload types remain C-compatible if introduced

Step 2: Run test to verify failure

Run: `zig build test -Dtest-filter="ghostty.h"`
Expected: FAIL because header / action enum are not in sync yet

Step 3: Write minimal implementation

Add new ABI-safe actions at the end only, such as:
- `ai_open_panel`
- `ai_close_panel`
- `ai_handoff_to_agent`
- `ai_retry_last`

Prefer void actions for this milestone unless a payload is absolutely required.

Update `include/ghostty.h` in lockstep.

Step 4: Run test to verify pass

Run: `zig build test -Dtest-filter="ghostty.h"`
Expected: PASS

Step 5: Run local regression tests

Run: `zig build test -Dtest-filter=action`
Expected: PASS

Step 6: Commit

```bash
git add src/apprt/action.zig include/ghostty.h
git commit -m "feat: add AI apprt actions"
```

### Task 5: Add AI config keys for handoff policy

Objective: Add the first AI config keys so behavior can be controlled without hardcoding future product decisions.

Files:
- Modify: `src/config/Config.zig`
- Test: `src/config/Config.zig`

Step 1: Write failing tests

Add config parsing tests for:
- `ai-enabled = true`
- `ai-agent-handoff-mode = review_before_execute`
- `ai-agent-handoff-mode = auto_execute_trusted`
- invalid handoff mode rejected cleanly
- `ai-agent-auto-execute = true`

Step 2: Run test to verify failure

Run: `zig build test -Dtest-filter="parseCLI"`
Expected: FAIL for the new AI config keys

Step 3: Write minimal implementation

Add the smallest viable config surface to `Config.zig` using existing conventions:
- `ai-enabled: bool = false`
- `ai-agent-handoff-mode: ... = .review_before_execute`
- `ai-agent-auto-execute: bool = false`

Ensure parsing and docs metadata align with established patterns.

Step 4: Run test to verify pass

Run: `zig build test -Dtest-filter="ai-agent-handoff-mode"`
Expected: PASS

Step 5: Run local regression tests

Run: `zig build test -Dtest-filter="parse e:"`
Expected: PASS or pre-existing unrelated skips only

Step 6: Commit

```bash
git add src/config/Config.zig
git commit -m "feat: add AI handoff policy config"
```

### Task 6: Add app-level handoff message plumbing

Objective: Create a non-UI app-level path for AI handoff requests so later runtimes can call into one shared path.

Files:
- Modify: `src/App.zig`
- Modify: `src/Surface.zig`
- Modify: `src/ai/main.zig`
- Possibly create: `src/ai/Platform.zig`
- Test: relevant new or modified Zig files

Step 1: Write failing tests

Add tests for a minimal handoff orchestration surface, for example:
- app can build a handoff request from a target surface
- no-surface app target is rejected cleanly where appropriate
- a handoff request contains objective + session awareness

Keep this pure and lightweight; avoid network/provider behavior.

Step 2: Run test to verify failure

Run: `zig build test -Dtest-filter=handoff`
Expected: FAIL — orchestration path missing

Step 3: Write minimal implementation

Implement the smallest possible shared path that:
- accepts an AI objective string plus target surface
- fetches session awareness from the surface
- packages `AgentHandoff`
- returns or queues a shared message for future runtime/UI consumption

Do not implement provider calls or native panels in this milestone.

Step 4: Run test to verify pass

Run: `zig build test -Dtest-filter=handoff`
Expected: PASS

Step 5: Run local regression tests

Run: `zig build test -Dtest-filter=surface`
Expected: PASS or pre-existing unrelated skips only

Step 6: Commit

```bash
git add src/App.zig src/Surface.zig src/ai/main.zig src/ai/Platform.zig
git commit -m "feat: add shared AI handoff plumbing"
```

### Task 7: Final integration verification for milestone 1

Objective: Prove the shared-core milestone is coherent, tested, and ready for the next implementation slice.

Files:
- Review only: all files changed in Tasks 1-6

Step 1: Run focused shared-core verification

Run:
- `zig build test -Dtest-filter=AgentHandoff`
- `zig build test -Dtest-filter=session-awareness`
- `zig build test -Dtest-filter=action`
- `zig build test -Dtest-filter=ghostty.h`
- `zig build test -Dtest-filter=ai-agent-handoff-mode`
- `zig build test -Dtest-filter=handoff`

Expected: PASS or documented pre-existing unrelated skips only

Step 2: Run broader regression suite

Run: `zig build test`
Expected: no new failures introduced by this milestone

Step 3: Review diff and summarize

Run:
- `git diff --stat origin/main...HEAD`
- `git status --short`

Expected: clean, intentional shared-core delta

Step 4: Commit any final fixes

```bash
git add -A
git commit -m "feat: complete AI handoff milestone 1 core"
```
