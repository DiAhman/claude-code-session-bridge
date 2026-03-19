# Bidirectional Session Bridge with Project Orchestration

**Date:** 2026-03-19
**Status:** Approved (design phase)
**Protocol Version:** 2.0
**Scope:** Replace the one-directional listen/ask model with fully bidirectional, project-scoped, autonomous multi-session orchestration.

## Problem

The current session bridge has a fundamental limitation: `/bridge listen` puts a session into a blocking listener mode where it can only answer queries. Asking sessions can only ask. Communication is one-directional — one side must be dedicated to listening while the other asks. Two sessions cannot collaborate as equals, and there is no support for multi-session orchestration, task delegation chains, or autonomous inter-session coordination.

## Goal

Enable fully bidirectional communication between Claude Code sessions with:

- **Project-scoped session groups** — sessions belong to named projects, isolated from each other
- **Role-based routing** — sessions register with specialties, queries route to the right peer
- **Autonomous task delegation chains** — orchestrator assigns work, specialists escalate to each other, results roll back up
- **Minimal user intervention** — sessions coordinate autonomously; the user interacts through one cockpit session
- **Human-in-the-loop for decisions** — agents escalate design choices and ambiguous requirements to the user rather than guessing

### Target Scenario

User creates GitHub issues. Orchestrator session sees them and assigns each to the right specialist session. A specialist working on an issue discovers a bug in the shared framework. It hands off to the framework session. The framework session traces the root cause to the auth server. The auth server session fixes it and reports back. The fix cascades back up the chain — framework adapts, original specialist finishes the issue, orchestrator updates and closes the GitHub issue. All without the user switching terminals.

---

## Section 1: Project & Session Structure

### Directory Layout

Sessions are grouped under named projects instead of a flat global list:

```
~/.claude/session-bridge/
  projects/
    plextura-suite/
      project.json
      conversations/
        conv-<id>.json
      sessions/
        <session-id>/
          manifest.json
          inbox/
          outbox/
          watcher.pid
    website-redesign/
      project.json
      conversations/
      sessions/
        ...
  sessions/                            # Legacy flat structure for ad-hoc bridges
    ...
```

### project.json

Created by the first session (typically the orchestrator). Contains project metadata and optional topology routing hints.

```json
{
  "projectId": "plextura-suite",
  "name": "Plextura Suite Development",
  "createdAt": "2026-03-19T...",
  "createdBy": "q7w4r2",
  "topology": {
    "auth-server": { "routes": ["framework", "dev"] },
    "framework": { "routes": ["auth-server"] }
  }
}
```

