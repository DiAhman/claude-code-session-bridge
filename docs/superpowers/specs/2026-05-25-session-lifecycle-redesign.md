# Session Lifecycle Redesign

**Status:** Spec — design agreed, plan not yet written.
**Date:** 2026-05-25
**Supersedes:** Aspects of the cleanup behavior shipped in v0.2.22 (stale-prune at 30 min, `cleanup.sh` doing three jobs in one script).

## Problem Statement

A user-reported friction: when a specialist session crashes, is `/exit`-ed, or is otherwise interrupted mid-conversation, restarting it produces a brand-new session ID. The orchestrator's pending messages addressed to the prior ID are orphaned, conversation threads referencing that ID become stale, and the user has to manually backtrack and reorient the orchestrator to the new identity.

Investigation showed the code *does* try to persist session IDs across restarts (`project-join.sh:65-103` reuses if `.claude/bridge-session` + session dir + manifest are all intact). The persistence breaks under three conditions:

1. **`/bridge stop`** intentionally clears the bridge-session pointer + destroys the session dir.
2. **Stale-session prune** (`cleanup.sh`, current 30-min threshold) destroys session directories whose `lastHeartbeat` is too old — which happens within 30 min of every clean `/exit` because the watcher daemon stops updating.
3. **No distinction between "session offline" and "session broken."** Both are treated as "stale and destroy-eligible."

The underlying design conflates two concepts into one `sessionId`:
- **Logical identity** — "redteam specialist in plextura-suite," a durable role within the project roster.
- **Runtime instance** — a specific Claude Code process serving that identity right now.

This spec separates them. Logical identity persists; runtime instances come and go.

## Design Principles

These were established by user feedback during design discussion and should govern all subsequent implementation decisions:

1. **Persistence is the default.** Logs, archives, conversations, manifests, inboxes, outboxes, and session directories survive indefinitely unless explicitly removed. The user controls disk reclamation; the bridge never auto-deletes anything load-bearing.
2. **Distinguish intent from accident.** Status states must reflect *why* something happened, not just *what* happened. A session that closed cleanly and a session whose process died are different events with different recovery semantics.
3. **Sessions are office staff, not threads.** Most specialist sessions get created once and stay in the project indefinitely. They're opened and closed as needed. Removal is rare. The mental model is hiring/firing employees, not spawning/reaping workers.
4. **The user never touches bridge internals.** Only the orchestrator session calls bridge scripts; the user interacts with the orchestrator (and runs `/bridge standby` on specialists). Design choices that make life easier for hand-typing names while hurting durability are wrong tradeoffs.
5. **The heartbeat is not a token-using activity proxy.** A real heartbeat runs in a background process, on a fixed interval, independent of agent inference. The current `lastHeartbeat` field is a misnamed "last seen" timestamp that any code touching the manifest updates.

## Lifecycle State Machine

```
                    project-join.sh
                   (first-time only)
                          │
                          ▼
                    ┌──────────┐
                    │  active  │
                    └────┬─────┘
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
       │ close-session.sh│                 │ heartbeat producer
       │ (SessionEnd     │ /bridge remove  │ dies while
       │  hook)          │                 │ status=active
       ▼                 ▼                 ▼
  ┌─────────┐       ┌─────────┐       ┌─────────┐
  │ offline │       │ removed │       │  stale  │
  └────┬────┘       └─────────┘       └────┬────┘
       │              (terminal)           │
       │ resume-session.sh                 │ resume-session.sh
       │ (SessionStart hook)               │ (SessionStart hook)
       └─────────────────────┐    ┌────────┘
                             ▼    ▼
                          back to active
```

### State definitions

| State | Meaning | Heartbeat? | Set by |
|---|---|---|---|
| `active` | Runtime alive, heartbeat producer running, hooks firing | Yes, fresh | `project-join.sh` (new) or `resume-session.sh` (revival) |
| `offline` | Cleanly voluntarily closed; heartbeat absence is **expected** | No (absence is correct) | `close-session.sh` on SessionEnd hook |
| `stale` | Was supposed to be active; heartbeat producer died without authorization | No (absence is anomalous) | Heartbeat producer's EXIT trap, OR on-demand stale-detector |
| `removed` | Explicit removal from project; session dir destroyed | N/A | `remove-session.sh` (also rare; terminal) |

