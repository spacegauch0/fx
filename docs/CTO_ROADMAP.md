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
| 1. Project memory (facts, decisions, outcomes) | M3 |
| 2. GitHub ingestion service — signature verification | Done (M2) |
| 2. GitHub ingestion service — listener / polling | M5 |
| 3. Planning and supervision | M4 |
| 4. Version activation and rollback | M3 |
| 5. Long-running control plane | M5 |
| 6. Telegram transport | M6 |
| 7. Proactive loop | M7 |

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

### M3 — Activation, rollback, and memory

The largest gap between the demo and its thesis: `approve()` currently
flips a JSON field and nothing becomes live.

- `.cto/versions/<n>/` holds a materialized approved worktree.
- `.cto/current` is a symlink; activation is an atomic rename-swap.
- Health-check (`zig build` + `zig build test` in the materialized copy)
  runs *before* the swap; failure aborts without touching `current`.
- `fx cto rollback` restores the previous version; the prior known-good
  is always retained.
- Source branches and human git history are never rewritten.
- `.cto/memory.jsonl` per D6, written on task completion and approval.

*Done when:* approve → activate → health-check → rollback round-trips in
a real repo, and a candidate that fails its health check leaves `current`
untouched.

### M4 — Supervision

- Subprocess worker dispatch per D3.
- Per-run timeout and deadline; bounded, truncated log capture into
  `.cto/runs/<id>.log`.
- Retry with backoff, capped, recorded per attempt.
- Real cancellation: `/interrupt <id>` signals the child's process group,
  marks the run `.interrupted`, and leaves the worktree for inspection.

*Done when:* `/interrupt` stops a real running worker, a timeout is
indistinguishable in the audit trail from a cancellation only by its
recorded reason, and no orphan child survives daemon shutdown.

### M5 — Daemon and control plane

- `fx cto daemon` — foreground, supervised-friendly, structured logs.
- Single-writer lock per D4.
- Unix control socket per D2, speaking newline-delimited JSON.
- Loopback webhook endpoint (opt-in) and the polling alternative
  (default).
- `/health` and `/ready`.
- CLI auto-detects a running daemon and proxies to it.

*Done when:* the daemon survives terminal exit, a second writer is
refused rather than corrupting state, and every existing `fx cto`
command works identically with and without a daemon running.

### M6 — Telegram transport

Long polling by default (outbound only). Chat-ID allowlist. Token from
the secret store. Parsed `channel.Command` → control socket. Concise
approval requests and failure notices. D5's restriction enforced kernel-
side, not just in the bot.

*Done when:* an allowlisted chat can drive every read command and a
non-allowlisted chat gets nothing, proven without a live bot token.

### M7 — Proactive loop

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
