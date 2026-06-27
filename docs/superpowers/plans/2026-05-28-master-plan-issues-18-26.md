# Master Plan — Session-Bridge Issue Bundle (#18–#26)

> **Status:** Scoped and decisions locked. Awaiting per-phase plans (writing-plans pass per phase).
> **Issues addressed:** GitHub #18, #19, #20, #21, #22, #23, #24, #25, #26 on DiAhman/claude-code-session-bridge
> **Starting from:** v0.3.1 (commit `3edaca6`)
> **Target end state:** v0.5.0
> **Branch:** `next` (long-running) → merge to `main` at each phase tag
> **Strategy:** Back-to-back 3-phase sprint, ~8–10 days

---

## Overview

Three sequenced releases closing 9 GitHub issues filed against v0.3.1:

- **v0.3.2** (patch) — Liveness truth (heartbeat-on-traffic + self-healing daemon), per-peer inbox forensics, conversation-id UX, compaction visibility, listener double-fork guard, plaintext-persistence docs.
- **v0.4.0** (minor) — Routing primitives: multi-recipient broadcast, CC tagging via `recipientRole`, opt-in content redaction. All built on one shared fan-out refactor of `send-message.sh`.
- **v0.5.0** (minor) — Durable file-based deferred dispatch with event-triggered emission, `--blocked-by` sugar, auto-emit hooks, operator visibility.

The bundle is shaped by one hard constraint: the user's plextura-suite deploy (1 orchestrator + 9 specialists) runs LIVE against this repository's `plugins/session-bridge/` via a symlinked plugin cache install. Every commit between green-test boundaries is felt by 10 running sessions. The plan enforces TDD-with-zero-red-commits, prefers extract-helper-then-rewire refactors over in-place rewrites, and gates new behavior behind opt-in flags or safe-default `jq` reads so legacy data continues to work.

## Branch & release strategy

```
main  ─── v0.3.1 ─────────────────────────────► v0.3.2 ───► v0.4.0 ───► v0.5.0
                          │                       ▲           ▲           ▲
                          └── `next` branch ──────┴───────────┴───────────┘
                                  (rolling work)   tag         tag         tag
                                                   +merge      +merge      +merge
```

- `next` branch holds all work-in-progress. Created off `main` at `3edaca6`.
- Pushed to `origin/next` regularly for backup.
- Other downloaders on `main` stay safe at v0.3.1 until each phase ships.
- The user's local symlinked install picks up whatever branch is checked out locally.
- At each phase boundary: tag the commit (`vX.Y.Z`), merge `next → main` (fast-forward or merge commit), push tag + main.
- After v0.5.0 ships, optionally delete `next`.

## Phase index

| # | Version | Bump | Title | Issues | Effort |
|---|---|---|---|---|---|
| 1 | 0.3.2 | patch | Liveness Truth & Forensics | #18, #19, #21-docs, #23, #24, #25 | 3d · ~19 commits |
| 2 | 0.4.0 | minor | Routing Primitives | #20, #26, #21-redaction | 2–3d · ~10 commits |
| 3 | 0.5.0 | minor | Deferred / Event-Triggered Dispatch | #22 | 3–4d · ~23 commits |

---

## Locked design decisions

All 8 open questions resolved.