### Key invariants

- **`offline` and `stale` are mutually exclusive.** Heartbeat absence in `offline` is expected; in `active` it indicates breakage and triggers transition to `stale`.
- **`/exit` → `offline`** must be a guaranteed path when SessionEnd fires successfully. The user explicitly flagged this: a clean exit while the listener is in background should produce `offline`, never `stale`.
- **`resume-session.sh` is the only path back to `active`.** Both `offline` and `stale` recover the same way: the session resumes (e.g., user resumes the Claude Code conversation, SessionStart hook fires), `resume-session.sh` adopts the existing ID, restarts the heartbeat producer, flips status to `active`.
- **`removed` is terminal.** The session dir is destroyed, peers are notified, and any future re-registration uses a new ID via `project-join.sh`. Rare path.

## Heartbeat Mechanism

The current `lastHeartbeat` field in `manifest.json` is renamed conceptually to "last seen" — an incidental timestamp updated by anything that touches the manifest. It stays for human-readable forensic value but loses its load-bearing role.

The new heartbeat is a **dedicated file with timestamp content**:

```
<session-dir>/heartbeat
```

Content: a single line, ISO 8601 UTC timestamp:
```
2026-05-25T18:14:44Z
```

### Producer

A dedicated background process per session writes the current timestamp to this file every `HEARTBEAT_INTERVAL` seconds (default: 60). Writes use the atomic temp+mv pattern:

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$SESSION_DIR/heartbeat.XXXXXX")
echo "$NOW" > "$TMP" && mv "$TMP" "$SESSION_DIR/heartbeat"
```

**Producer placement decision (open):** the producer can stay coupled to `inbox-watcher.sh` (its current home, which already runs detached and updates every 60s) or split into a sibling `heartbeat-daemon.sh`. The cleaner separation is split; the smaller diff is keep coupled. To be decided at planning time.

**Key constraint:** the producer is a background bash process, not a Claude Code hook. It does NOT consume agent tokens. Each `touch` / `mv` is a single filesystem operation per minute per session.

### Content, not mtime

User's Linux configuration disables mtime updates on the SSDs for wear reasons. The heartbeat signal is the **file content** (the timestamp string), not the inode metadata. Readers `cat` the file and parse the timestamp.

This has a secondary benefit: backing up the heartbeat file for forensic audit (e.g., copying it into `.delivered/`-style archive) preserves the timestamp; an mtime-based scheme would lose the signal on copy.

### Producer's EXIT trap (defensive layer)

The producer installs an EXIT/INT/TERM trap that records its own death and ensures status integrity:

```bash
_on_exit() {
  local CURRENT_STATUS
  CURRENT_STATUS=$(jq -r '.status' "$MANIFEST" 2>/dev/null || echo "")
  case "$CURRENT_STATUS" in
    active)
      _set_status "stale"
      _log "HEARTBEAT_EXIT producer dying unexpectedly (status was active → stale)"
      ;;
    offline|stale|removed)
      _log "HEARTBEAT_EXIT clean (status=$CURRENT_STATUS)"
      ;;
    *)
      _log "HEARTBEAT_EXIT unknown status='$CURRENT_STATUS'"
      ;;
  esac
}
trap _on_exit EXIT INT TERM
```

**Resulting truth table:**

| Death scenario | Pre-trap status | Trap action | Final state |
|---|---|---|---|
| `/exit` → `close-session.sh` flips offline → SIGTERMs producer | offline | no-op | offline ✓ |
| `/exit` → SessionEnd hook misses entirely | active | stale | stale ✓ |
| Producer manually `kill`-ed mid-session | active | stale | stale ✓ |
| `bridge-listen.sh` orphan-sweep matches producer | active | stale | stale ✓ |
| Kernel OOM-kills the producer | active | stale | stale ✓ |
| `/bridge remove` → `remove-session.sh` sets removed → SIGTERMs producer | removed | no-op | removed ✓ |
| `kill -9` (SIGKILL) — can't trap | active | (no trap fires) | falls through to on-demand stale-detector |

The `kill -9` case is handled by belt-and-suspenders: on-demand stale-detection (next section) catches it within `STALE_THRESHOLD` seconds whenever someone reads the manifest.

### Consumer / stale detection

Stale detection is **on-demand, never a sweeper daemon**. Two places do the check:

1. **`send-message.sh`** — before delivering to recipient inbox, read recipient's manifest + heartbeat. If `status=="active"` AND `now - heartbeat_time > STALE_THRESHOLD`:
   - Flip recipient's status to `stale` (atomic manifest write).
   - Still deliver the message normally — recipient's inbox accepts it (hybrid A: guaranteed delivery).
   - Generate a `recipient-stale` notification message back to the sender (hybrid C: sender notification).

2. **`list-peers.sh`** — when called by `/bridge peers` or by the orchestrator's roster scan, perform the same check on every peer. Surface the state in output.

**Thresholds (defaults; configurable):**
- `HEARTBEAT_INTERVAL`: 60s — producer tick rate
- `STALE_THRESHOLD`: TBD at planning time, likely 3-5× HEARTBEAT_INTERVAL (180-300s). User's "office staff" model suggests being lenient here; a specialist quietly idle should not false-positive into stale.

## Script Architecture

`cleanup.sh` is split by intent into four single-purpose scripts. Each script's purpose is honest from its name and never overlaps with another's.

```
plugins/session-bridge/scripts/
  project-join.sh       [REFACTORED — strict, first-time only]
  resume-session.sh     [NEW — SessionStart hook target]
  close-session.sh      [NEW — SessionEnd hook target]
  remove-session.sh     [NEW — /bridge remove command]
  prune.sh              [NEW — /bridge prune maintenance utility]
  cleanup.sh            [DELETED]
  inbox-watcher.sh      [MODIFIED — heartbeat semantics + EXIT trap, OR split]
  send-message.sh       [MODIFIED — stale-detect + recipient-stale notification]
  list-peers.sh         [MODIFIED — stale-detect on read]
