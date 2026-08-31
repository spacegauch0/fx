# CTO runtime — architecture decisions and roadmap

This is the plan for taking `fx cto` from the current PoC to the v0 in
`docs/SPEC.md`. It records the decisions that spec leaves open, with the
reasoning, so the remaining work is mechanical rather than speculative.

This is a greenfield project: there are no external users, no stored
state worth migrating, and no published interface to keep stable. Where a
current shape is wrong, the plan changes it rather than working around it.

## Status

| Spec item | State |
|---|---|
| Core persistence and audit | Done |
| Self-extension workflow (task → worktree → build/test → review → approve) | Done |
| GitHub connector (`pull_request` merged, normalized + provenance) | Done |
| Human control surface (CLI + `channel` parser) | Done |
| 1. Durable observations, delivery dedup, merge timestamps | Done |
| 1. Project memory (facts, decisions, outcomes) | Outstanding |
| 2. GitHub ingestion service — signature verification | Done (M2) |
| 2. GitHub ingestion service — listener / polling | Outstanding |
| 3. Planning and supervision | Done (M4) |
| 4. Version activation and rollback | Done (M3) |
| — Agent-native interfaces (brief/explain/schema; `--json` outstanding) | Mostly done (M5) |
| 5. Long-running control plane | Done (M6) |
| 6. Telegram transport | M7 |
| 7. Proactive loop | M8 |

## Agent-operating model

A CTO-as-a-service is, by its own premise, operated by an agent — its own
future self as much as any human. Every `fx cto` invocation that built
M2–M4 was in fact driven by an agent (the one writing this), and a real,
measurable share of that work went into re-deriving "what does this
system look like right now" from `.zig` source and raw JSON files, not
from anything the system itself offered to say about it. That cost is
what this section exists to eliminate.

