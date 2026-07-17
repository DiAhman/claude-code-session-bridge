# Claude Code Session Bridge

Fork of `PatilShreyas/claude-code-session-bridge` — peer-to-peer communication between Claude Code sessions.

## Project Structure

```
plugins/session-bridge/
  .claude-plugin/plugin.json     # Plugin manifest (currently v0.3.0)
  commands/bridge.md             # /bridge command definition
  hooks/hooks.json               # SessionStart, UserPromptSubmit, PostToolUse, PreCompact, Stop, SessionEnd hooks
  skills/bridge-awareness/SKILL.md  # Agent behavior skill
  scripts/                       # Core bash scripts (25 scripts + lib/stale-check.sh, lib/path-resolve.sh, lib/find-open-conversation.sh)
  tests/                         # Test suite (~35 test files, ~610 tests)
  test.sh                        # Test runner
```

## Versioning

Semantic versioning: `0.MINOR.PATCH`. Currently on `0.3.x`.

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

The bidirectional, project-scoped, autonomous multi-session orchestration system is implemented and stable as of v0.3.0. Protocol version: **2.0**.

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
- **Session lifecycle**: each session has a four-state machine — `active` (heartbeat producer alive), `offline` (cleanly `/bridge close`-ed or `/exit`-ed), `stale` (was supposed to be active but heartbeat went silent), `removed` (explicit `/bridge remove`, destructive). Recovery on resume is automatic: SessionStart hook → `resume-session.sh` adopts the existing ID, restarts the heartbeat-daemon, flips status back to `active`. No more silent ID changes on restart.
- **Persistence-first cleanup**: nothing is auto-deleted — `bridge-listen.log`, `<inbox>/.delivered/`, conversations, manifests, inboxes, outboxes all survive indefinitely. Disk maintenance is operator-controlled via `/bridge prune --delivered N --outbox N --conversations N --logs N`.
- **Stale detection**: on-demand only (during `send-message.sh` delivery and `/bridge peers` listing). Uses `<session-dir>/heartbeat` file content + PID-liveness check on `heartbeat-daemon.pid`. PID-liveness backstop prevents false positives across laptop sleep/wake.
- **`recipient-stale` notification**: sending to a stale recipient still delivers the message (it queues in the inbox) AND emits a `recipient-stale` notification back to the sender so the orchestrator surfaces the unresponsive state to the user.
- **Lifecycle flag (`manifest.lifecycle`)** — additive field separate from `status`. Values: `normal` (default) or `compacting`. `PreCompact` hook flips it to `compacting`; the first `UserPromptSubmit` after compaction (via `clear-compacting.sh`, wired BEFORE `check-inbox.sh`) flips it back to `normal`. `list-peers.sh` surfaces `active (compacting)`; `send-message.sh` emits a once-per-60s stderr warning when a recipient is mid-compaction.
- **Heartbeat-on-traffic + self-heal** — `send-message.sh` and `bridge-listen.sh` call `write_heartbeat` on every successful message exchange (best-effort, never blocks delivery). `send-message.sh` also calls `ensure_producer_alive` which detached-relaunches a dead `heartbeat-daemon.sh` via `setsid nohup … </dev/null >/dev/null 2>&1 &`. Liveness is now ground truth, not a sidecar guess.
- **`/bridge inbox [<session>]` triage subcommand** — operator + agent visibility into pending/delivered messages for any peer in the same project. Backed by `scripts/list-inbox.sh`, gated by `assert_same_project` so cross-project enumeration is refused. Supports `--pending|--delivered|--all`, `--since <duration>`, `--json`, `--limit N`.
- **Conversation auto-resume-or-create** — `send-message.sh` without `--conversation` now calls `find_open_conversation <sender> <recipient> <project>`. Single open match → silently attaches and emits stderr `auto-attached to <conv-id>`. Zero matches → creates fresh conversation. Multiple matches → refuses with stderr `Multiple open conversations: <id1> <id2>` (exit 2) so the operator picks explicitly.
- **Standby double-fork guard** — `bridge-listen.sh` refuses to start when (a) `$PPID` is dead/zombie AND (b) `/proc/$PPID/cmdline` matches `^bash -c .* &$`. Operator escape hatch: `BRIDGE_INTENTIONAL_DOUBLE_FORK=1`. Prevents the runaway-listener footgun without disturbing normal Claude Code launch.
- **Plaintext persistence** — all bridge files (`<inbox>/*`, `outbox/*`, `conversations/*`, `bridge-listen.log`) are plaintext JSON on local disk under `~/.claude/session-bridge/`. Do NOT send secrets, credentials, API keys, or PII through the bridge. See SKILL.md for the operator-facing warning.

### v0.3.3 patch — hook context delivery + inbox drain (shipped)

- **#28 fix**: `check-inbox.sh` Default mode now emits via `hookSpecificOutput.additionalContext` with dynamic `hookEventName` (UserPromptSubmit or PostToolUse) — reaches the model. Previously used `systemMessage` which is terminal-only, causing silent message loss on the PostToolUse path. Archival is now gated on emission success (via `EMIT_SUCCESS` flag) so a failed emit leaves the message `pending` for the next hook to retry rather than silently losing it.
- **#27 fix (architectural)**: SessionStart hook chain now runs `check-inbox.sh --drain`, surfacing each pending message individually as actionable turn-input on cold-start. `bridge-listen.sh` refuses launch with `BRIDGE_STATUS=pending_messages` when the caller's inbox has pending items — closes the loop so the plumbing enforces the drain-before-standby invariant (v0.3.2 shipped the SKILL.md guidance as interim mitigation). Escape hatch: `BRIDGE_STANDBY_IGNORE_PENDING=1`.
- **PreCompact bloat filter**: `check-inbox.sh --summary-only` now skips conversations older than 30 days by default (`--stale-conv-days N` override; 0 disables). Prevents accumulated long-tail "waiting" threads from dominating PreCompact context on every `/compact`. Filter falls back to `.createdAt` when `.lastActivity` is unset (the schema doesn't populate `.lastActivity` yet).
- **Summary-only note**: v0.3.3 also confirmed via decompiled Claude Code source that PreCompact's hook executor uses raw stdout as literal "compaction instructions" and never parses `hookSpecificOutput` or `.systemMessage`. The JSON emission Summary-only mode uses is thus interpreted as instructions rather than displayed context. The `--stale-conv-days` filter still meaningfully reduces the size of that stdout blob; reshaping the emission format to clean summary text is scoped as a v0.3.4 candidate.

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
