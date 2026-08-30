# CTO Extensions

This directory is the initial self-modification boundary.

The trusted kernel (`src/cto/kernel.zig`) may allow CTO to propose changes
here without granting permission to rewrite audit, policy, or activation
code. Nothing under `src/cto/kernel.zig`, `src/cto/journal.zig`,
`src/cto/store.zig`, or the approval path in `src/cto/main.zig` should ever
be modified by a self-generated candidate; only a human-reviewed change to
this repository should touch those files.

The first intended self-built extension is:

```text
github.pull_request.merged
```

A future implementation might create:

```text
src/cto/extensions/github_events.zig
```

The connector should:

1. acquire read-only access;
2. observe merged PRs;
3. normalize them into CTO events;
4. preserve provenance;
5. never activate itself;
6. rely on the kernel for approval and version switching.