Agent-ergonomic is therefore not a UX layer bolted onto a human-first
CLI; it is the primary interface contract. A dense, structured, low-noise
surface that is cheap for an agent to parse and reason about is also easy
for a human to skim — legibility does not trade off against usability, it
subsumes it. The reverse does not hold: optimizing purely for a human
skimming a terminal (today's `std.debug.print` prose, and only that)
leaves an agent re-parsing English sentences to recover structure that
was already known at the moment the string was formatted.

Concretely, the system is a **tower of five surfaces**, each a narrower,
more purpose-built projection of the one below it:

1. **World model** — this document, plus `fx cto schema` (D7). Read
   once; gives a complete, current, self-generated description of every
   entity, state, and transition, so a fresh agent session never has to
   reverse-engineer the shape of `.cto/` from `store.zig`.
2. **Situational awareness** — `fx cto brief` (D7). One call: what's
   active, what's blocked and on whom, what's currently running and for
   how long, what just changed, what to do next. The thing an agent runs
   first in every session and every check-in.
3. **Investigation** — `fx cto explain <kind>-<id>` (D7). One call: the
   complete causal story of one entity, cross-referenced across tasks,
   runs, releases, and the journal, so tracing "why is task-3 stuck" is a
   single lookup instead of manually joining four files by hand — which
   is exactly what every session so far has had to do.
4. **Action** — `request`, `approve`, `activate`, `rollback`,
   `interrupt`, … Every mutating command is idempotent, self-narrating
   (states what happened and suggests `next_actions`), and now defined
   exactly once: D8 collapses the CLI's and the human-channel bridge's
   independently maintained notions of "what this system can be asked to
   do" into one canonical schema, closing a drift that has already
   happened once.
5. **Ground truth** — `events.jsonl`. Unchanged in kind: append-only was
   already the right shape (M1). What changes is that every read surface
   built on it windows and filters rather than forcing an agent to reread
   the whole history to answer "what's new" (D7, `--since`).

This tower rests on a principle already present in the code but not yet
named: **exactly one authoritative source per fact, everything else a
computed view.** `.cto/current` is the single source of truth for the
active release, not `releases.json` (M3); `task.status` and
`capabilities.status` are updated together, inside one function, never
independently (`Kernel.markCandidate`). `brief`, `explain`, and every
`--json` view extend this same discipline rather than introduce a second
place a fact could live: they are pure projections of the tables and the
journal, recomputed fresh on every call, never independently cached or
mutated. An agent that has just read `brief` can trust it reflects
reality with no staleness question left to reason about.

## Decisions

### D1 — Secrets live outside `.cto/`, env-var first

`.cto/` is workspace-local and adjacent to a git repo; the spec makes
"no provider secrets in `.cto/`" a non-goal for good reason.

Resolution order for any provider secret:

1. `FX_CTO_<PROVIDER>_<PURPOSE>` environment variable
   (e.g. `FX_CTO_GITHUB_WEBHOOK_SECRET`, `FX_CTO_TELEGRAM_TOKEN`).
2. A keyed file at `~/.fx/cto-credentials/credentials.json`, following the
   convention `~/.fx/mcp-credentials/credentials.json` already
   established, and refused outright if its mode lets group or others
   read it — the way ssh refuses a permissive private key.

**Not** `host.SecretStore`. That interface is a single-slot store
(`load(alloc) -> ?[]u8`, no key) purpose-built for the one fx gateway
credential and backed by the macOS Keychain or a profile file. CTO needs
several independently-rotatable secrets. Widening a credential path the
whole of fx depends on is the wrong change to make from an additive
layer; a separate keyed store is smaller and blast-radius-free.

The keyed store is built on `io_mod.openOrCreateVerifiedPrivateDir` and
`io_mod.durableReplaceVerified`, which already enforce exactly `0700`/
`0600`, reject symlinks and hardlinks, and fsync — hardened code that
exists and is tested, rather than new file handling.

Secrets are never journaled, printed, or included in an error message.
The journal records *that* a key was resolved (by key name) and never its
value.

### D2 — Two transports, split by trust level

Authentication is a different problem for "a human asking to approve
something" than for "an internet-facing webhook", so they get different
answers rather than one shared token.

**Control API — Unix domain socket.**
`$XDG_RUNTIME_DIR/fx-cto/<workspace-hash>.sock` (falling back to
`~/.cache/fx/cto/`), containing directory `0700`.

Authentication *is* the filesystem permission. There is no bearer token
to leak into a shell history, no port to scan, no TLS to misconfigure,
and no auth code of my own for someone to find a bug in — the kernel
already trusts the local user who can read `.cto/`, so a socket only that
user can open grants exactly the authority they already had. `std.Io.net.UnixAddress.listen`
supports this directly.

**Webhook ingestion — loopback HTTP + provider signature.**
`127.0.0.1:<port>`, never `0.0.0.0`. Authentication is the provider's own
HMAC (`X-Hub-Signature-256` for GitHub), constant-time compared, verified
*before the body is parsed*. Exposing it publicly is the operator's
decision and their tunnel (`cloudflared`, `ngrok`); the daemon never
binds a public interface itself. Documented as such.

**Polling is the default ingestion mode.** Outbound-only, no listener, no
tunnel, no inbound attack surface at all — the right default for a
local-first tool. The webhook endpoint is opt-in for people who want
latency.

### D3 — The daemon dispatches workers out-of-process

The current in-process `LiveRunner` (`runCtoFxWorker` chdirs, then calls
`cli_ask.run` directly) is correct for one-shot CLI use and **wrong for a
daemon**, for three independent reasons:

- `std.process.setCurrentPath` is process-global, so two concurrent tasks
  would corrupt each other's working directory, and the daemon's own cwd
  along with them.
- A blocking in-process call cannot be cancelled, so `/interrupt` can
  never be implemented against it.
- An agent crash or OOM would take the supervisor down with it.

The daemon therefore spawns `fx ask` as a child process with per-child
`cwd` (which is what `std.process.SpawnOptions` is for), giving
cancellation (signal the child's process group), isolation, and
concurrency for free.

This costs nothing architecturally: `fx_worker.LiveRunner` is already a
typed seam the composition root fills in. The CLI keeps injecting the
in-process runner; the daemon injects a subprocess runner. `kernel.zig`
does not change.

### D4 — The daemon is the single writer of `.cto/`

Today every `fx cto` invocation read-modify-writes whole JSON files with
no locking — fine for one human at a keyboard, unsound the moment a
daemon reconciles in the background.

When a daemon is running it owns all writes; the CLI becomes a client of
the control socket. With no daemon running, the CLI writes directly, but
under `io_mod.acquireTimedAdvisoryLock` (already implemented and tested,
including the cancellable and unsupported-filesystem paths).

Consequence, accepted: `.cto/` becomes a verified private directory
(`0700`) rather than the current default-permission directory. Greenfield,
so it is simply created that way.

### D5 — Telegram cannot approve self-modifying code

Telegram gets an allowlist of chat IDs and can run every read command,
plus approvals for actions that are not self-modifying. Approving a
candidate that changes fx's own source stays CLI-only unless the operator
explicitly opts in.

A chat ID is a weak authenticator — it survives a stolen phone, a
forwarded message, or a bot token leak. "Authority narrows downward"
means the weakest-authenticated channel does not get the
strongest-consequence action. The approval gate is the whole point of the
PoC; it should not be reachable from the least trustworthy input.

### D6 — Memory stays boring

Project memory is `.cto/memory.jsonl`: append-only facts with
`{id, kind, subject, body, provenance{source, ref}, recorded_at_ms, superseded_by}`.
Retrieval is filtering by subject and kind. No vector store, no graph
database, no embeddings — explicit non-goals of the original brief, and
unjustifiable at a scale of hundreds of facts.

### D7 — The read surface is a projection, not a file dump

Today `fx cto status/tasks/goals/runs/releases/events/observations` are
nine independent, hand-formatted views over nine largely-overlapping
tables — an agent (or human) reconstructing "what needs my attention"
has to run several of them and mentally join the results. That join is
exactly the kind of work a computer should do once, correctly, rather
than an agent repeating imperfectly from prose every session.

- **`fx cto brief`**: one call, the whole current situation — pending
  approvals, in-flight runs (with elapsed time against their deadline),
  recently failed tasks and their one-line reason, capabilities still
  missing, and a `next_actions` list of concrete commands to run next.
  Computed fresh from the same tables every other command reads; nothing
  new is stored.
- **`fx cto explain <kind>-<id>`**: the full causal narrative for one
  task, run, goal, or release — its lifecycle, every run it produced
  (not just the latest), validation results, and the exact journal
  entries that reference it — cross-referenced automatically instead of
  requiring `tasks` + `runs` + `events` and manual filtering by id. For a
  task this subsumes `review`'s diff by summarizing it and pointing at
  `fx cto review <id>` for the full text, rather than inlining a
  potentially large diff into a view meant to stay dense.
- **`fx cto logs <run-id> [--tail N]`**: reads `.cto/runs/<id>.log`
  (M4) directly. That file exists today only as a path convention a
  caller already has to know; it should be a first-class command, the
  same way pid/interrupt-marker bookkeeping already got one
  (`fx cto interrupt`).
- **Prefixed ids everywhere**: `task-7`, `run-12`, `release-3`, `goal-2`
  — displayed everywhere, and accepted everywhere a bare integer is
  accepted today. Four independent `u64` counters that all start at 1
  and are displayed as bare `#7` is a standing invitation to conflate a
  task id with a run id, which is exactly the ambiguity M4 had to design
  around by hand when scoping `fx cto interrupt` to run ids specifically.
  Most commands stay lenient (a bare integer is still accepted where the
  command already scopes the entity kind — `approve`, `activate`,
  `review`, `rollback` only ever mean a task). `interrupt` and `logs` are
  the exception: a task id and a run id are both plausible there, so a
  bare integer is refused with an error naming the `run-` prefix
  explicitly, rather than silently guessing which counter was meant.
- **`--since <sequence>` on `events`** (and `observations`): the journal
  is append-only and unbounded by design (M1); a read surface built on
  it must let an agent ask "what changed since I last checked" in
  O(new), not reread the whole history every check-in — the same pattern
  this project already relies on for watching PR activity externally.
- **Relative + absolute timestamps**: every view keeps the raw
  `*_at_ms` field (machine precision, what `explain`'s elapsed-time math
  uses) and adds a human/agent-legible relative form (`"3m ago"`) next to
  it, so reasoning about "is this run overdue" doesn't require an
  epoch-arithmetic step that is also a place to make a mistake.
- **A scoped test target**: `zig build test-cto`, restricted to
  `src/cto/**`. This serves the same agent — the one iterating on this
  system's own code — not its runtime. Today a scoped change has to be
  validated against the full ~8600-test suite (minutes) or against
  nothing; a fast, targeted signal is the difference between checking
  after every edit and batching several edits before daring to check.

*Done when:* a fresh agent session with no prior context can run `fx cto
schema` once and `fx cto brief` per check-in and have enough information
to decide its next action without reading any `.cto/*.json` file or any
`src/cto/*.zig` source directly.

### D8 — One `Command` schema for every transport

`main.zig`'s CLI arg parser and `channel.zig`'s Telegram-text parser
already each define their own notion of "what this system can be asked
to do," maintained independently — and they have already drifted:
`channel.Command` covers `status/goals/runs/decisions/approve/interrupt`
but has no case for `request`, `activate`, `rollback`, `review`, or
`ingest`, none of which were deliberately excluded — they were added to
the CLI after `channel.zig` was written and never backported. That is not
a bug in either file; it is the predictable cost of defining the same set
of actions twice.

The fix is structural, not disciplinary: `channel.zig`'s `Command` union
becomes the canonical action schema for the entire system — extended to
cover every mutating and read command that exists — and both the CLI arg
parser and the Telegram-text parser become thin, transport-specific
functions that produce the same `Command` value, dispatched through one
executor. M6's control socket (already specified to speak
"newline-delimited JSON") gets a third parser for free: JSON lines
deserializing directly into `Command`, using the same D9 envelope
`--json` output already established. Nothing downstream of parsing —
authorization, execution, the printed or JSON-rendered result — is
transport-specific ever again.

This is additive to D2/D3 (trust boundaries, dispatch mechanism), not a
replacement: which transports may issue which `Command` variants (D5's
"Telegram cannot approve self-modifying code") is still enforced at the
boundary, per transport, before dispatch. Only the *shape* of an action
is unified, not who is allowed to send it.

### D9 — Structured output is primary; text is rendered from it

Every `fx cto` command today calls `std.debug.print` directly — the
formatted string *is* the only representation of the result, so an agent
consuming it has to re-derive structure by parsing prose, and any future
JSON output would be a second, independently-maintained code path that
can silently drift from what the text says (the same class of problem D8
closes for the action schema, here applied to the result schema).

Each command instead produces a typed result value first; printing and
`--json` serialization are two renderers over that one value, so they
cannot disagree. `--json` wraps every result in a stable envelope —
`{"kind": "...", "generated_at_ms": ..., "data": ..., "next_actions":
[...]}` — so a result is self-identifying even read out of context
(piped through another tool, or re-read from a saved log), and
`next_actions` travels as data (`{"command": "fx cto approve task-7",
"reason": "..."}`) rather than only as a sentence a human has to parse to
find the command to copy. Text stays the default — this remains a CLI a
human runs by hand — and `--json` is opt-in, matching `gh`/`docker`/
`kubectl` convention rather than forcing every caller to parse JSON for a
one-line status check.

**One correctness fix this rethink surfaced, filed here rather than as
its own decision:** `Runtime.request` checks
`capabilities.isAvailable(...)` before creating a task, but a capability
sitting in `.candidate` status (already delegated, awaiting approval) is
not "available" either — so a second `fx cto request` for the same
objective while a candidate is already pending creates a *second*,
parallel, duplicate task and worktree instead of pointing at the one
already in flight. An agent that re-issues `request` defensively
(uncertain whether an earlier call succeeded — exactly the situation a
context compaction or a retried tool call produces) would fork real
compute this way. Fix: `request` also checks for an existing non-terminal
task against the same `required_capability` and returns that task's id
instead of creating a new one when found.

## Milestones

Ordered so that each is independently reviewable and mergeable, and so
security prerequisites land before the surfaces that need them.

### M2 — Signed ingestion — **done**

Verify a provider signature before anything parses the body.

- `src/cto/secrets.zig`: keyed resolution per D1, refusing a
  group/other-readable credentials file.
- `src/cto/ingest_auth.zig`: `verifyGithubSignature` using
  `std.crypto.auth.hmac.sha2.HmacSha256` with a constant-time compare,
  plus a body-size cap and an event-name allowlist held in the trusted
  layer (so a self-generated connector cannot widen the traffic that
  reaches it).
- `fx cto ingest` takes `--signature` and refuses an unsigned body when a
  secret is configured. Every refusal is journaled as `ingest_rejected`
  with an operator-facing reason that never echoes the body, signature,
  or secret.

The connector stays pure — signature verification is the trusted
runtime's job, per the spec.

Note: a tampered body and a wrong secret deliberately produce the *same*
verdict. Distinguishing them would tell an attacker which half they got
right. Replay suppression is delivery-id dedup, which M1 already
provides.

### M3 — Activation and rollback — **done** (memory outstanding)

The largest gap between the demo and its thesis: `approve()` used to flip
a JSON field and nothing became live.

- `.cto/releases/v<n>/` holds a materialized release, **detached** at an
  immutable commit. Detached because a release is a snapshot, and git
  refuses to check the same branch out twice — a branch-based release
  would collide with the candidate worktree still holding it.
- Candidate work is committed to its own `candidate/task-<n>` branch
  first, staging only boundary-allowed paths, so build artifacts can
  never enter a release commit and the extension boundary is enforced a
  second time at the moment work becomes immutable. Human branches and
  history are never written to.
- `.cto/current` is a symlink; activation is an atomic rename-swap via
  `symLinkAtomic`, so a reader sees the old release or the new one and
  never a partial state.
- Health check (`zig build` + `zig build test` in the materialized
  release) runs *before* the swap. On failure the approval stands, the
  task becomes `activation_failed` and retryable with `fx cto activate`,
  and — the property that matters — the capability stays a *candidate*
  because it is not live.
- `fx cto rollback` repoints at the previous version; superseded releases
  stay on disk so the move is reversible both ways.
- The symlink, not `releases.json`, is the single source of truth for
  what is active, so the two cannot disagree.

**What activation does not do:** it does not replace the running `fx`
binary. An operator builds or installs from `.cto/current`. Hot-swapping
a live process stays out of scope.

Still outstanding from this milestone: `.cto/memory.jsonl` per D6.

### M4 — Supervision — **done**

- `src/cto/process_worker.zig`: out-of-process worker dispatch per D3. The
  child is spawned as its own process **group** (`pgid = 0`), and every
  signal this worker sends targets `-pid` (the group), not `pid` (the one
  process `Child.kill` would reach) — so cancellation reaches every
  subprocess the worker spawns in turn, not just the direct `fx ask`
  child (a coding agent runs shell tool calls, which are exactly the
  grandchildren a single-pid signal would miss). A trailing group-wide
  kill after every reap — not only on timeout/interrupt — sweeps up
  anything the child backgrounded and detached before exiting normally.
- Per-run wall-clock timeout, enforced by the worker's own supervision
  loop (a non-blocking `wait4(..., WNOHANG)` poll, not the blocking
  `Child.wait`/`Child.kill` pair, which only ever signal one pid and
  cannot be raced against a deadline from the same call). On expiry:
  SIGTERM to the group, a grace period, then SIGKILL if it hasn't exited
  — exercised by a test whose spawned process traps and ignores SIGTERM,
  so only a real group-wide SIGKILL can end it before its 30s `sleep`
  would otherwise outlast the test.
- Bounded, truncated log capture: stdout/stderr are drained on background
  threads (so a chatty child never blocks on a full pipe buffer while the
  supervision loop is deciding whether to kill it) into a capped buffer,
  written to `.cto/runs/<id>.log`.
- Real cancellation: `fx cto interrupt <run-id>` (and `/interrupt` on the
  channel bridge) writes an interrupt marker next to the run's pid file.
  The *owning* supervision loop, not the `interrupt` invocation, is what
  signals the process group — keeping exactly one signaler even when
  interrupt runs concurrently with the run it is cancelling. The request
  itself is always journaled (`interrupt_requested`), including when no
  running worker was found.
- Retry with backoff (2s, 4s; capped at 3 attempts), but scoped narrowly:
  only a crash of the dispatch mechanism itself (a failed spawn, a wait4
  failure) is retried, recorded per attempt in `fx cto runs`. A worker
  that actually ran and reported `.failed`/`.timed_out`/`.interrupted` is
  never auto-retried — that would mean silently re-running a model
  attempt (spending) without the approval "Act narrowly" requires, and it
  is real information a human should see once, not have looped past them.

**Scope note, honestly stated:** the CLI's default `fx cto request` path
still dispatches in-process (`FxWorker`/`LiveRunner`, unchanged, per D3's
own reasoning: `setCurrentPath` is process-global and a blocking call
cannot be preempted regardless of which milestone we're in). `interrupt`
against that path correctly reports "no out-of-process worker was found"
rather than claiming to cancel something it cannot reach. `ProcessWorker`
is complete, tested (spawn/success/failure/timeout/group-cancel/interrupt-
marker), and reachable from the CLI's `interrupt` bookkeeping today; it
becomes what actually serves `fx cto request` when M6's daemon exists to
own concurrent dispatch, exactly as D3 describes the split. Building the
mechanism now and switching the default later, rather than switching the
default onto a mechanism validated only in isolation, is the deliberate
order — matches this project's own precedent of catching the real bugs
(the `FileNotFound`, the empty release commit) only once the *real*
binary was exercised, not just unit tests.

### M5 — Agent-native interfaces — **mostly done** (`--json`/D9 and the full D8 merge outstanding)

Implements D7, most of D8, and a slice of D9. Pure CLI-side legibility
work — landed independently of M6, and, as it turned out, threaded
through it: the daemon's own read commands are `views.zig`'s renderers
called a second way, and `action.Action` (D8) is what let the daemon add
a transport without adding a third independent command vocabulary.

Delivered:

- `fx cto brief` — one call, the whole current situation: missing
  capabilities, tasks needing a decision (each with the exact next
  command to run), runs in flight with elapsed time, and the last few
  failures.
- `fx cto explain <kind>-<id>` — the full causal narrative for one task,
  run, release, or goal. For a task: every run it produced (via
  `Run.task_id`, exact), its releases, and journal entries matching its
  capability name — documented in the view itself as a best-effort
  correlation, not a guaranteed one, since `Event.subject` was never
  given a task-id field to filter on precisely.
- `fx cto logs <run-id> [--tail N]` — reads `.cto/runs/<id>.log` (M4)
  directly.
- `fx cto schema` — a JSON description of every entity's fields and every
  event/action kind, generated via `@typeInfo` reflection over the real
  types, not hand-maintained prose.
- Prefixed ids (`task-N`/`run-N`/`release-N`/`goal-N`), displayed
  everywhere and accepted everywhere; `interrupt` and `logs` require the
  `run-` prefix specifically (`id.parseStrict`), since those are exactly
  where a task id and a run id are both plausible. `id.parseAny` lets
  `explain` determine an argument's kind from its own prefix, since it is
  the one command that can legitimately mean any of the four kinds.
- `--since <sequence>` on `events`. **Not** on `observations` as
  originally scoped: `Observation` has no sequence field to filter on
  (only the journal does), and inventing one purely for this felt like
  the wrong direction versus giving `events` a real cursor first, which
  is the one that actually gets checked on every agent check-in.
- `request`'s idempotency fix (`Kernel.inFlightTaskForCapability`).
- `zig build test-cto`, scoped to `src/cto/**` — ~3.5s instead of several
  minutes, and it already caught a real test-isolation bug in the M6
  daemon work within the same session it was built (see git history).
- `action.Action` (D8): the canonical vocabulary, shared today by the CLI
  parser and the daemon's control socket. `channel.zig`'s own text parser
  (`/status`, `/approve <id>`, …) is a second, narrower, still-separate
  parser over a subset of the same actions — the full D8 merge (folding
  `channel.Command` into `action.Action` so there is exactly one type,
  not two that happen to agree today) is still outstanding.

Outstanding:

- **`--json` and the structured-result-first refactor (D9).** Every
  command still only produces `std.debug.print` text; there is no typed
  result value, no JSON envelope, and no `next_actions` as data (though
  `brief`/`explain` already print the equivalent as prose — "next:"
  sections with copy-pasteable commands). This is the largest remaining
  piece of the original M5 scope and the reason this milestone is
  "mostly," not fully, done.
- **The full D8 merge** described above.

*Done when:* a fresh agent session with no prior context can run `fx cto
schema` once and `fx cto brief` per check-in and have enough information
to decide its next action without reading any `.cto/*.json` file or any
`src/cto/*.zig` source directly. Met for the text CLI; not yet
demonstrated for a caller that specifically needs `--json`.

### M6 — Daemon and control plane — **done** (webhook/polling ingestion outstanding)

- `src/cto/action.zig`: the canonical `Action` enum D8 called for, landed
  here rather than waiting on the rest of M5 — the daemon needed *some*
  shared vocabulary to avoid becoming a third independent one, and
  building it once, correctly, was cheaper than building it twice. The
  broader D8 merge (folding `channel.Command`'s own text-parser fully
  into this vocabulary) is still outstanding; today the two coexist,
  each honest about its scope (`channel.Command` — free text a human
  types; `action.Action` — every command any transport can issue).
- `src/cto/writer_lock.zig`: D4's single-writer lock, built on
  `io_mod.openOrCreateVerifiedPrivateDirFromDir` +
  `io_mod.acquireTimedAdvisoryLock` (already hardened, already tested) —
  not new locking code. Held by the daemon for its whole lifetime; taken
  by the CLI only for the duration of one mutating command when no
  daemon is running.
- `src/cto/control_protocol.zig`: a versioned (`protocol_version`),
  newline-delimited JSON request/response envelope. `Command` is every
  `Action` plus two protocol-only liveness probes (`health`, `ready`)
  that never touch the kernel; `Command.toAction()` is `inline else`
  over `@field`, so the two enums are mechanically guaranteed to agree —
  adding to one without the other is a compile error, not a place to
  drift.
- `src/cto/daemon.zig` / `control_client.zig`: the Unix-socket server and
  client. One finding worth recording since it would otherwise resurface
  as a confusing production bug: the socket does **not** live inside
  `.cto/`. `sockaddr_un.sun_path` is capped at 108 bytes on Linux
  (`std.Io.net.UnixAddress.max_len`), and a project checked out several
  directories deep — ordinary for a CI runner or a sandboxed dev
  environment, and exactly what this repository's own working directory
  looked like while building this milestone — blows that budget before
  any filename is even appended. The socket instead lives at
  `$XDG_RUNTIME_DIR/fx-cto/<hash>.sock` (falling back to
  `~/.cache/fx/cto/<hash>.sock`), matching D2's original design; the
  directory is force-set to `0700` and the failure to do so is a hard
  daemon-startup error, never silently swallowed, since D2's whole
  authentication argument depends on it.
- Reads (`status`/`tasks`/`goals`/…) are rendered by `src/cto/views.zig`,
  extracted from what were `main.zig`'s private, stderr-only printers.
  The daemon and the CLI now render the *same* functions into two
  destinations (a socket response buffer vs. stderr) instead of keeping
  two independently-formatted copies of "what does `tasks` look like" —
  a smaller instance of D9's structured-result principle, delivered here
  ahead of the rest of D9.
- `request`/`approve`/`activate`/`rollback`/`interrupt`/`review` are
  handled directly against the kernel/runtime (not proxied text
  commands); `ingest` (needs stdin) and `channel` (its own free-text
  syntax and D5 refusal logic) stay CLI/direct-mode only, by design, and
  the CLI never attempts to proxy them.
- `request` over the control socket dispatches through `Runtime.
  initWithWorker`, a new constructor that injects a `ProcessWorker` (M4)
  as the live worker — the change D3 always said the daemon would need,
  landed as an *addition* (`worker_override: ?worker_mod.Worker`)
  rather than a rewrite of `Runtime.init`, so the CLI's existing
  `FxWorker`/`LiveRunner` composition root is untouched and every
  existing test and call site keeps working exactly as before.
- The CLI auto-detects a running daemon (`control_client.daemonAvailable`,
  a `health` probe) and proxies every command that has an `Action`
  counterpart to it; `ingest`/`channel` stay direct always. With no
  daemon detected, a mutating command acquires the writer lock itself
  for its own duration; a second writer — whether another direct
  invocation or an attempt to start a second daemon — is refused with
  `error.LockBusy` rather than racing whole-file JSON state.
- Verified against the real compiled binary, not just unit tests (this
  project's established bar): a background daemon answering `ctl`
  health/status/request/interrupt calls, the direct CLI transparently
  proxying to it, a killed daemon's stale socket file and lock both
  cleaning up correctly on the next daemon start, and a direct-mode
  command succeeding again once the daemon is gone.

**Known gap, honestly scoped out:** the loopback webhook endpoint and
the default polling loop (this milestone's other original half) are not
built. Ingestion still only has its M2 half — a trusted admission
function `fx cto ingest` calls locally — with nothing that fetches or
receives an event on its own yet. That's real, separable, network-facing
work; folding it into whichever later milestone actually needs low-
latency ingestion is preferable to landing it here disconnected from any
consumer of it.

*Done when (control plane only — see the gap above):* the daemon
survives terminal exit, a second writer is refused rather than
corrupting state, and every existing `fx cto` command works identically
with and without a daemon running. Verified for every read command,
`request`, and `interrupt`; `approve`/`activate`/`rollback`/`review` are
implemented the same way but not yet independently smoke-tested end to
end over the socket.

### M7 — Telegram transport

Long polling by default (outbound only). Chat-ID allowlist. Token from
the secret store. Parsed via the shared `Command` schema (D8) → control
socket. Concise approval requests and failure notices. D5's restriction
enforced kernel-side, not just in the bot.

*Done when:* an allowlisted chat can drive every read command and a
non-allowlisted chat gets nothing, proven without a live bot token.

### M8 — Proactive loop

Reconcile new observations against active goals and memory; propose or
delegate only where policy allows; require approval before any sensitive
effect. Evaluate with task success rate, policy violations, latency,
cost, and human-intervention count.

*Done when:* a merged-PR observation for a watched repo produces a
proposal without a human prompting it, and no sensitive effect ever
occurs without an approval event preceding it in the journal.

## Out of scope

Autonomous merge/deploy/delete/spend/message; cloud or multi-tenant
hosting; secrets in `.cto/`; self-generated code touching the kernel,
policy, journal, or activation path. These are the spec's non-goals and
the plan does not erode them.

## Worth a human decision

Two things I chose a conservative default for rather than guessing at
intent — both easy to change, neither blocking:

1. **Telegram approval scope** (D5). I defaulted to "cannot approve
   self-modifying candidates." If the intended use is approving from a
   phone while away from a laptop, that default defeats the purpose and
   should be relaxed to an explicit opt-in flag.
2. **Ingestion default** (D2). I defaulted to polling because it needs no
   inbound exposure. If low latency matters more than attack surface, the
   webhook endpoint should become the documented default instead.