```

### project-join.sh

**Purpose:** First-time registration of a session into a project.
**Called by:** `/bridge project join <project>` command (explicit, user/orchestrator-initiated).
**Behavior:**
- Errors if `.claude/bridge-session` already exists in `$PROJECT_DIR` (already a member).
- Errors if a session manifest for this project already references this `PROJECT_DIR` via `projectPath`.
- Mints a new 6-char session ID.
- Writes manifest with `status=active`, role, specialty, name, starts heartbeat producer.
- Writes `.claude/bridge-session` and `.claude/bridge-role` files.
- **No "reuse existing" path.** That logic moves entirely to `resume-session.sh`.

### resume-session.sh

**Purpose:** Re-bind a Claude Code session to its previously-registered bridge identity.
**Called by:** `auto-join.sh` (the SessionStart hook target).
**Behavior:**
- Reads `.claude/bridge-role` for project context (project name, role, specialty, name).
- Reads `.claude/bridge-session` for the previously-assigned session ID.
- Validates that `<bridge>/projects/<project>/sessions/<id>/manifest.json` exists.
- **If valid:** flip status `offline|stale → active`, restart heartbeat producer (if dead), update manifest's "last seen" timestamp, exit with the existing ID.
- **If invalid (session dir gone, manifest missing):** emit a loud error message via systemMessage:
  ```
  === BRIDGE RESUME FAILED ===
  Session XXXXXX no longer exists in project YYYYY.
  This means the session was explicitly removed (/bridge remove)
  or destroyed (long-term cleanup).
  Run: /bridge project join YYYYY
  to re-register with a new ID. Existing conversations addressed
  to the old ID will need to be re-routed.
  === END BRIDGE ===
  ```
  Do NOT silently mint a new ID. The user/orchestrator decides.

### close-session.sh

**Purpose:** Gracefully transition session to `offline`. Non-destructive.
**Called by:** SessionEnd hook (replaces today's `cleanup.sh` invocation).
**Behavior, in order (the order matters — see "race-window safety" below):**
1. Resolve `SESSION_ID` via `BRIDGE_SESSION_ID` env var or `.claude/bridge-session` file.
2. **Atomic manifest write: `status="offline"`.** (Done first to prevent any window where status=active + heartbeat-going-stale could trip stale-detection.)
3. Kill heartbeat producer (PID from `watcher.pid`).
4. Kill listener if running (PID from `bridge-listen-child.pid`).
5. Remove ephemeral runtime PID files (`watcher.pid`, `bridge-listen-child.pid`).
6. Do NOT touch: session directory, manifest beyond status field, `bridge-listen.log`, `<inbox>/.delivered/`, inbox, outbox, conversations, `.claude/bridge-session` pointer.
7. Do NOT notify peers — `status=offline` is visible via `/bridge peers` on demand.

**Race-window safety:** if step 2 happens after step 3, there's a window where producer is dead, status is still `active`, and a concurrent `send-message.sh` or `list-peers.sh` invocation would falsely mark the session `stale`. Step ordering (status first, kill second) closes this window.

### remove-session.sh

**Purpose:** Explicit destructive removal of a session from a project. Rare operation.
**Called by:** `/bridge remove <session-id>` or `/bridge remove --name <name>` command.
**Behavior:**
- Atomic manifest write: `status="removed"`.
- Kill heartbeat producer, listener, watcher.
- Notify project peers with a new `session-removed` message type (distinct from today's `session-ended`).
- Resolve any open conversations initiated by this session (status → resolved with reason "session removed").
- `rm -rf <session-dir>`.
- Remove `.claude/bridge-session` and `.claude/bridge-role` from the target project's directory.

### prune.sh

**Purpose:** Operator-controlled disk maintenance. Never automatic.
**Called by:** `/bridge prune` command with flags.
**Behavior:**
- Accepts flags: `--delivered [DAYS]`, `--outbox [DAYS]`, `--conversations [DAYS]`, `--logs [DAYS]`, `--all [DAYS]`.
- Default thresholds are **generous** (7+ days). Operator can override.
- Without flags, prints a dry-run summary of what would be pruned.
- Never prunes manifests, inboxes, heartbeat files, or session directories.

### Hook config changes

`plugins/session-bridge/hooks/hooks.json`:

```diff
   "SessionStart": [{"matcher": "", "hooks": [{
-    "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/auto-join.sh\""
+    "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/auto-join.sh\""
   }]}]
   "SessionEnd": [{"matcher": "", "hooks": [{
-    "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh\""
+    "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/close-session.sh\""
   }]}]
