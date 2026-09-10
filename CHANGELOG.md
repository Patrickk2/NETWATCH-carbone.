# Changelog

## 1.3.1

Stabilization release under active development.

### Correctness and security

- corrected the canonical repository URL;
- made `1.3.1` the authoritative script version;
- replaced weak IPv4 validation with `ipaddress`;
- fixed machine-readable JSON/CSV output;
- made scan diagnostics go to stderr;
- added ownership markers for IPv4 and IPv6 Netfilter chains;
- added IPv4 firewall rollback on partial rule failure;
- made block/unblock state updates occur only after successful firewall application;
- hardened ARP-spoof PID termination checks;
- made IPv4 persistence failures explicit;
- hardened router host/user/port/key validation and SSH host-key verification;
- stopped update-check failures from returning success;
- kept automatic self-update disabled;
- explicitly marked QoS throttling unavailable instead of advertising an unimplemented feature;
- implemented ownership-aware IPv4 and IPv6 reset behavior.

### Tests and CI

- added validation, CLI, output, firewall, IPv6, and router regression tests;
- added mocked destructive-system command testing;
- added GitHub Actions syntax, ShellCheck, and test execution.

### Known repository limitation

The published GitHub release `v1.3.0` predates these corrections and cannot be rewritten through the current repository automation interface. Its release notes should therefore be treated as historical until the next release is published.
