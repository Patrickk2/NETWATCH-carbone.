# NETWATCH UI Design System

The TUI uses a quiet, information-dense terminal language designed for network administration and security operations.

## Visual principles

- Information hierarchy over decoration.
- Status is communicated with a label plus restrained semantic color; never color alone.
- Technical identifiers are aligned and visually distinct from explanatory text.
- Destructive actions require an intentional confirmation step.
- The UI never owns firewall, ARP, IPv6, or router business logic; it delegates to the existing command layer.
- Human UI output is separate from machine-readable CLI output.

## Layout

Every screen follows one application shell:

```text
NETWATCH  NETWORK CONTROL              MODE  <SCREEN>  <STATUS>  v<VERSION>
────────────────────────────────────────────────────────────────────────────

[ primary content / contextual detail ]

────────────────────────────────────────────────────────────────────────────
↑↓ Navigate   Enter Select   / Search   r Refresh   ? Help   q Quit
ESC Back
```

Base spacing is 1 terminal cell inside panels and 2 cells between major regions. Screens use the same top bar and footer regardless of content.

## Semantic states

| State | Meaning | Treatment |
| --- | --- | --- |
| READY | healthy, idle | success text, restrained green |
| ACTIVE | NETWATCH control is active | success text |
| SCANNING | discovery in progress | info text |
| CONNECTING | router/network connection in progress | info text |
| APPLYING | control operation being applied | accent/info text |
| DEGRADED | expected capability is unavailable | warning text |
| FAILED | requested operation failed | danger text |
| ERROR | unsafe/unexpected state | danger text |
| DRY RUN | no system changes will be applied | warning text and explicit label |

## Palette

The curses implementation deliberately uses terminal-native named colors rather than hard-coded RGB values so it follows the user's terminal theme.

- Text: default foreground / high readability.
- Muted: cyan/secondary information.
- Accent: blue/selection and active navigation.
- Success: green/healthy or completed operations.
- Warning: yellow/attention and destructive confirmations.
- Danger: red/failed or destructive state.
- Info: cyan/technical progress.

Color is paired with words such as `READY`, `FAILED`, `OWNED`, `UNOWNED`, `BLOCK`, and `CANCEL`.

## Typography

Terminal-native monospace is the source of truth. Alignment uses fixed columns for IP, MAC, hostname, vendor, and state. Technical identifiers remain unwrapped wherever practical; explanatory copy wraps and is allowed to reduce secondary detail first on small terminals.

## Components

### Header

Persistent identity, screen/mode, global state, and version.

### Panel

Single bordered region with a short uppercase title. Panels are used for grouping, not decoration.

### Table

Fixed headers, aligned columns, visible selection, and predictable row navigation. Avoid dense box-drawing grids between every row.

### Status

Text label plus semantic treatment. Examples: `READY`, `ACTIVE`, `DEGRADED`, `FAILED`.

### Confirmation dialog

Explicit target, scope, owned resources, and action. Confirm with Enter, cancel with Escape.

### Empty state

Every empty collection states why it is empty and gives the next useful action.

### Footer

Only the shortcuts relevant to the current context are shown; global shortcuts remain stable.

## Screen architecture

- **DASHBOARD** — network identity, key operational counts, recent activity.
- **DEVICES** — searchable/scannable device table plus contextual detail pane.
- **DETAIL** — full identity, NETWATCH state, scope, and actions.
- **FIREWALL** — explicit IPv4/IPv6 chain and ownership state.
- **IPV6** — interface, global address, and neighbor discovery.
- **ROUTER** — SSH target and host-key verification posture.
- **HELP** — concise keyboard reference and security interaction note.

## Responsive behavior

Target sizes: 80×24, 100×30, 120×40, 160×50.

The first priority at small sizes is: status, target identity, essential action, and error/recovery information. Secondary vendor/hostname/detail content is the first thing to collapse.

## Security UX rules

- Never imply host-key verification can be skipped.
- Never silently expand a NETWATCH operation to unrelated firewall resources.
- Never make block/reset equivalent to an unconfirmed one-key action.
- Show scope (`IPv4`, `IPv6`, `gateway firewall`, `NETWATCH-owned`) before confirming changes.
- Failure messages should include cause and rollback/recovery status where the underlying command exposes it.
- The TUI invokes the existing scripts, preserving their validation and ownership checks.
