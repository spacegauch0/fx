# CTO runtime on fx — v0 specification

## Purpose

`fx cto` is a local-first CTO control plane layered on top of the `fx`
coding harness. Its purpose is to own engineering outcomes over time: retain
context, notice relevant events, delegate work in isolated worktrees, review
candidate changes, and require a human before sensitive effects occur.

The PoC's defining property is controlled self-extension. The trusted kernel
does not rewrite itself. It can ask a fixed `cto-dev` counterpart to create a
connector in a constrained extension boundary, validate it, and present it for
human review and approval.

## Non-goals

- Autonomous merge, deployment, deletion, spending, or external messaging.
- A cloud-hosted multi-tenant product.
- Storing provider secrets in `.cto/`.
- Letting self-generated code modify the kernel, policy, audit journal, or
  activation logic.

## Trust and safety model

The trusted kernel owns task state, policy, audit, worker dispatch, worktree
creation, candidate validation, and approval. Mutable connectors live only in
`src/cto/extensions/`.

| Action | Current policy |
| --- | --- |
| Local worker execution in the extension boundary | Allowed and audited |
| Workspace-escaping path | Denied and audited |
| Merge, deploy, delete, spend, external message | Approval required |
| Candidate capability activation | Explicit `fx cto approve <task-id>` |

Every policy result is written to the append-only `.cto/events.jsonl` journal.

## Implemented

### Core persistence and audit

- `.cto/capabilities.json`, `.cto/tasks.json`, `.cto/goals.json`, and
  `.cto/runs.json` survive process restarts.
- `.cto/events.jsonl` is the ordered audit ledger.
- The kernel tracks capabilities, goals, capability tasks, worker runs, and
  candidate validation state.

### Self-extension workflow

1. `fx cto request "watch merged pull requests"` identifies the missing
   `github.pull_request.merged` capability.
2. The kernel creates a task for `cto-dev` and an isolated Git worktree.
3. The `fx` worker is invoked in that worktree.
4. Candidate changes are restricted to `src/cto/extensions/` and the generated
   prompt file.
5. The candidate is built and tested before it can be reviewed.
6. `fx cto review <task-id>` renders only the extension diff.
7. `fx cto approve <task-id>` activates the capability after human approval.

### GitHub connector

`src/cto/extensions/github_events.zig` normalizes a GitHub
`pull_request` webhook only when it is `closed` and `merged: true`. It carries
the delivery ID, repository, PR URL and number, title, author, merger, head
SHA, and base branch into the provider-neutral observation contract.

It is pure. Signature verification, delivery persistence, and action policy
remain responsibilities of the trusted runtime.

### Human control surface

Available commands:

```text
fx cto status
fx cto capabilities
fx cto goals
fx cto tasks
fx cto runs
fx cto decisions
fx cto events
fx cto review <task-id>
fx cto approve <task-id>
fx cto channel "/status"
```

The `channel` command accepts Telegram-compatible intent text (`/status`,
`/goals`, `/runs`, `/decisions`, `/approve <id>`, `/interrupt <id>`). It has no
network transport or bot credential yet. `/interrupt` currently records the
intent in user-facing output; it cannot cancel a running worker yet.

## Remaining work

### 1. Durable observations and project memory

- Persist normalized observations in `.cto/observations.jsonl`.
- Deduplicate deliveries by provider and delivery ID.
- Keep cursors for polling providers.
- Add project facts, decisions, and outcome summaries with provenance.
- Preserve GitHub merge timestamps in the observation payload.

### 2. GitHub ingestion service

- Verify webhook signatures before parsing input.
- Provide a local webhook endpoint and an authenticated polling alternative.
- Ingest CI checks, reviews, issues, deployments, and PR lifecycle events.
- Route normalized observations through the durable store and policy engine.

### 3. Planning and supervision

- Convert active goals into prioritized plans and linked tasks.
- Persist worker progress, bounded logs, retries, deadlines, and timeouts.
- Implement cancellation so `/interrupt <id>` actually stops a worker.
- Produce concise decision briefs rather than raw event streams.

### 4. Version activation and rollback

- Materialize each approved candidate as a versioned active worktree.
- Health-check the candidate before switching the active pointer.
- Retain the prior known-good version and support explicit rollback.
- Keep source branches and human Git history unchanged until a separately
  approved merge.

### 5. Long-running control plane

- Run a local daemon that owns locks, schedules reconciliation, and survives
  a terminal session.
- Expose authenticated local API endpoints for status, approvals, event
  ingestion, and supervision.
- Add structured logs and health/readiness checks.

### 6. Telegram transport

- Authenticate allowed chats/users.
- Receive updates through a webhook or long polling process.
- Connect parsed commands to the local API.
- Send concise approval requests, failures, and scheduled summaries.

### 7. Proactive loop

- Reconcile new observations against active goals and memory.
- Create proposals or delegated work only when policy allows it.
- Require approval before sensitive effects.
- Evaluate decisions using task success, policy violations, latency, cost, and
  human interventions.

## Verification baseline

The implemented CTO subset is verified with the focused Zig test root and a
full `zig build`. On the current environment the focused suite reports 49–59
passing tests (depending on imported scope), 13 platform-specific skips, and
no failures. The full repository suite has unrelated baseline failures in this
Linux/root test environment and is not represented as passing.

## Delivery sequence

1. Observation/memory store and GitHub delivery deduplication.
2. Local daemon plus an authenticated event-ingestion API.
3. Supervision, cancellation, retries, and candidate version activation.
4. Telegram transport and proactive reconciliation.
5. End-to-end fixture: merged PR → observation → decision → task → worktree →
   review → human approval → active candidate or rollback.
