# Security Policy

## Scope

NETWATCH is a Linux network administration tool. Its network-control functions are intended only for systems and networks that the operator owns or is explicitly authorized to administer.

## Security boundaries

NETWATCH is designed to:

- reject invalid network targets before privileged commands;
- never intentionally block the configured default gateway;
- modify only chains explicitly marked as NETWATCH-owned;
- avoid `eval`;
- avoid automatic execution of downloaded update code;
- verify ARP-spoof process identity before termination;
- require explicit SSH host-key verification in the router bridge;
- keep runtime state out of version control.

These controls are defense-in-depth, not a guarantee that every Linux or router configuration is safe.

## Reporting

For suspected vulnerabilities, contact the repository maintainer privately rather than publishing credentials, private keys, network captures, or a weaponized proof of concept in a public issue.

Include the affected version, operating system/distribution, affected command, reproducible steps, and the expected versus actual behavior.

## Supported versions

The current stabilization line is **1.3.x**. Older versions may lack security and correctness fixes.
