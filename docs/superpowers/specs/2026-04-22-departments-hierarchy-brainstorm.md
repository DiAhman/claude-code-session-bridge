# Departments / 3-Layer Hierarchy — Brainstorm

**Status**: brainstorm, not a spec. Saved to revisit.
**Date**: 2026-04-22
**Context**: post v0.2.21. Plextura orchestrator has 9 specialists and is juggling too many direct threads.

## Problem statement

Currently the bridge has two tiers:

- `orchestrator` — coordinates
- `specialist` — executes

In Plextura-style projects with 9+ specialists, the orchestrator becomes a bottleneck. Its context gets flooded with task-updates, routing questions, and per-specialist decisions. Two distinct pains:

1. **Decision volume** — N specialists, N streams of coordination decisions hitting one brain.
2. **Message volume** — `task-update` spam clutters the transcript even when decisions are light.

## Proposed shape

Insert a middle layer:

```
Project Orchestrator
├── Department Lead: web
│   ├── specialist
│   ├── specialist
│   └── specialist
├── Department Lead: infra
│   ├── specialist
│   └── specialist
└── Department Lead: …
```

- Specialists rarely talk directly to orchestrator.
- Specialists talk to their assigned lead.
- Orchestrator talks only to leads.

## Design choices that actually matter

Four decisions shape the implementation; everything else follows.

### 1. Static vs dynamic departments
- **Static**: declared in `project.json` at creation. Leads fixed. Specialists declare department at join.
- **Dynamic**: orchestrator creates departments on demand and appoints leads as scope emerges.
- **Hybrid**: declarative defaults in `project.json`, orchestrator can reassign at runtime.

For Plextura (fixed domains: web/shell/grant/cloud/…), **static** likely wins. For exploratory projects, dynamic matters more.

### 2. Strict vs permissive boundaries
- **Strict**: specialists ONLY talk to their lead. Cross-department anything routes lead→lead.
- **Permissive**: specialists can send read-only queries across departments (with cc to their own lead). Assignments and escalations must go through leads.
- **Advisory**: no technical enforcement — convention only; the skill teaches preferred paths.

Advisory is cheapest to build; strict is cleanest for context hygiene. Permissive is likely the right middle — strict creates choke points if a lead is slow.

### 3. Who summarizes, and when?
The **core value prop** of a lead is aggregation. If leads become dumb relays, orchestrator sees the same flood — we've added hops for nothing.

- Lead receives N task-updates per minute from specialists.
- Best pattern: **lead relays nothing automatically**. Lead sends `task-update` to orchestrator at meaningful milestones, and aggregates specialist status on orchestrator request (`query "status of department:web"`).
- This is the discipline — without it the hierarchy is pure overhead.

### 4. Failover when a lead is offline/busy
- **Simplest**: specialists fall back to `routing-query` to orchestrator (existing behavior). Orchestrator answers or appoints temporary lead.
- Alternatives: buffer messages, elect replacement, specialists promote themselves. Probably overkill for v1.

## Minimal first slice

Just enough to validate the hypothesis without committing to full semantics:

- `project-join.sh` accepts `--department <name>` (optional); manifest stores it.
- `--role lead` added as a valid role alongside `orchestrator`/`specialist`.
- `project.json` gains `departments: { <name>: { lead: <sessionId> } }`, populated as leads join.
- SKILL.md teaches:
  - Specialists resolve routes via `my department lead → other lead → orchestrator`.
  - Leads decompose tasks inward, summarize outward.
- `routing-query` gains semantics:
  - Lead first handles routing questions from their own specialists.
  - Orchestrator handles cross-department routing.
- No new message types. No new scripts. Just: extra manifest field, routing rule, skill text.

Roughly a few hundred lines of skill text and ~40 LOC of bash. Can be tested on Plextura by promoting 3–4 existing specialists to leads and reassigning the rest to departments.

## The question to answer before committing

Is the orchestrator struggling with **noise** (message volume) or **decisions** (coordination complexity)?

- If noise: a lower-cost experiment might suffice — orchestrator-side filter that suppresses `task-update` unless urgency is `high+` OR content contains keywords (`blocked`, `completed`, `error`, `question`). One week of data would reveal whether the problem is volume.
- If decisions: hierarchy is the right call regardless of filtering — only sub-delegation fixes cognitive load.

In Plextura the answer is probably **both**, but leaning "decisions." Worth validating before building.

## Risks and costs

- **More hops = more latency.** Specialist→lead→orchestrator = 2 hops vs 1. For synchronous coordination this compounds.
- **More sessions = more idle token cost** (even at zero-CPU standby, each session has registration/heartbeat/hook overhead per Claude Code instance).
- **Lead discipline is load-bearing.** A lead that forwards everything negates the design.
- **Routing failures multiply with layers.** More places for "who handles X?" to go wrong. Need solid fallbacks.
- **Role ambiguity.** Can a lead also be a specialist in their own domain? Probably yes in practice — they ARE the expert. Manifests may need an `alsoHandles` field or similar.

## Followups to think about later

- Does a lead's conversation tree rollup automatically surface in the orchestrator's `/bridge status`?
- How do `human-input-needed` messages flow? Do leads have delegated authority for some decisions?
- Does the existing `parentConversation` field already do the threading work, or do we need new linkage?
- Is "team" a better name than "department"? Matches common eng vocabulary.
- Do specialists need to know about other departments at all, or should routing stay fully lead-mediated?

## Alternatives explored

- **Keep flat, add orchestrator-side message filtering.** Cheapest. May solve noise without solving decisions.
- **Keep flat, add a "digest" channel** that specialists post non-urgent updates to, orchestrator pulls on demand.
- **Swarm architecture** — specialists peer-to-peer without central coordinator. Wrong direction; too chaotic for structured projects.

## Open questions for the user

1. Noise or decisions — which is the bigger pain right now?
2. Is Plextura's domain list stable enough for static departments?
3. Would you tolerate specialists NEVER talking to the orchestrator directly (strict), or is that too restrictive?
4. How much of the lead's job should be "condense and relay" vs "actually do work in their domain"?
