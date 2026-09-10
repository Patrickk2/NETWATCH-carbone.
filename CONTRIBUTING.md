# Contributing to NETWATCH

NETWATCH is a Linux-only Bash project. Contributions should preserve a small, auditable implementation and should prefer correctness over feature count.

## Engineering rules

Follow these priorities:

1. correctness;
2. security;
3. simplicity;
4. maintainability;
5. optimization only after verification.

Do not rewrite NETWATCH in another language or add Windows, PowerShell, Android, or Termux implementations.

Never introduce `eval`, unsafe shell interpolation, silent error swallowing, or insecure SSH host-key handling.

Never claim a capability is implemented unless the code and tests prove it.

## Before changing code

Inspect:

```bash
git status
git diff
git log --oneline -10
```

Read the relevant script completely and identify the smallest correct change.

## Verification

Always run:

```bash
bash -n netwatch.sh netwatch-ipv6.sh netwatch-router.sh
shellcheck netwatch.sh netwatch-ipv6.sh netwatch-router.sh
```

and the relevant test scripts under `tests/`.

Destructive firewall behavior must be tested through mocks. Do not run regression tests against an unauthorized or production network.

## Test expectations

When changing validation, firewall, state, output, router, or update behavior, add or update a regression test.

Important cases include:

- invalid addresses and malformed MACs;
- `block`/`unblock` idempotency;
- duplicate rules;
- partial firewall failure and rollback;
- ownership rejection for unrelated chains;
- dry-run non-modification;
- JSON/CSV parsing;
- stale PID files and PID reuse;
- router argument boundaries;
- SSH connection failures;
- missing dependencies.

## Documentation

Update `README.md` and command help whenever user-facing behavior changes.

Mark functionality explicitly as implemented, unavailable, experimental, gateway-only, or root-required.

## Security issues

Do not disclose exploitable security details in public issues when private reporting is practical. See `SECURITY.md`.

## Git hygiene

Do not force-push, skip hooks, modify global/local Git configuration, or create empty commits. Stage only intended files and use descriptive commit messages.
