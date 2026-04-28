# Workspace Templates for OpenClaw Mode

## Problem

When cc-monitor is installed in OpenClaw (龙虾) mode, `setup_openclaw_subagent()` creates the agent and binds channels, but the workspace directory is empty. The sub-agent has no instructions on how to operate — it doesn't know how to scan tmux sessions, forward messages, write marker files, or handle the monitoring infrastructure.

## Solution

Add template files to `cc-monitor/templates/` and a JSON manifest that get written to the OpenClaw workspace during installation. Templates describe **intent and principles**, not rigid scripts. The manifest provides deterministic config paths so the agent never has to guess.

## Files

```
cc-monitor/templates/
  agents.md      — Message routing, session scanning, prohibited behaviors (required)
  tools.md       — tmux conventions, marker file contract, monitoring hook reference (required)
  soul.md        — Behavioral principles: fidelity, no improvisation (recommended)
  identity.md    — Agent role stub (only created if absent)
  user.md        — User profile stub (only created if absent)
```

## Design Principles

1. **Describe intent, not implementation.** The sub-agent is an AI. Say "forward messages verbatim without modification" rather than providing exact bash commands.

2. **Deterministic entry point via manifest.** Install generates `cc-monitor.workspace.json` containing absolute paths and config values. Templates reference this single file. No `sed` substitution in templates — no escaping issues, no platform differences.

3. **Reference, don't duplicate.** Point to cc-monitor's existing scripts and config rather than copy-pasting their logic.

4. **Graceful degradation.** If the agent can't find a specific config value, it should still function — ask the user, use defaults, or skip optional features.

5. **Respect user customization.** Files carry a managed marker. Never overwrite user-modified files without consent.

## Manifest: cc-monitor.workspace.json

Generated at install time by `jq`, placed in workspace root. Contains only non-sensitive operational values:

```json
{
  "version": 1,
  "ccMonitorDir": "/home/user/cc-monitor",
  "configPath": "/home/user/.config/cc-monitor/config.conf",
  "markerDir": "/tmp/cc-monitor",
  "channelId": "openclaw-weixin",
  "agentName": "cc-monitor"
}
```

Templates reference this file: "Read `cc-monitor.workspace.json` in your workspace root for paths and config."

## Managed Marker

Each template file starts with:

```html
<!-- cc-monitor-managed: workspace-template v1 -->
```

This allows the installer to distinguish cc-monitor-managed files from user-created content.

## File Priority

| File | Priority | Install behavior |
|------|----------|-----------------|
| agents.md | Required | Create or overwrite managed; prompt if user-modified |
| tools.md | Required | Create or overwrite managed; prompt if user-modified |
| soul.md | Recommended | Create or overwrite managed; prompt if user-modified |
| identity.md | Optional | Only create if absent; never overwrite existing |
| user.md | Optional | Only create if absent; never overwrite existing |
| cc-monitor.workspace.json | Required | Always regenerate (derived from config, not user-editable) |

## Rendering Strategy

### During install

In `setup_openclaw_subagent()`, after creating the agent:

1. Determine workspace path from `openclaw agents list` or default `~/.openclaw/workspace/`
2. Generate `cc-monitor.workspace.json` via `jq` (always overwrite — it's derived from config)
3. For each template file:
   - Target doesn't exist → copy from template
   - Target exists with managed marker and content identical → overwrite
   - Target exists with managed marker but content differs → overwrite (template update)
   - Target exists without managed marker (user-created) → skip for optional files; prompt for required files
4. Non-interactive mode: overwrite managed files, skip user-created files, create absent files

### Template content approach

Templates are self-contained markdown files containing:
- Managed marker comment
- Reference to `cc-monitor.workspace.json` for paths
- Principle-based instructions the AI can interpret flexibly
- Prohibitions (what NOT to do) — rigid rules

## Template Content Overview

### agents.md (required)
- Session startup scan procedure
- Message routing rules (send to X, switch to X, forward, reply to Monitor notifications)
- Prohibited behaviors (no prefix, no translation, no session creation/destruction)
- Default values (no default active session, marker target from config)

### tools.md (required)
- tmux conventions (paste-buffer for text, never kill sessions, separate text and Enter)
- Marker file contract (path from manifest, required fields: target, created_at, generation)
- Monitoring hook reference (what cc-monitor.sh handles automatically — no need to poll)
- Reference to manifest for all paths

### soul.md (recommended)
- Behavioral principles: be genuinely helpful, have opinions
- Critical rules for forwarding: verbatim transmission, no prefix, no rewriting
- tmux output must be relayed as-is, no summarization
- Safety boundaries

### identity.md (stub only)
- Minimal role definition: IM ↔ tmux message proxy
- Style: direct, practical

### user.md (stub only)
- Minimal placeholder with comment for user to fill in

## Files Changed

| File | Change |
|------|--------|
| `templates/agents.md` | New — agent instructions template |
| `templates/tools.md` | New — tools and conventions template |
| `templates/soul.md` | New — behavioral principles template |
| `templates/identity.md` | New — identity stub |
| `templates/user.md` | New — user profile stub |
| `install.sh` | Add `generate_workspace_manifest()` and `render_workspace_templates()` to `setup_openclaw_subagent()` |
| `install.md` | Add workspace template generation step |
| `README.md` | No change (templates are internal to install flow) |

## Out of Scope

- Sub-agent memory or conversation history management
- Dynamic template updates after installation
- Multi-language templates
- Template validation beyond basic file existence