The `topology` field provides orchestrator-defined routing hints keyed by **project name** (the `projectName` field in each session's manifest, derived from the working directory basename). Project names are stable across session restarts, unlike session IDs which are ephemeral. Optional — sessions without explicit routes fall back to specialty matching.

### Enhanced manifest.json

Each session registers with its role and specialty:

```json
{
  "sessionId": "f8k2m1",
  "projectId": "plextura-suite",
  "projectName": "auth-server",
  "projectPath": "/home/me/projects/auth-server",
  "role": "specialist",
  "specialty": "authentication, authorization, JWT, session management",
  "startedAt": "...",
  "lastHeartbeat": "...",
  "status": "active"
}
```

**Field clarifications:**
- `projectName` — The working directory basename (e.g., `auth-server`). Used for display, topology routing, and peer identification. Must be unique within a project. If two sessions share the same directory name, the second must override via `--name` flag on join.
- `role` — Either `orchestrator` or `specialist`. Determines skill behaviors.
- `specialty` — Free-text description used for automatic peer routing. Agents match problem domains against this string.

### Session States

| State | Meaning | How Set |
|-------|---------|---------|
| `active` | Agent is working (tools running, user interacting) | Any hook fires → set active |
| `idle` | Session open, in standby listen loop | Agent enters bridge-listen.sh standby |
| `offline` | Session ended or crashed | cleanup.sh or no heartbeat for 30+ minutes |

### Peer Discovery

Any session in a project can scan `projects/<projectId>/sessions/*/manifest.json` to see all peers and their specialties. Alternatively, a session can ask the orchestrator "who handles X?" via a `routing-query` message.

### Backward Compatibility

The old flat `sessions/` directory still works for ad-hoc two-session bridges that don't need project scoping. The project system is opt-in.

---

## Section 2: Conversation Protocol

Every exchange between sessions happens within a conversation — a threaded, stateful container that tracks participants, topic, and resolution status.

### Conversation File

Stored at `projects/<projectId>/conversations/conv-<id>.json`:

```json
{
  "conversationId": "conv-a1b2c3",
  "topic": "Bug in user auth flow - issue #123",
  "initiator": "q7w4r2",
  "responder": "f8k2m1",
  "parentConversation": null,
  "status": "open",
  "createdAt": "2026-03-19T...",
  "resolvedAt": null,
  "resolution": null
}
```

### Conversation Statuses

| Status | Meaning | Transitions To |
|--------|---------|---------------|
| `open` | Conversation active, messages flowing | `waiting`, `resolved` |
| `waiting` | Initiator sent a message, awaiting responder's reply | `open`, `resolved` |
| `resolved` | Topic handled, conversation complete | (terminal) |

`waiting` is set automatically when a `query` or `task-assign` is sent. Cleared back to `open` when a `response` arrives. `resolved` is set when `task-complete` or `task-cancel` is sent.

### Pairwise Conversations with Escalation Chains

Conversations are always between exactly two sessions. Escalation creates a new child conversation linked by `parentConversation`:

```
conv-001: Orchestrator <-> Dev        (parent: null)
  conv-002: Dev <-> Framework         (parent: conv-001)
    conv-003: Framework <-> Auth      (parent: conv-002)
```

### Message Types

| Type | Purpose | Conversation Behavior |
|------|---------|----------------------|
| `task-assign` | Orchestrator delegates work | Creates new conversation |
| `query` | Need info or help from peer | Creates new, or sends within existing |
| `response` | Answer to a query | Within existing conversation |
| `escalate` | Route to another specialist | Creates new child conversation (sets `parentConversation`) |
| `task-complete` | Work done, here's the result | Resolves the conversation |
| `task-update` | Progress report | Within existing conversation |
| `task-cancel` | Stop current task | Resolves the conversation |
| `task-redirect` | Cancel current + assign new task | See below |
| `human-input-needed` | Decision requires human judgment | Within existing conversation |
| `human-response` | Human's answer to a decision | Within existing conversation |
| `routing-query` | "Who handles X?" (ask orchestrator) | `conversationId` is null |
| `ping` | Connection check | `conversationId` is null |
| `session-ended` | Cleanup notification | `conversationId` is null |

**`task-redirect` semantics:** This is a compound action. The sender sends a `task-redirect` message carrying the OLD `conversationId` (which resolves it) and includes the new task details in `content`. The receiving agent is responsible for creating a new conversation for the new task via `conversation-create.sh`. This keeps the protocol simple — the redirect message closes one door, the receiver opens the next.

**`conversationId` nullability:** Messages that operate outside of conversations (`routing-query`, `ping`, `session-ended`) set `conversationId` to `null`. All other messages MUST include a valid `conversationId`. The `send-message.sh` script validates this: if the message type requires a conversation and `conversationId` is null, it exits with an error.

### Enhanced Message Format

```json
{
  "protocolVersion": "2.0",
  "id": "msg-abc123def456",
  "conversationId": "conv-a1b2c3",
  "from": "f8k2m1",
  "to": "p3x9n7",
  "type": "task-complete",
  "timestamp": "...",
  "status": "pending",
  "content": "Fixed JWT validation. Changed validateToken() to reject expired refresh tokens.",
  "inReplyTo": "msg-xyz789",
  "metadata": {
    "urgency": "normal",
    "fromProject": "auth-server",
    "fromRole": "specialist"
  }
}
```

### Message Urgency Levels

| Urgency | Behavior |
|---------|----------|
| `normal` | Picked up on next hook cycle, handled after current work |
| `high` | Picked up on next hook cycle, agent prioritizes over current work |
| `critical` | Hook bypasses rate limiting, system message tells agent to stop and handle immediately |

### Resolution Rollup

When a conversation chain resolves, results flow back up:

1. Auth fixes bug → sends `task-complete` to Framework → conv-003 resolved
2. Framework adapts → sends `task-complete` to Dev → conv-002 resolved
3. Dev finishes issue → sends `task-complete` to Orchestrator → conv-001 resolved
4. Orchestrator updates GitHub issue

Each `task-complete` carries a summary of what was done so the receiving session has enough context to continue without follow-up questions.

### Multi-Turn Within a Conversation

If a response isn't sufficient, the receiver sends another `query` within the same `conversationId`. The conversation stays `open` until someone sends `task-complete` or both sides agree it's resolved.

### Conversation Creation and Race Conditions

Only the **initiator** creates a conversation via `conversation-create.sh`. The responder never creates one — it sends messages within the existing `conversationId` from the received message.

If two sessions simultaneously send queries to each other about the same topic, two separate conversations are created. This is correct behavior — they are independent requests that happen to overlap. Each conversation resolves independently. The skill teaches agents to check for existing open conversations with a peer before creating a new one, reducing (but not eliminating) duplicates.

---

## Section 3: Hook-Driven Communication

Replaces the blocking `/bridge listen` loop. Every session is always reachable — messages are picked up passively through hooks during active work, and through a standby listen loop during idle time.

### Two Hooks, Two Triggers

| Hook | Fires When | Purpose |
|------|-----------|---------|
| `UserPromptSubmit` | User presses Enter | Immediate inbox check |
| `PostToolUse` | Agent finishes any tool call | Catches messages during autonomous work |

### Rate Limiting for PostToolUse

The `--rate-limited` flag controls whether `check-inbox.sh` applies rate limiting:

- **Without flag** (`UserPromptSubmit`): Always runs a full inbox scan immediately.
- **With `--rate-limited`** (`PostToolUse`): Checks a timestamp file first. If fewer than 5 seconds have passed since the last scan, exits early with `{"continue": true}`. Exception: if any file in the inbox is newer than the timestamp file AND contains `"urgency":"critical"`, the rate limit is bypassed.

**Early exit for non-bridge sessions (B5):** Before any inbox scanning, `check-inbox.sh` checks whether this session has a bridge registration. It looks for a `.claude/bridge-session` file in the project directory, or checks `$BRIDGE_SESSION_ID` in the environment. If neither exists, it exits immediately with `{"continue": true}`. This means non-bridge sessions pay essentially zero cost from the `PostToolUse` hook — one file existence check per tool call.

```bash
# Early exit: not a bridge session
if [ -z "${BRIDGE_SESSION_ID:-}" ] && [ ! -f "${PROJECT_DIR:-.}/.claude/bridge-session" ]; then
  echo '{"continue": true}'
  exit 0
fi

# Rate limiting (only with --rate-limited flag)
if [ "${1:-}" = "--rate-limited" ]; then
  LAST_CHECK_FILE="$BRIDGE_DIR/.last_inbox_check"
  NOW=$(date +%s)
  LAST=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)

  if [ $((NOW - LAST)) -lt 5 ]; then
    # Check for critical messages only (fast path: scan for urgency string)
    HAS_CRITICAL=$(grep -rl '"urgency":"critical"' "$INBOX"/*.json 2>/dev/null | head -1)
    if [ -z "$HAS_CRITICAL" ]; then
      echo '{"continue": true}'
      exit 0
    fi
  fi

  echo "$NOW" > "$LAST_CHECK_FILE"
fi

# Proceed with full inbox scan...
```

The critical-message fast path uses `grep` instead of `jq` for speed — a simple string match on `"urgency":"critical"` is sufficient to decide whether to bypass the rate limit.

### Updated hooks.json

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh\"",
          "async": false
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh\" --rate-limited",
          "async": false
        }]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh\"",
          "async": false
        }]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh\" --summary-only",
          "async": false
        }]
      }
    ]
  }
}
```

**PreCompact behavior:** The `--summary-only` flag outputs a state snapshot that survives context compaction. For project-scoped sessions, this includes: project name, session role/specialty, all active conversations (ID, peer, topic, status), pending `human-input-needed` messages, and the last known state of each peer. This ensures the agent retains orchestration context even after compaction.

### Standby Mode (Idle Sessions)

Sessions that are idle (no active work, waiting for tasks) enter a standby listen loop. The agent runs `bridge-listen.sh` as its last action after completing work. This blocks until a message arrives, then the agent handles it and re-enters standby.

```
Agent completes task
  → sends task-complete
  → checks inbox for queued messages
  → nothing pending? enters bridge-listen.sh (blocks)
  → message arrives → bridge-listen.sh returns
  → agent handles message
  → if new task: works on it, then back to standby
  → if query: answers it, then back to standby
