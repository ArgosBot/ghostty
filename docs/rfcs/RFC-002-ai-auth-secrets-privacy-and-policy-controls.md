# RFC-002: AI Auth, Secrets, Privacy, and Policy Controls
| Field       | Value                                |
|-------------|--------------------------------------|
| Status      | Draft                                |
| Created     | 2026-04-08                           |
| Depends on  | RFC-001                              |
| Phase       | 1                                    |

---

## 1. Motivation

An AI-enabled terminal becomes unsafe if it can transmit terminal contents, shell context, or credentials without clear policy and predictable consent rules. Ghostty already contains sensitive primitives such as clipboard access, password input detection, shell integration metadata, and platform-native permission flows. This RFC defines how the fork stores provider credentials, enforces data handling policy, applies redaction, and requires explicit user approvals before sensitive data leaves the machine.

## 2. Policy Architecture Overview

This section defines the layered policy model applied before any provider call.

```text
┌────────────────────────────────────────────────────────────┐
│ User Action or AI Job Submission                          │
└──────────────────────────┬─────────────────────────────────┘
                           ▼
┌────────────────────────────────────────────────────────────┐
│ AIPolicyEngine                                             │
│  1. Resolve provider profile                               │
│  2. Resolve secret reference                               │
│  3. Evaluate consent policy                                │
│  4. Apply redaction rules                                  │
│  5. Enforce secure-input and privacy guards                │
└──────────────────────────┬─────────────────────────────────┘
                           ▼
                allowed ───┴─── rejected
```

### 2.1 Policy Principles

This fork follows four principles: explicit opt-in, least data transfer, user-editable review before send when risk is non-trivial, and platform-native secret storage wherever possible.

## 3. Shared Types and Protocols

This section defines the canonical policy objects shared across runtimes.

```zig
pub const AISecretRef = union(enum) {
    env_var: []const u8,
    macos_keychain: []const u8,
    libsecret: []const u8,
    plaintext_file: []const u8,
};

pub const AIConsentMode = enum {
    deny,
    ask,
    allow,
};

pub const AIRedactionRule = struct {
    id: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    scope: Scope,

    pub const Scope = enum {
        selection,
        viewport,
        scrollback,
        cwd,
        environment,
        clipboard,
        all,
    };
};

pub const AIProviderProfile = struct {
    id: []const u8,
    display_name: []const u8,
    secret_ref: AISecretRef,
    endpoint: []const u8,
    default_model: []const u8,
    consent_mode: AIConsentMode,
    allow_streaming: bool,
    allow_tools: bool,
};

pub const AIPolicySnapshot = struct {
    send_selection: AIConsentMode,
    send_viewport: AIConsentMode,
    send_scrollback: AIConsentMode,
    send_cwd: AIConsentMode,
    send_environment: AIConsentMode,
    allow_agent_execution: AIConsentMode,
    require_review_before_send: bool,
    max_context_bytes: usize,
    redaction_rules: []const AIRedactionRule,
};
```

### 3.1 Error Model

This section defines policy-specific failures.

```zig
pub const AIPolicyError = error{
    SecretUnavailable,
    SecretStorageUnsupported,
    ConsentDenied,
    SecureInputActive,
    RedactionFailed,
    PolicyInvariantViolation,
};
```

## 4. Implementation Details

This section defines the concrete policy and secret storage integration work.

### 4.1 Secret Resolution

This section defines the order and platform-specific secret behavior.

| Platform | Preferred Secret Source | Fallback | Notes |
|----------|-------------------------|----------|-------|
| macOS | Keychain item referenced by `AISecretRef.macos_keychain` | Environment variable | Keychain UI stays native and no plaintext token is required |
| Linux/GTK | libsecret item referenced by `AISecretRef.libsecret` | Environment variable | Desktop secret integration is required for production packaging |
| All platforms | Environment variable | Plaintext file only in explicitly allowed developer mode | Plaintext file support exists for local development and CI only |

New files:
- `src/ai/policy/SecretResolver.zig` [new file]
- `macos/Sources/Features/AI/KeychainSecretStore.swift` [new file]
- `src/apprt/gtk/secret_store.zig` [new file]

### 4.2 Config Keys

This section defines the new user-facing configuration surface.