```

`auto-join.sh` internally swaps its delegation from `project-join.sh` to `resume-session.sh`.

## New Message Type: `recipient-stale`

When `send-message.sh` detects a stale recipient at delivery time, it emits a synthetic message back to the sender:

```json
{
  "id": "msg-XXXXX",
  "type": "recipient-stale",
  "from": "<recipient-id>",
  "to": "<original-sender-id>",
  "timestamp": "2026-05-25T18:14:44Z",
  "status": "pending",
  "content": "Recipient redteam (xy12ab) is unresponsive. Last heartbeat: 2026-05-25T17:42:08Z (32 minutes ago). Message msg-AAAAA was still delivered to recipient's inbox — it will be processed when the session revives. You may want to nudge the user to reopen the session.",
  "metadata": {
    "fromProject": "<project>",
    "originalMessageId": "msg-AAAAA",
    "staleRecipientId": "xy12ab",
    "staleRecipientName": "redteam",
    "lastHeartbeat": "2026-05-25T17:42:08Z",
    "staleSince": "2026-05-25T17:47:08Z"
  }
}
```

**Orchestrator skill update:** add `recipient-stale` to the special-handling list in `SKILL.md`. Surface format:

```
⚠ recipient-stale: redteam (xy12ab) unresponsive since 17:42 — msg-AAAAA queued, may need user nudge
```

This is the user-visible signal that intervention may be needed. The orchestrator does NOT auto-retry, auto-reroute, or auto-escalate — it surfaces the state and waits.

## Backward Compatibility

This is a structural refactor. The protocol version stays at 2.0 (no breaking wire-format changes), but on-disk state representation changes:

| Migration concern | Handling |
|---|---|
| Existing v0.2.22 sessions have no `heartbeat` file | On first read where `heartbeat` is missing, treat heartbeat as "fresh" (don't flip to stale based on absence alone). The next producer tick creates the file. |
| Existing manifests have no explicit `status` field for offline (they only ever say `active` or are deleted) | Treat missing `status` as `active`. Defensive default. |
| Existing `.claude/bridge-session` pointers may reference now-deleted session dirs | `resume-session.sh` errors loudly as designed. User runs `/bridge project join` to reset. |
| `/bridge stop` command behavior change | `/bridge stop` is renamed-or-deprecated. New commands: `/bridge close` (manual offline transition, same as SessionEnd hook) and `/bridge remove` (destructive). Keep `/bridge stop` as alias for `/bridge close` for one minor version, then remove. |
| `cleanup.sh` is referenced in tests, CLAUDE.md, README | Update references during the implementation pass; delete `cleanup.sh` itself; rewrite affected tests against the new scripts. |
| v0.2.22 `.delivered/` archive policy (24h auto-prune) | Removed. `.delivered/` grows until `/bridge prune --delivered N` is run. Documented in CLAUDE.md and release notes as a deliberate policy shift toward persistence-first. |

## Non-Goals

- **Cross-machine session migration.** Sessions remain tied to the machine they were created on. The bridge is single-host by design.
- **Automatic recovery from `stale`.** The orchestrator does not auto-restart specialists or auto-reroute messages. The user is the recovery actor; the system just surfaces what needs attention.
- **Configurable heartbeat per session.** One global `HEARTBEAT_INTERVAL` and `STALE_THRESHOLD` for the project. Per-session tuning is out of scope.
- **Heartbeat that proves the agent's inference loop is alive.** Heartbeat proves the bridge daemon process is alive, which is a weaker but cheaper signal. The on-demand stale-detector + the EXIT trap catch the daemon-died-while-agent-alive case correctly.
- **`stale` self-healing without operator action.** If a specialist's heartbeat producer dies and the agent is still technically alive but not running the bridge plumbing, only resuming the Claude Code session (running through SessionStart → resume-session.sh) restores the heartbeat. There is no in-band "ping to wake up the daemon" mechanism.

## Open Questions

To resolve at planning time:

1. **Heartbeat producer placement.** Stay coupled to `inbox-watcher.sh` (smaller diff, slight role overload) or split into `heartbeat-daemon.sh` (cleaner, two new files instead of one)?
2. **`STALE_THRESHOLD` default.** The user's "office staff" model suggests being lenient. Candidates: 180s (3× interval), 300s (5×), 600s (10×). Propose 300s.
3. **`recipient-stale` payload schema.** The sketch above is a starting point. Confirm exact field names before implementation.
4. **`/bridge stop` → `/bridge close` rename strategy.** Keep alias for one version, hard-deprecate immediately, or leave `/bridge stop` permanently as alias?
5. **Stale check on the orchestrator's `check-inbox.sh`?** If yes, every PostToolUse hook scans all peers for staleness — more responsive surfacing of staleness, but reads all manifests every tool call. Probably no, but worth considering.
6. **What happens if `resume-session.sh` finds the bridge-session pointer but the manifest is corrupted (jq parse fails)?** Treat as "session lost" and emit the same loud error? Or attempt manifest recovery from project-level state?

## Acceptance Criteria

When this is shipped, the following must all be true:

- [ ] A specialist session `/exit`-ed mid-conversation produces `status=offline` (verified via cat of manifest after exit).
- [ ] Re-opening the same Claude Code conversation (resume) revives the session with the same ID and flips `status=active`.
- [ ] Pending messages addressed to the previously-offline session sit in its inbox and get delivered when the session revives.
- [ ] Conversations referencing the session ID are intact after offline/revive cycle (no orphaning).
- [ ] An orchestrator sending to a session whose heartbeat went silent > `STALE_THRESHOLD` ago gets back a `recipient-stale` notification on its next turn.
- [ ] `/bridge peers` output distinguishes `active`, `offline`, and `stale` cleanly.
- [ ] No automatic destruction of session directories, logs, conversations, archives, or inboxes.
- [ ] `/bridge remove <session>` is the only path that destroys a session, and it requires explicit user invocation (or orchestrator with explicit reasoning).
- [ ] Heartbeat file is written via content, not mtime, and is readable via `cat <session>/heartbeat`.
- [ ] Producer EXIT trap correctly transitions `active → stale` on unexpected death; correctly no-ops on planned death.
- [ ] All existing tests (post-v0.2.22 count: 365) pass after refactor. New tests cover the lifecycle state machine, heartbeat semantics, and `recipient-stale` flow.