```

`bridge-listen.sh` uses filesystem event watchers for zero-CPU blocking. Platform-specific invocations:

- **Linux:** `inotifywait -t 60 -e create "$INBOX"` — blocks until a new file is created in the inbox directory, or 60 seconds elapse. Exit code 0 = file created, exit code 2 = timeout.
- **macOS:** `fswatch --one-event --latency=0.5 "$INBOX" &` with a background timer that kills it after 60 seconds. `fswatch` has no built-in timeout, so the script manages it.
- **Fallback (neither available):** Poll with `sleep 3` loop up to 60 seconds (current behavior, preserved for compatibility).

Detection order: check `command -v inotifywait`, then `command -v fswatch`, then fall back to polling. The 60-second timeout ensures the agent surfaces between cycles for Ctrl+C opportunities. The Bash tool's own timeout (120s default) provides an outer bound.

The agent is never truly idle at the prompt — it is either working or blocking on `bridge-listen.sh`. Sessions can sit in standby for hours with zero CPU usage and wake instantly when a message arrives.

### Message Flow During Active Work

```
Session A (Dev)                              Session B (Framework)
                                             [working on a task]

1. Sends query to B's inbox
2. Continues own work
                                             3. PostToolUse hook fires
                                             4. check-inbox.sh finds message
                                             5. Agent handles query inline
                                             6. Sends response to A's inbox
                                             7. Resumes its own work