| # | Topic | Decision |
|---|---|---|
| 1 | Branch strategy | Long-running `next` branch off `main`. Tag + merge at each phase boundary. |
| 2 | `--redact` default (#21) | **OFF**. Conservative pattern set only: `AKIA[0-9A-Z]{16}`, `sk_live_[a-zA-Z0-9]{20,}`, `sk_test_…`, `github_pat_…`, `xoxb-…`. NOT email or JWT (false-positive risk). Document `BRIDGE_REDACT_PATTERNS_FILE` env var for user-supplied additions. |
| 3 | Broadcast on conversation-bearing types (#20) | **Auto-create N conversations**, one per recipient. Each peer gets an independent thread. Token cost is identical to a manual loop. |
| 4 | `--auto-resume` default (#23) | **Default-on** in v0.3.2. Emits stderr `auto-attached to <conv-id>` line for transparency. Matches multi-day cross-conversation workflow. |
| 5 | Double-fork guard (#18) | **Default-on in v0.3.2**. Narrow heuristic: refuse only when (a) `$PPID` is dead/zombie AND (b) `/proc/$PPID/cmdline` matches `^bash -c .* &$` AND (c) `BRIDGE_INTENTIONAL_DOUBLE_FORK=1` env is NOT set (operator escape hatch). Integration test mimics normal Claude Code launch path to prove zero false positive. |
| 6 | Timeout sweep host (#22) | **heartbeat-daemon.sh** with project-level `flock -n projects/<id>/deferred/.sweep-lock` coordination. Fires within ~60s of expiry regardless of session activity. O(1) early-out when `deferred/` doesn't exist. |
| 7 | Deferred outbox semantics (#22) | **Single-source-of-truth per msg-id with in-place lifecycle updates.** Enqueue writes outbox `status="deferred"` + `deferredAt`. Flush updates in-place to `status="sent"` + `deliveredAt`. Expiry: `status="expired"` + `expiredAt`. |
| 8 | Plugin cache version-bump quirk | **Direct-path approach** (`installed_plugins.json` `installPath` → repo dir, not cache). Per-phase verification step at every version-bump commit: confirm `installPath` still points at repo, restore if Claude Code overwrote it. |

## Critique adjustments incorporated

The adversarial review (verdict: "ship-with-noted-adjustments") flagged 15 items. All addressed:

| # | Critique | Resolution |
|---|---|---|
| C1 | `decisions.sh` phantom reference | Project-scope guard codified as `lib/path-resolve.sh:assert_same_project <caller-id> <target-id>`. Used by v0.3.2 WS3 (`list-inbox.sh`) and v0.5.0 WS7 (`list-deferred.sh`). |
| C2 | PreCompact ordering bug | `lifecycle=compacting` is cleared by FIRST `UserPromptSubmit` hook after compaction, NOT by `check-inbox.sh`. New `scripts/clear-compacting.sh` wired into UserPromptSubmit array (before existing check-inbox.sh). Both `pre-compact.sh` and `clear-compacting.sh` are O(1) jq operations with unconditional `exit 0`. |
| C3 | `ensure_producer_alive` fork detachment | Explicit incantation: `setsid nohup bash "$HEARTBEAT_SCRIPT" "$SESSION_DIR" </dev/null >/dev/null 2>&1 &` then `disown $!`. Test asserts: no fd inherited from caller; parent shell exits immediately without hanging; PID file written before relaunch returns. |
| C4 | "Fixes diagnostic gap" overclaims for running orchestrator | Explicit acknowledgment in v0.3.2 release notes: `/bridge inbox` lands for OPERATORS immediately (script change, hot-reloaded via symlink). Agent self-diagnosis behavior change lands only on next `bridge-awareness` skill reload (next `/bridge` invocation or session resume). |
| C5 | `--blocked-by` semantics ambiguity | Explicit definition: `--blocked-by msg-X` is identical to `--on-event message-resolved:msg-X`. The `message-resolved:<id>` event fires when ANY message whose `inReplyTo == msg-X` lands in the recipient's inbox via `send-message.sh`. Includes `response`, `task-update`, `task-complete`, `task-cancel`, `escalate`, `task-redirect`. Documented in `lib/deferred.sh` header + `SKILL.md`. |
| C6 | Reserved `all`/`*` validation | `send-message.sh` accepts these only when (a) in `--to` value or (b) as first positional arg. Validation runs BEFORE recipient-resolution dispatch. Session-id regex tightened to `^[a-z0-9]{6}$` so `all`/`*` can never collide. Docs always show `*` quoted. |
| C7 | `lib/deliver.sh` ownership | Pinned in v0.4.0 design pass. v0.4.0 WS1 extracts `_deliver_one(msg-json, target-inbox, sender-outbox)` into `lib/fanout.sh` as a PURE helper (no notification side effects). v0.5.0 reuses directly + invokes `lib/stale-notify.sh` (hoisted in v0.5.0 WS2). No double extraction. |
| C8 | Broadcast stdout polymorphism | Always emit JSON `{conversationIds: [...], recipients: [{id, status, msgId, conversationId}]}` for ANY send. Single-recipient case: `--legacy` flag (or `BRIDGE_OUTPUT_LEGACY=1` env) restores bare-`MSG_ID` echo for back-compat. Default flips to JSON in v0.4.0; release notes flag prominently. |
| C9 | Existing orphan-killer interaction (`bridge-listen.sh:81-88`) | Double-fork guard runs AFTER orphan cleanup and BEFORE flock acquire. Ordering test pins both paths still work. |
| C10 | `write_heartbeat` monotonicity | Atomic temp+mv pattern means writes don't tear. Test asserts heartbeat timestamp is non-decreasing across 10 concurrent writes (any one write can win; file is always valid). |
| C11 | `conversation-update.sh` auto-emit latency | Shell-out adds ~20–50ms per call. Acceptable for user's ~5 msg/min coordination rate. Wrapped `\|\| true` for non-blocking. Future optimization possible. |
| C12 | Conservative redaction defaults | See locked decision #2 — no email/JWT defaults. |
| C13 | Symlink re-snapshot risk | See locked decision #8 — per-phase verification step. |
| C14 | Re-entrancy in auto-emit | `emit-event.sh` calls `lib/fanout.sh:_deliver_one` directly, NEVER `send-message.sh`. Stale-recipient notifications from deferred flush via `lib/stale-notify.sh` (direct write). No dependency cycle. |
| C15 | Compacting warning noise | `send-message.sh` rate-limits "recipient compacting" stderr warning to once per (sender, recipient) pair per 60s. Tracked via `<sender-session-dir>/.compact-warned-<recipient>` mtime file. |

---

## Phase 1 — v0.3.2: Liveness Truth & Forensics

### Goal

Turn the lifecycle signal from a sidecar guess into ground truth (heartbeat-on-traffic + self-healing daemon + compacting flag). Give operators a per-peer inbox forensics view. Smooth conversation-id UX. Fix the standby double-fork footgun. Document plaintext persistence. All small-effort, low-risk wins.

### Issues addressed

- **#18** — `bridge-listen.sh` double-fork PPID guard + SKILL.md prohibition
- **#19** — Heartbeat written on send/receive + self-heal dead producer
- **#21** (docs portion only) — Plaintext-persistence warning in SKILL.md + bridge.md
- **#23** — Conversation auto-resume-or-create when `--conversation` omitted
- **#24** — `/bridge inbox [<session>]` triage subcommand
- **#25** — Compacting lifecycle flag (separate from `status` four-state)

### Shared infrastructure (lands FIRST)

| Order | Component | Purpose |
|---|---|---|
| 1.1 | `tests/test-helpers.sh` — `setup_project_session` helper | Standardizes the create-bridge-dir + project + session-with-manifest-inbox-outbox-heartbeat dance. Saves ~80 LOC across 5 new test files. |
| 1.2 | `scripts/lib/path-resolve.sh` | Centralizes session-dir / inbox / outbox / project-id resolution (currently duplicated in `send-message.sh:49-67`, `bridge-listen.sh:42-55`, `check-inbox.sh:74-89`). Adds `assert_same_project` for project-scope guard. |
| 1.3 | `scripts/lib/stale-check.sh` extensions | Adds three helpers: `write_heartbeat <session-dir>`, `set_lifecycle <manifest> <value>`, `ensure_producer_alive <session-dir>` (relaunches dead daemon detached). |
| 1.4 | `scripts/lib/find-open-conversation.sh` | Used only by #23 but extracted to keep `send-message.sh` readable. Returns: empty / single-id / multiple-ids-error. |

### Ordered workstreams

| # | Issue | Workstream | Depends on |
|---|---|---|---|
| 1 | infra | `setup_project_session` helper + `lib/path-resolve.sh` + `lib/find-open-conversation.sh` | — |
| 2 | infra | Extend `lib/stale-check.sh` with `write_heartbeat`, `set_lifecycle`, `ensure_producer_alive`. Refactor `heartbeat-daemon.sh` to source the lib. | 1 |
| 3 | #24 | `scripts/list-inbox.sh` + `/bridge inbox [<session>] [--pending\|--delivered\|--all] [--since N] [--json] [--limit N]` subcommand | 1 |
| 4 | #23 | Auto-resume-or-create in `send-message.sh` (default-on, stderr `auto-attached` line) | 1 |
| 5 | #19 | `write_heartbeat` from `send-message.sh` (post-deliver) + `bridge-listen.sh` (post-message). `ensure_producer_alive` self-heal in `send-message.sh`. | 2 |
| 6 | #25 | `pre-compact.sh` (PreCompact hook) + `clear-compacting.sh` (UserPromptSubmit hook, runs BEFORE check-inbox.sh). `list-peers.sh` shows `active (compacting)`. `send-message.sh` emits rate-limited stderr warning. | 2 |
| 7 | #18 | `bridge-listen.sh` PPID double-fork guard (default-on, narrow heuristic, escape-hatch env). SKILL.md prohibition. | 2 |
| 8 | #21-docs | Plaintext-persistence warning paragraph in SKILL.md + bridge.md help. | — |
| 9 | release | Bump `plugin.json` 0.3.1 → 0.3.2. Run full `bash test.sh`. Manual smoke against live install (verify `installPath` intact). Tag `v0.3.2`. Merge `next → main`. | 3–8 |

### Risks

- **R1.1** Production hot path. Mitigation: extract-helper-then-rewire, no in-place rewrites. Existing tests pass UNMODIFIED through refactor commits.
- **R1.2** `write_heartbeat` failure must never fail message delivery. Best-effort `|| true`. Test pins this.
- **R1.3** `ensure_producer_alive` spawn risk. Detachment incantation per C3. Bounded to "at most one per invocation" via flock on `heartbeat-daemon.pid`.
- **R1.4** PPID guard false-positive risk. Narrow heuristic per locked decision #5. Integration test mimics Claude Code launch.
- **R1.5** Auto-resume default-on is hot-path behavior change. Stderr `auto-attached` line emitted on every attach. Skill teaches expectation. Release notes flag prominently.
- **R1.6** PreCompact ordering: `pre-compact.sh` MUST `exit 0` unconditionally so it never blocks `check-inbox.sh --summary-only`.

### Estimate

3 days · ~19 commits · 6 issues addressed · 0 protocol-breaking changes (new `.lifecycle` field is additive with `// "normal"` default).

---

## Phase 2 — v0.4.0: Routing Primitives

### Goal

Land multi-recipient send (`all`/`*`/`--to a,b,c`), recipient-role tagging (`--cc` + `metadata.recipientRole`), and opt-in content redaction (`--redact`) on top of a single shared fan-out refactor of `send-message.sh`. Receiver-side surfaces learn the `recipientRole` distinction.

### Issues addressed

- **#20** — Multi-recipient broadcast
- **#26** — `--cc` + `metadata.recipientRole=primary|cc`
- **#21** (redaction portion) — Opt-in `--redact` with conservative pattern set

### Shared infrastructure (lands FIRST)

| Order | Component | Purpose |
|---|---|---|
| 2.1 | `scripts/lib/fanout.sh` (`_deliver_one`, `expand_recipients`, `parse_csv_recipients`) | Pure-helper home for per-recipient delivery. NO side effects (stale-notif stays in caller's loop body). Reused by v0.5.0. |
| 2.2 | `send-message.sh` per-recipient loop refactor | Convert single-recipient flow into `RECIPIENTS=("$TARGET_ID")` array + loop. Conversation auto-create runs ONCE outside loop for shared `conversationId` (CC) OR loops to create N conversations (broadcast). Existing test-send-message.sh passes UNMODIFIED — proves byte-identical single-recipient case. |
| 2.3 | `scripts/lib/redact.sh` + `lib/redact-patterns.default` | Conservative pattern set per locked decision #2. Default-off; `--redact` opt-in. |

### Ordered workstreams

| # | Issue | Workstream | Depends on |
|---|---|---|---|
| 1 | infra | Refactor `send-message.sh` per-recipient loop + extract `lib/fanout.sh`. Existing test-send-message.sh passes UNMODIFIED. | — |
| 2 | #20 | Broadcast: `all`/`*` (expanded via `list-peers`) + `--to a,b,c`. Auto-create N conversations for conversation-bearing types per decision #3. Always emit JSON stdout (`--legacy` for old shape per C8). Per-peer success/failure summary to stderr. | 1 |
| 3 | #26 | `--cc id1,id2` flag. `metadata.recipientRole = primary\|cc`. Shared conversationId across primary + all cc. Receiver-side `check-inbox.sh` + `bridge-listen.sh` surface `RECIPIENT_ROLE=` and prepend `[CC informational — no response required]` for role=cc. Dedupe `--cc id` when id also in `--to` (deliver once as primary, log warning). | 1, 2 |
| 4 | #21-redaction | `--redact` flag. Apply to content BEFORE outbox audit. Set `metadata.redactionCount`. `BRIDGE_REDACT_PATTERNS_FILE` env override. Conservative defaults only. | 1 |
| 5 | release | Bump 0.3.2 → 0.4.0. Update CLAUDE.md (reserved keywords, new stdout shape, new metadata fields). Verify direct-path `installPath`. Tag `v0.4.0`. Merge. | 2, 3, 4 |

### Risks

- **R2.1** Hot-path refactor: existing 44-test `test-send-message.sh` runs UNMODIFIED through WS1. Explicit assertions for single-recipient inbox/outbox file counts AND `--legacy` stdout shape.
- **R2.2** Reserved keywords. Quoted-`*` examples mandatory in docs.
- **R2.3** Stdout JSON shape is a breaking change for anything grepping `msg-` in send-message stdout. Mitigation: `--legacy` flag; release notes flag prominently; orchestrator skill updated.
- **R2.4** `recipientRole` new field. Receivers running pre-0.4 code default to `primary` via `// "primary"` jq read.
- **R2.5** Broadcast disk multiplier: per-peer outbox audit copies N-multiply for `all` broadcasts. Acceptable; `/bridge prune --outbox N` handles.

### Estimate

2–3 days · ~10 commits · 3 issues addressed · 1 breaking change (stdout shape, mitigated by `--legacy`).

---

## Phase 3 — v0.5.0: Deferred / Event-Triggered Dispatch

### Goal

Add a durable file-based deferred queue (`projects/<id>/deferred/<event>/<msg-id>.json`) with operator + agent visibility. New: `emit-event.sh` entry point; `send-message.sh --on-event/--on-event-timeout/--on-event-fallback`; `--blocked-by msg-id` sugar; auto-emit `message-resolved:<id>` from send-message + `conversation-resolved:<id>` from conversation-update; `/bridge deferred` subcommand; `list-peers` deferred-count column; `prune --deferred`; timeout sweep hosted in `heartbeat-daemon.sh`.

### Issues addressed

- **#22** — Deferred / event-triggered message dispatch (entire phase)

### Shared infrastructure (lands FIRST)

| Order | Component | Purpose |
|---|---|---|
| 3.1 | `scripts/lib/deferred.sh` | Queue primitives: `deferred_enqueue`, `deferred_list`, `deferred_flush`, `deferred_cancel`, `deferred_path`, `sanitize_event_name`. Reserves `<verb>:<arg>` event-name shape; forbids `/` and `\0`. Atomic-rename flush semantics. |
| 3.2 | `scripts/lib/stale-notify.sh` | Hoisted from `send-message.sh`: emit-recipient-stale-notification. Used by both `send-message.sh` immediate path AND `emit-event.sh` deferred flush. Writes notif directly via `lib/fanout.sh:_deliver_one` (no recursion into send-message). |

### Ordered workstreams

| # | Sub-issue | Workstream | Depends on |
|---|---|---|---|
| 1 | infra | `lib/deferred.sh` primitives + sanitization + atomic flush. Standalone tests. | — |
| 2 | infra | Hoist stale-recipient notification into `lib/stale-notify.sh`. Refactor `send-message.sh` to use it. Tests pin byte-identical behavior. | — |
| 3 | emit | `scripts/emit-event.sh <event-name> [--project <id>]` entry point. Atomic flush via `lib/deferred.sh`. Per-msg: `lib/fanout.sh:_deliver_one` + `lib/stale-notify.sh` if recipient stale. | 1, 2 |
| 4 | defer | `send-message.sh --on-event <name>` + `--on-event-timeout <duration>` + `--on-event-fallback drop\|deliver-anyway\|notify-sender`. Enqueues to `projects/<id>/deferred/<event>/<msg-id>.json`. Writes outbox at enqueue with `status="deferred"` + `deferredAt` per decision #7. | 1, 2 |
| 5 | auto-emit | `conversation-update.sh` auto-emits `conversation-resolved:<conv-id>` when status flips to resolved (best-effort, `\|\| true`). `send-message.sh` auto-emits `message-resolved:<original-msg-id>` when a message with `.inReplyTo` lands per C5 semantics. | 3 |
| 6 | sugar | `send-message.sh --blocked-by msg-X` translates to `--on-event message-resolved:msg-X`. Records `metadata.deferral.blockedBy`. Mutually exclusive with `--on-event`. | 4, 5 |
| 7 | visibility | `scripts/list-deferred.sh` + `/bridge deferred [--event <n>] [--to <id>] [--json]` subcommand. Project-scope guard via `path-resolve.sh:assert_same_project`. | 1, 4 |
| 8 | peers | `list-peers.sh` adds DEFERRED column (count of pending deferred msgs TO each peer). Column hidden if no deferred msgs anywhere in project. | 1 |
| 9 | prune | `prune.sh --deferred N` + include in `--all`. Forced expiry separate from age-based prune (`expiresAt < now` → delete regardless of `N`). | 1 |
| 10 | timeout | Timeout sweep in `heartbeat-daemon.sh` per decision #6. Project-level flock for exactly-once. O(1) early-out when `deferred/` empty. On expiry: apply fallback policy via `lib/fanout.sh:_deliver_one` or notif via `lib/stale-notify.sh`. Update outbox in-place to `status="expired"` + `expiredAt`. | 4, 9 |
| 11 | docs + release | Document deferred dispatch in `commands/bridge.md` + `SKILL.md`. Teach `--blocked-by` patterns. Bump 0.4.0 → 0.5.0. Verify direct-path `installPath`. Tag `v0.5.0`. Merge. | 3, 4, 5, 6, 7, 9, 10 |

### Risks

- **R3.1** Production hot path. Auto-emit best-effort `|| true`. No-op when no deferred queue. Test asserts zero behavioral change when `deferred/` absent.
- **R3.2** Refactor: `lib/stale-notify.sh` extraction (WS2) byte-identical to current inline. Diff against fixture-recorded JSON pins contract.
- **R3.3** Auto-emit latency: ~20–50ms per `conversation-update.sh` call. Acceptable per C11.
- **R3.4** Race: concurrent `emit-event.sh` rely on atomic-mv. Test pins winner-takes-all.
- **R3.5** Disk leak: deferred without timeout accumulates. `prune --deferred` + surfacing in `list-peers` + `/bridge deferred`. SKILL.md warns.
- **R3.6** Event-name collision: reserve `<verb>:<arg>` shape. Document. Suggest `human:<name>` for free-form.
- **R3.7** Hook performance: O(1) early-out when queue empty. With 100 deferred msgs, sweep ~50ms. Benchmarked.
- **R3.8** heartbeat-daemon scope expansion: previously did ONE thing; now adds timeout sweep. Justified by reliability (decision #6). Sweep code ~30 lines.

### Estimate

3–4 days · ~23 commits · 1 issue addressed · 0 protocol-breaking changes (additive).

---

## Cross-cutting concerns

### Test suite green at every commit

398 tests today → ~450 (v0.3.2) → ~485 (v0.4.0) → ~510 (v0.5.0). Full `bash test.sh`: ~30s today → ~60s by end. Total runtime cost across bundle: ~50 min. Noted as friction. Optional stretch: parallel test runner in v0.3.2 WS1.

### Symlinked production install

Direct-path approach (decision #8): `installed_plugins.json` `installPath` → repo dir. Script changes hot-reload via symlink. Manifest changes (lifecycle, recipientRole, deferral) propagate on next message that touches them.

**Per-phase verification at every version-bump commit:**

```bash
jq '.plugins."session-bridge@session-bridge"[0]' ~/.claude/plugins/installed_plugins.json
# Confirm installPath points at repo dir (not a cache version path).
# If overwritten by Claude Code, restore:
jq --arg p "/home/me/Documents/Coding Projects/Claude code session bridge/plugins/session-bridge" \
   '.plugins."session-bridge@session-bridge"[0].installPath = $p' \
   ~/.claude/plugins/installed_plugins.json > /tmp/ip.json && mv /tmp/ip.json ~/.claude/plugins/installed_plugins.json
```

### Schema evolution

Every NEW field read via safe-default `jq`:

- `.lifecycle // "normal"`
- `.metadata.recipientRole // "primary"`
- `.metadata.redactionCount // 0`
- `.metadata.deferral // null`

No script ever errors on a missing new field. Tests pin defaults explicitly.

### Hot-reload vs restart-required

| Surface | Hot-reloads? | Implication |
|---|---|---|
| `scripts/*.sh` | YES (symlink + re-exec per call) | Script changes felt immediately. |
| `commands/bridge.md` | NO (loaded at `/bridge` invocation) | Standing standby loop holds stale guidance. |
| `skills/bridge-awareness/SKILL.md` | NO (loaded at activation) | Active agent has stale skill until reload. |
| `hooks/hooks.json` | YES (Claude Code re-reads per firing) | New hooks fire on next firing. |
| `.claude-plugin/plugin.json` | Re-snapshot trigger? | See decision #8 + per-phase verification. |

**Implication:** receiver-side behavior changes (CC framing, lifecycle warning, auto-attached note) MUST be triggered by INLINE DATA in the message that `check-inbox.sh` prints — NOT by relying on agent having re-read the skill. SKILL.md updates are best-effort improvements for new sessions, not load-bearing.

### `lib/deliver.sh` ownership

Resolved in v0.4.0 design pass (per C7). v0.4.0 WS1 extracts `_deliver_one(msg-json, target-inbox, sender-outbox)` into `lib/fanout.sh` as a PURE helper (no notification side effects). v0.5.0 WS3 reuses directly + invokes `lib/stale-notify.sh` (hoisted in v0.5.0 WS2). No double extraction.

### Branch & version-bump strategy

Per decision #1: `next` branch holds all work. Version bumps only at phase-boundary commits. Tags + merges to main only at version bumps.

---

## Risk register (master)

De-duplicated across phases.

| ID | Risk | Phase | Mitigation |
|---|---|---|---|
| MR-1 | Hot-path refactor regression breaks 10 production sessions | All | Extract-helper-then-rewire. Existing tests pass UNMODIFIED through refactor commits. |
| MR-2 | Schema-evolution: legacy data missing new fields | All | Safe-default jq reads. Tests pin defaults. |
| MR-3 | `ensure_producer_alive` daemon-spawn freezes hooks | 1 | Explicit setsid + nohup + fd close per C3. Test asserts parent exits immediately. |
| MR-4 | PPID double-fork false-positive bricks standby loop | 1 | Narrow heuristic (PPID dead + cmdline regex + escape-hatch env). Integration test mimics Claude Code launch. |
| MR-5 | Auto-resume default-on surprises agent | 1 | Stderr `auto-attached` line on every attach. SKILL.md teaches expectation. Release notes flag prominently. |
| MR-6 | Stdout JSON shape breaks callers grepping `msg-` | 2 | `--legacy` flag for opt-out. Orchestrator skill updated. |
| MR-7 | Broadcast disk multiplier blows up outbox | 2 | Document N-multiplier. `/bridge prune --outbox` handles. |
| MR-8 | Redaction false-positive corrupts message in flight | 2 | Default-off. Conservative pattern set (no email/JWT). Test confirms `--redact` off → byte-identical. |
| MR-9 | Deferred queue accumulates indefinitely (disk leak) | 3 | `prune --deferred`. Surfaced in `list-peers` + `/bridge deferred`. SKILL.md warns. |
| MR-10 | Auto-emit re-entrancy creates dependency cycle | 3 | `emit-event.sh` calls `lib/fanout.sh:_deliver_one` (pure), NEVER `send-message.sh`. Stale-notify via `lib/stale-notify.sh` direct write. |
| MR-11 | Daemon-hosted sweep adds latency to heartbeat-daemon | 3 | O(1) early-out when queue empty. Project-level flock for exactly-once. Benchmarked. |
| MR-12 | Event-name collision (operator vs auto-emit) | 3 | Reserve `<verb>:<arg>` shape. Document. |
| MR-13 | Symlinked install version-bump re-snapshot | All | Per-phase verification step. Restore direct-path `installPath` if overwritten. |
| MR-14 | Test runtime budget grows to ~60s per commit | All | Acceptable. Optional parallel runner stretch goal. |
| MR-15 | `conversation-update.sh` auto-emit latency (~20–50ms) | 3 | Acceptable for ~5 msg/min coordination rate. Wrapped `\|\| true`. Future inline optimization possible. |

---

## Per-phase verification checkpoints

At every version-bump commit (end of each phase), run this manual checklist on the user's live install:

1. **Plugin install integrity:**
   ```bash
   jq '.plugins."session-bridge@session-bridge"[0] | {installPath, version}' ~/.claude/plugins/installed_plugins.json
   ```
   `installPath` MUST point at repo dir AND `version` MUST match new tag. If not, restore per the snippet in "Symlinked production install" above.

2. **Test suite:** `cd plugins/session-bridge && bash test.sh` → 0 failures.

3. **Basic protocol smoke:**
   ```bash
   BRIDGE_DIR=~/.claude/session-bridge bash plugins/session-bridge/scripts/list-peers.sh --project plextura-suite
   ```
   Expected sessions shown with expected statuses.

4. **Phase-specific smoke:**
   - **v0.3.2:** `/bridge inbox <any-specialist>` works; manifests show new `.lifecycle` field after first compaction; heartbeat file updates on next send.
   - **v0.4.0:** broadcast `all` from scratch session delivers to all peers; `--cc` delivers with `RECIPIENT_ROLE=cc`; `--redact` redacts test patterns.
   - **v0.5.0:** defer with `--on-event ready`; emit `ready`; verify msg lands in recipient inbox with `status=sent`.

5. **Restart specialists:** User restarts the 10 plextura sessions to pick up SKILL.md + bridge.md changes (NOT script changes — those hot-reload).

---

## Follow-up planning passes

Each phase gets its own per-phase plan doc with TDD-detail commit-level breakdown via `superpowers:writing-plans`:

- `docs/superpowers/plans/2026-MM-DD-v0.3.2-liveness-and-forensics.md` — written after this master plan is approved
- `docs/superpowers/plans/2026-MM-DD-v0.4.0-routing-primitives.md` — written after v0.3.2 ships
- `docs/superpowers/plans/2026-MM-DD-v0.5.0-deferred-dispatch.md` — written after v0.4.0 ships

Per-phase plans use `writing-plans` conventions: each workstream broken into TDD-style commits (failing test → implement → commit), exact code shown in each step, no placeholders. The implementer (subagent-driven-development or manual) executes against these plans.

---

## Non-goals / explicit wontfixes

- **#21 Option 3 (per-recipient encryption):** wontfix-for-now. Conflicts with `/bridge inbox` cross-session triage (#24); would require a key registry on project-join and break the persistence-first model. Revisit if a real multi-tenant use case emerges.
- **Real-time push-based delivery:** out of scope. The file-based inbox is the durability layer; standby + Stop hook handle responsiveness; this bundle doesn't change that.
- **Cross-machine sessions:** out of scope. Bridge is single-host by design (`~/.claude/session-bridge/` is local).
- **Acknowledgement-based delivery (read receipts on agent ATTENTION, not just claim):** out of scope. The v0.2.22 instrumentation gave us forensic proof of CLAIM/OUTPUT but no signal that the agent actually processed the systemMessage. This is a deeper architectural problem (memory drift under load) that needs its own design pass, not bolted into this bundle.