| Key | Default | Description |
|-----|---------|-------------|
| `ai-enabled` | `false` | Master switch inherited from RFC-001 |
| `ai-provider-profile` | `default` | Selected provider profile name |
| `ai-secret-source` | `system` | Secret resolution strategy |
| `ai-consent-selection` | `ask` | Permission for sending selected text |
| `ai-consent-viewport` | `ask` | Permission for visible terminal region |
| `ai-consent-scrollback` | `deny` | Permission for historical terminal output |
| `ai-consent-cwd` | `ask` | Permission for current working directory |
| `ai-consent-environment` | `deny` | Permission for environment variables |
| `ai-require-review-before-send` | `true` | Forces review buffer before provider submission |
| `ai-max-context-bytes` | `32768` | Hard maximum serialized context size |
| `ai-redaction-rule` | empty | Repeatable redaction rules |
| `ai-allow-plaintext-secrets` | `false` | Developer-only escape hatch |

These keys belong in `src/config/Config.zig` and file parsing in `src/config/file_load.zig`.

### 4.3 Consent Evaluation

This section defines how the policy engine decides whether data can be transmitted.

```zig
pub fn authorizeContext(
    policy: AIPolicySnapshot,
    request: AIRequest,
    secure_input_active: bool,
) AIPolicyError!AuthorizedContext {
    if (secure_input_active) return error.SecureInputActive;
    if (!contextAllowed(policy, request.context)) return error.ConsentDenied;
    return try redactContext(policy, request.context);
}
```

All context authorization occurs before the provider transport is invoked. A rejected request never reaches network code.

### 4.4 Review Buffer Requirement

This section defines when review is mandatory.

Review is always mandatory for any request that includes scrollback, environment variables, more than one semantic prompt block, or any content captured while an approval gate is in `ask` mode. The user may edit or delete any captured segment before transmission.

## 5. User Experience and Consent Flows

This section defines the approval behavior exposed by native runtimes.

```text
┌──────────────────────────────────────────────────────────┐
│ Send Terminal Context to AI?                            │
│                                                          │
│ Provider: OpenRouter                                     │
│ Model: openrouter/auto                                   │
│ Includes: selection, cwd, 1 prompt block                 │
│ Redactions applied: 2                                    │
│                                                          │
│ [Review Context]   [Deny]   [Allow Once]   [Always Allow]│
└──────────────────────────────────────────────────────────┘
```

### 5.1 macOS

macOS uses a native consent sheet attached to the active terminal window, modeled after `macos/Sources/Helpers/PermissionRequest.swift` and clipboard confirmation flows.

### 5.2 GTK

GTK uses a modal dialog attached to the active `Window` object, following the same semantics and cached decision model as macOS.

## 6. Error Handling

This section defines the major policy failure scenarios.

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| No secret can be resolved for the selected provider | Secret resolver returns `SecretUnavailable` | Present provider repair flow and keep request locally editable |
| System secret storage is unavailable | Platform adapter reports unsupported capability | Offer environment-variable setup guidance and keep AI disabled by default |
| Secure input or password mode is active | `Surface` or native runtime indicates protected mode | Block context transmission and explain why the action is unavailable |
| A redaction rule fails to compile or apply | Redaction engine returns `RedactionFailed` | Reject send, surface configuration error, and log sanitized diagnostics |
| User denies a one-time approval | Consent prompt returns denial | Cancel the request without persisting any context |
| Context exceeds the hard maximum | Byte accounting exceeds `ai-max-context-bytes` | Force user review and require explicit trimming before send |

## 7. Security Considerations

This section defines the security posture of the policy layer.

The fork treats terminal-derived context as sensitive by default. Scrollback and environment variable transmission are denied until explicitly enabled. Secure input and password prompt states are hard stops, not warnings. Provider tokens never appear in logs, crash reports, or review buffers. Any future telemetry defined by RFC-006 must be aggregated and content-free by default.

## 8. Migration and Packaging

This section defines how the policy layer fits into distribution and upgrades.

Downstream packages must not depend on live network access to build the AI feature set. Packaging retains the existing Ghostty offline-cache build model described in `PACKAGING.md`. Provider credentials are runtime state and must never be embedded in packages, examples, or release artifacts.

## 9. Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| Store the OpenRouter key directly in `config` | It would normalize plaintext secret handling and make accidental leakage likely. |
| Default all context scopes to `allow` after the user enables AI | It would trade convenience for unsafe silent data transfer. |
| Use a single consent toggle for all context types | It would hide material differences between selection, viewport, scrollback, and environment data. |

## 10. Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the default posture for sensitive context? | **Deny or ask, never implicit allow.** This matches a security-first terminal product. |
| 2 | How are provider secrets stored in production? | **Use native platform secret stores first.** Environment variables remain a fallback and plaintext files are development-only. |
| 3 | What happens when secure input is active? | **AI context transmission is blocked.** Protected input is treated as a hard boundary rather than an informational warning. |
