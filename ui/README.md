# NETWATCH TUI

The professional terminal interface is an optional presentation layer over the existing NETWATCH Bash command surface.

## Launch

From the repository root:

```bash
python3 ui/netwatch_tui.py
```

The `netwatch-ui` launcher is also included:

```bash
bash netwatch-ui
```

No Python package dependency is required. The implementation uses the Python standard library `curses` module.

## Navigation

`↑` / `↓` or `j` / `k` navigate devices.

`Enter` opens device details.

`/` filters devices by IP, MAC, hostname, vendor, or state.

`b` blocks, `u` unblocks, `i` runs identification, `r` refreshes.

`?` opens help. `Esc` returns to the dashboard. `q` quits.

## Security boundary

The TUI does not implement firewall or router mutations itself. It invokes:

- `netwatch.sh` for IPv4 scan, identification, block, unblock, and reset operations;
- `netwatch-ipv6.sh` for IPv6 discovery;
- `netwatch-router.sh` for router status.

That preserves existing validation, ownership checks, and SSH host-key policy in the core scripts.

## Machine-readable output

The TUI never replaces or decorates the existing `scan json` / `scan csv` modes. Those remain CLI interfaces intended for scripts and automation.