8. Next hook fires
9. check-inbox.sh finds response
10. Agent acts on response, continues
```

### Message Flow to Idle Session

```
Session A (Dev)                              Session B (Framework)
                                             [standby: bridge-listen.sh blocking]

1. Sends query to B's inbox
2. Continues own work (or enters standby)
                                             3. inotifywait detects new file
                                             4. bridge-listen.sh returns message
                                             5. Agent handles query
                                             6. Sends response to A's inbox
                                             7. Re-enters bridge-listen.sh
```

### Interrupt Priority Chain

```
critical bridge message  →  bypasses rate limit, interrupts work
high bridge message      →  next hook cycle, agent reprioritizes
normal bridge message    →  next hook cycle, handled in order
user Ctrl+C              →  breaks current operation, direct interaction
```

### Background Inbox Watcher (Optional Enhancement)

A lightweight background process started by `register.sh` that uses `inotifywait` to watch the inbox directory. When a message arrives while the session is between states (e.g., the agent somehow returned to the prompt without entering standby), it prints a terminal notification:

```
>> Bridge: query from "auth-server" — press Enter to process.
```

Also handles periodic heartbeat updates so idle sessions aren't marked stale. PID stored in `session-dir/watcher.pid`, killed by `cleanup.sh`.

---

## Section 4: Skill & Agent Awareness

The SKILL.md that teaches every agent how to behave in the bridge ecosystem. Replaces the current `bridge-awareness` skill.

### Session Lifecycle

```
Register with role/specialty
        |
        v
Receive task (or user prompt)
        |
        v
   +--- Work on task <------------------+
   |        |                            |
   |        v                            |
   |  Need info/help from peer?          |
   |    YES -> open conversation         |
   |        -> send query                |
   |        -> DECISION POINT:           |
   |          Can proceed without answer?|
   |            YES -> continue task     |
   |              -> response arrives    |
   |                 via PostToolUse hook|
   |              -> integrate answer ---+
   |            NO  -> bridge-receive.sh |
   |              -> blocks up to 90s    |
   |              -> response arrives    |
   |              -> resume task --------+
   |    NO  |
   |        v
   |  Task complete
   |        -> send task-complete
   |        -> check inbox for queued messages
   |        -> handle any pending conversations
   |        v
   |  Enter standby (bridge-listen.sh loop)
   |        |
   |        v
   |  Message arrives
   |        |
   |        v
   |  Handle by type:
   |    task-assign    -> start new task -+
   |    query          -> answer, resume standby
   |    task-cancel    -> acknowledge, resume standby
   |    task-redirect  -> acknowledge, start new task
   |    escalate       -> take ownership, start work
   +-------------------------------------+
