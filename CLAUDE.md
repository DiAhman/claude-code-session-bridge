# Claude Code Session Bridge

Fork of `PatilShreyas/claude-code-session-bridge` — peer-to-peer communication between Claude Code sessions.

## Project Structure

```
plugins/session-bridge/
  .claude-plugin/plugin.json     # Plugin manifest (currently v0.2.21)
  commands/bridge.md             # /bridge command definition
  hooks/hooks.json               # SessionStart, UserPromptSubmit, PostToolUse, PreCompact, Stop, SessionEnd hooks
  skills/bridge-awareness/SKILL.md  # Agent behavior skill
  scripts/                       # Core bash scripts (18 scripts, ~1985 lines)
  tests/                         # Test suite (22 test files, ~2773 lines, 353 tests)
  test.sh                        # Test runner
```

## Versioning

Semantic versioning: `0.MINOR.PATCH`. Currently on `0.2.x`.

- **Patch bump** (`0.2.x → 0.2.x+1`): bug fixes, new scripts, test additions, doc updates
- **Minor bump** (`0.2.x → 0.3.0`): breaking protocol changes, new message types that break backward compat
- **Do NOT bump major** until user says so

Version lives in `plugins/session-bridge/.claude-plugin/plugin.json`. Bump it on every commit that changes runtime behavior (scripts, hooks, commands, skill). Don't bump for test-only or doc-only changes.

## Development

### Running Tests

```bash
cd plugins/session-bridge && bash test.sh
```

All tests must pass before committing. Tests use isolated temp directories and clean up after themselves.

### Key Patterns

- Scripts use `set -euo pipefail` and require `jq`
- Atomic file writes: write to temp file + `mv` (prevents partial reads)
- Session IDs: 6-char alphanumeric from `/dev/urandom`
- Message IDs: `msg-` prefix + 12-char alphanumeric
- Date format: ISO 8601 UTC (`date -u +"%Y-%m-%dT%H:%M:%SZ"`)
- macOS + Linux compat: try BSD `date` first, GNU fallback
- Tests source `tests/test-helpers.sh` for assertions
- Each test file is standalone, uses `TEST_TMPDIR` with trap cleanup

### Bridge Directory

Runtime data lives at `~/.claude/session-bridge/` (not in the repo). Tests override with `BRIDGE_DIR` env var pointing to temp dirs.

### Git Remotes

- `origin`: `DiAhman/claude-code-session-bridge` (our fork)
- `upstream`: `PatilShreyas/claude-code-session-bridge` (original)

## Bidirectional Bridge v2 (shipped)

The bidirectional, project-scoped, autonomous multi-session orchestration system is implemented and stable as of v0.2.21. Protocol version: **2.0**.

- **Spec** (historical): `docs/superpowers/specs/2026-03-19-bidirectional-bridge-design.md`
- **Plan** (historical): `docs/superpowers/plans/2026-03-19-bidirectional-bridge.md`
- **Future direction (not yet implemented)**: `docs/superpowers/specs/2026-04-22-departments-hierarchy-brainstorm.md` — a 3-layer (orchestrator → lead → specialist) hierarchy for projects with many specialists.

### v2 Key Concepts

- **Projects** group sessions (`~/.claude/session-bridge/projects/<name>/`)
- **Conversations** thread messages with state tracking (open/waiting/resolved); chained via `parentConversation`
- **Three-path message delivery**:
  - `Stop` hook drains queues at turn boundaries (with safety cap)
  - `UserPromptSubmit` + rate-limited `PostToolUse` deliver during active work
  - `bridge-listen.sh` blocks at zero CPU (`inotifywait`/`fswatch`/poll fallback) when idle
- **Auto-join**: `SessionStart` hook reads `.claude/bridge-role` and rejoins project automatically
- **Standby concurrency**: `flock` ensures only one listener per session; `BRIDGE_STATUS=` markers (delivered / already_running / timeout) let the agent reason about listener state without spurious relaunches
- **Visibility lines**: agents emit `← <type> from <project>: <one-sentence summary>` then `→ standby` after each handled message — keeps the transcript readable during bursts
- **Human-in-the-loop**: `human-input-needed` messages with `proposedDefault` and `blocksWork`

### v2 Backward Compatibility

Legacy ad-hoc bridges (`/bridge start` + `/bridge connect`) still work via the flat `sessions/` directory. The project system is opt-in.

## Local Plugin Cache Quirk

Claude Code snapshots directory-source plugins into `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` at install time. Local edits to this repo's `plugins/session-bridge/` do **not** propagate to running sessions until the snapshot is refreshed. When developing this plugin against your own Claude Code, replace the snapshot directory with a symlink to `plugins/session-bridge/` and update `~/.claude/plugins/installed_plugins.json` to point at the symlink path. See README "Developing Against a Local Checkout" for the exact commands.

## Prerequisites

- `jq` (JSON processing)
- `inotify-tools` (provides `inotifywait` for zero-CPU filesystem watching on Linux)
  - Install: `sudo apt install inotify-tools`
  - macOS alternative: `fswatch`
  - Fallback: polling with `sleep` if neither available