```

### Peer Routing Logic

```
Need help from another session?
        |
        v
  Check project.json topology hints
        |
  Found route? --YES--> Send to that peer
        |
        NO
        |
        v
  Scan sessions/*/manifest.json
  Match problem domain against peer specialties
        |
  Found match? --YES--> Send to best match
        |
        NO
        |
        v
  Ask orchestrator via routing-query
        --> Orchestrator responds with peer ID
        --> Send to that peer
```

### Key Agent Behaviors

1. **Always enter standby after finishing work.** Never return to the prompt idle. Run `bridge-listen.sh` in a loop.

2. **Handle incoming messages promptly.** If a hook surfaces a message while mid-task, address it first. For non-critical messages during complex work, send a "busy, will respond shortly" acknowledgment.

3. **Include real code in responses.** When answering a peer's query, read actual files and include relevant code — exact signatures, types, and implementations. Don't paraphrase.

4. **Track your conversations.** Before entering standby, check for open conversations waiting for responses. Mention them in standby messages so context survives compaction.

5. **Escalate, don't guess.** If a query is outside your specialty, escalate to the right peer or ask the orchestrator for routing.

6. **Resolution summaries flow up.** When sending `task-complete`, include enough detail — what changed, which files, what the new API looks like — so the receiver can continue without follow-ups.

### Human-in-the-Loop: Decision Escalation

When an agent hits a decision that requires human judgment (design choices, architecture, feature details, ambiguous requirements), it sends a `human-input-needed` message.

```json
{
  "type": "human-input-needed",
  "urgency": "high",
  "content": "API response format: nested resources (richer, slower) or flat IDs with separate endpoints (faster, more requests)?",
  "metadata": {
    "proposedDefault": "flat IDs — matches existing codebase patterns",
    "blocksWork": false,
    "context": "Working on issue #123, building GET /users/{id}/projects"
  }
}
```

Two fields control the flow:

- **`proposedDefault`** — The agent's best guess with reasoning.
- **`blocksWork`** — Whether the agent can continue with its default or must wait.

Non-blocking decisions: agent continues with its proposed default, flags the assumption in code. If the human later overrides, the agent adjusts.

Blocking decisions: agent enters standby and waits for a `human-response` message before resuming.

**How decisions reach the human:**

The orchestrator collects `human-input-needed` messages from all sessions. They are surfaced through three mechanisms:

1. **`/bridge decisions` command** — The user runs this in the orchestrator session to see the full queue. Added to the command set in Section 5.
2. **`UserPromptSubmit` hook** — When the user types anything in the orchestrator session, `check-inbox.sh` includes pending `human-input-needed` messages in its system message output with a header: `=== DECISIONS AWAITING YOUR INPUT ===`.
3. **`inbox-watcher.sh` terminal notification** — On the orchestrator's terminal, the background watcher prints a distinct notification when `human-input-needed` arrives: `>> DECISION NEEDED from "framework" — run /bridge decisions or press Enter`.

Example output from `/bridge decisions`:

```
3 decisions need your input:

1. [framework] API response format — flat IDs vs nested
   Recommendation: flat IDs. Status: continued with default.

2. [auth-server] JWT expiry — 15min vs 1hr tokens
   Recommendation: none. Status: BLOCKED, waiting on you.

3. [dev] Add rate limiting to new endpoint?
   Recommendation: yes, 100 req/min. Status: continued with default.
```

The user answers in natural language. The orchestrator sends `human-response` messages back to the relevant sessions.

### Orchestrator-Specific Behaviors

Additional guidance for sessions with the `orchestrator` role:

- Parse incoming task requests (from user or external sources) and decompose into subtasks
- Match subtasks to specialist sessions based on topology + specialties
- Track the full conversation tree — know which tasks are pending, blocked, or complete
- When all subtasks in a chain resolve, synthesize results and report to the user
- Handle `routing-query` messages — peers ask "who handles X?" and the orchestrator answers with a `response` message containing the target session ID and project name
- Maintain the human decision queue and surface it when the user interacts

### Orchestrator Failure

If the orchestrator session crashes or ends:

1. **Detection:** Specialist sessions detect via heartbeat — if the orchestrator's `lastHeartbeat` is older than 5 minutes, it's considered down. The skill teaches agents to check orchestrator health before sending `task-complete` messages up the chain.
2. **Behavior:** Specialists pause non-critical work and print a terminal notification: `"Orchestrator appears offline. Pausing task reporting. Current work saved."` They continue any in-progress work that doesn't require orchestrator interaction but do not pick up new tasks.
3. **Recovery:** When the user restarts the orchestrator and it re-joins the project, it scans all conversation files to rebuild state — which tasks are pending, which are complete, which are blocked. Specialists detect the orchestrator is back (heartbeat resumes) and flush any queued `task-complete` messages.
4. **No auto-promotion:** Specialist sessions do not promote themselves to orchestrator. This requires manual intervention — the user restarts the orchestrator session.

---

## Section 5: Commands

Commands handle setup and status. Actual communication happens through natural language processed by the skill.

### Command Set

| Command | Purpose |
|---------|---------|
| `/bridge project create <name>` | Create a multi-session project |
| `/bridge project join <name>` | Join a project with role/specialty |
| `/bridge project list` | List all projects on this machine |
| `/bridge peers` | List sessions in current project with roles/status |
| `/bridge status` | Conversations, pending decisions, message counts |
| `/bridge standby` | Explicitly enter the standby listen loop |
| `/bridge decisions` | Show pending human-input-needed queue (orchestrator) |
| `/bridge stop` | Disconnect, notify peers, cleanup |

### Removed/Replaced Commands

| Old | New |
|-----|-----|
| `/bridge listen` | `/bridge standby` (+ automatic standby via skill) |
| `/bridge connect <id>` | Unnecessary — project members see each other |
| `/bridge start` | `/bridge project join` for project use |
| `/bridge ask <question>` | Natural language via skill (still works as shortcut) |

### Typical Setup Flow

```
Terminal 1 (orchestrator):
> /bridge project create plextura-suite
> /bridge project join plextura-suite --role orchestrator \
    --specialty "task coordination, issue triage"

Terminal 2 (auth server):
> /bridge project join plextura-suite --role specialist \
    --specialty "authentication, JWT, authorization"
> /bridge standby

Terminal 3 (framework):
> /bridge project join plextura-suite --role specialist \
    --specialty "shared libraries, core utilities, database layer"
> /bridge standby

Terminal 1 (user talks to orchestrator):
> Here are today's issues: #123, #124, #125. Assign to the right sessions.
  [Orchestrator analyzes, routes, sends task-assign messages]
  [User walks away — sessions coordinate autonomously]
```

### Backward Compatibility

The old flat `/bridge start` + `/bridge connect <id>` commands still work for quick ad-hoc two-session bridges without project scoping.

---

## Scripts: New and Modified

### New Script Interfaces

**`project-create.sh`** — Create project directory structure and project.json.
```
Usage:    project-create.sh <project-name>
Env:      BRIDGE_DIR (default: ~/.claude/session-bridge)
Creates:  $BRIDGE_DIR/projects/<name>/project.json, conversations/, sessions/
Outputs:  Project name to stdout.
Errors:   Exit 1 if project already exists.
```

**`project-join.sh`** — Register a session within a project. Combines registration + project membership.
```
Usage:    project-join.sh <project-name> [--role <role>] [--specialty "<desc>"] [--name "<name>"]
Env:      BRIDGE_DIR, PROJECT_DIR (default: pwd)
Creates:  Session directory under $BRIDGE_DIR/projects/<name>/sessions/<id>/
          Writes manifest.json with projectId, role, specialty.
          Writes $PROJECT_DIR/.claude/bridge-session with session ID.
          Starts inbox-watcher.sh in background, stores PID in watcher.pid.
Outputs:  Session ID to stdout.
Defaults: --role specialist, --specialty "" (empty), --name basename of PROJECT_DIR.
Errors:   Exit 1 if project doesn't exist.
```

**`project-list.sh`** — List all projects.
```
Usage:    project-list.sh
Env:      BRIDGE_DIR
Outputs:  Table of project names, session counts, creation dates.
```

**`conversation-create.sh`** — Create a conversation file. Called by `send-message.sh` internally when the message type creates a conversation (`task-assign`, `query` without existing conversationId, `escalate`).
```
Usage:    conversation-create.sh <project-id> <initiator-id> <responder-id> <topic> [--parent <conv-id>]
Env:      BRIDGE_DIR
Creates:  $BRIDGE_DIR/projects/<project>/conversations/conv-<id>.json
Outputs:  Conversation ID to stdout.
Atomicity: Writes to temp file + mv, same as other scripts.
```

**`conversation-update.sh`** — Update conversation status. Called by `send-message.sh` internally when message type changes conversation state (`task-complete` → resolved, `task-cancel` → resolved, `query` → waiting).
```
Usage:    conversation-update.sh <project-id> <conversation-id> <new-status> [--resolution "<text>"]
Env:      BRIDGE_DIR
Updates:  status field, resolvedAt (if resolved), resolution (if provided).
Atomicity: jq + temp file + mv.
```

**`inbox-watcher.sh`** — Background process for idle notifications + heartbeat.
```
Usage:    inbox-watcher.sh <session-id> <project-id>
Env:      BRIDGE_DIR
Behavior: Watches inbox directory via inotifywait/fswatch/polling.
          On new file: prints terminal notification to stderr.
          Every 60 seconds: updates lastHeartbeat in manifest.json.
Lifecycle: Started by project-join.sh, PID in watcher.pid, killed by cleanup.sh.
```

### Modified Script Changes

**`send-message.sh`** — New parameters and project-aware path resolution.
```
Usage:    send-message.sh <target-id> <type> <content> [in-reply-to] [--conversation <id>] [--urgency <level>]
Env:      BRIDGE_DIR, BRIDGE_SESSION_ID (required)
New:      --conversation (conversationId), --urgency (normal|high|critical)
          protocolVersion field added to message JSON.

Path resolution (B6): The script reads the SENDER's manifest to find projectId.
  1. If sender has projectId → look for target in $BRIDGE_DIR/projects/<projectId>/sessions/<target>/inbox
  2. If not found in project → fall back to $BRIDGE_DIR/sessions/<target>/inbox (legacy)
  3. If not found in either → exit 1 with "Target session not found"

Conversation auto-management:
  - If type is task-assign/query(new)/escalate AND no --conversation given:
    calls conversation-create.sh, uses returned ID.
  - If type is task-complete/task-cancel:
    calls conversation-update.sh to set status=resolved.
  - If type is query (within existing conversation):
    calls conversation-update.sh to set status=waiting.

Validation:
  - If type requires conversationId (response, task-complete, task-update, task-cancel,
    human-input-needed, human-response) and none is provided or derivable: exit 1.
  - If type is conversation-free (ping, session-ended, routing-query): conversationId set to null.
```

**`check-inbox.sh`** — Rate limiting, early exit, project-scoped scanning.
```
New flags:
  --rate-limited    Apply 5-second rate limit (for PostToolUse hook)
  --summary-only    Output state summary for PreCompact (existing, enhanced)

Early exit: If no BRIDGE_SESSION_ID and no .claude/bridge-session file, exit immediately.

Project-scoped scanning: Reads session's manifest to find projectId.
  Scans only that project's sessions for this session's inbox.
  Falls back to legacy global scan for non-project sessions.

Enhanced --summary-only: Includes project context, active conversations,
  and pending human-input-needed decisions in the summary (for context
  compaction preservation).
```

**`bridge-listen.sh`** — inotifywait/fswatch with timeout.
```
Platform detection: inotifywait (Linux) → fswatch (macOS) → sleep poll (fallback).
Timeout: 60 seconds on all platforms.
  - inotifywait: -t 60 flag (native timeout support)
  - fswatch: background process + sleep 60 + kill (manual timeout)
  - poll: sleep 3 loop up to 60 seconds (existing behavior)

Project-scoped: Reads session manifest to resolve inbox path.
```

**`cleanup.sh`** — Project-aware cleanup.
```
Changes: Handles project-scoped session directories.
  Kills inbox-watcher.sh via watcher.pid.
  Does NOT delete conversation files (they're shared project state).
  Marks session conversations as resolved if session is the initiator
  of any open conversations (prevents orphaned waiting states).
```

**`list-peers.sh`** — Enhanced output.
```
Changes: Groups output by project. Shows role, specialty, status columns.
```

**`get-session-id.sh`** — Extended path search.
```
Changes: After checking .claude/bridge-session and legacy sessions/,
  also scans projects/*/sessions/*/manifest.json for matching projectPath.
```

### Unchanged Scripts

| Script | Notes |
|--------|-------|
| `bridge-receive.sh` | Still works as optional sync wait fallback. Path resolution inherits from session manifest. |
| `heartbeat.sh` | Still works, also supplemented by inbox-watcher.sh. |
| `connect-peer.sh` | Adapted for project-scoped paths, still used for ad-hoc bridges. |
