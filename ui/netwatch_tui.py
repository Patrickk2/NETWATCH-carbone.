#!/usr/bin/env python3
"""NETWATCH professional terminal UI.

Thin UI layer over the existing Bash command surface.  The TUI performs only
read-only presentation itself; control operations are delegated to the
existing scripts so firewall, IPv4/IPv6 and router safety checks remain in one
place.
"""
from __future__ import annotations

import curses
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWATCH = ROOT / "netwatch.sh"
NETWATCH6 = ROOT / "netwatch-ipv6.sh"
ROUTER = ROOT / "netwatch-router.sh"
VERSION = "1.3.1"

# Semantic palette.  All important statuses also include text labels.
C = {
    "bg": 1,
    "panel": 2,
    "border": 3,
    "text": 4,
    "muted": 5,
    "accent": 6,
    "success": 7,
    "warning": 8,
    "danger": 9,
    "info": 10,
}


@dataclass
class Device:
    ip: str
    mac: str = "--"
    hostname: str = "-"
    vendor: str = "-"
    state: str = "ACTIVE"


@dataclass
class NetState:
    iface: str = "unknown"
    ipv4: str = "unavailable"
    gateway: str = "unavailable"
    ipv6: str = "unavailable"
    forwarding: str = "disabled"
    firewall: str = "unknown"
    status: str = "DEGRADED"


class CommandError(RuntimeError):
    def __init__(self, command: list[str], rc: int, stderr: str):
        self.command = command
        self.rc = rc
        self.stderr = stderr.strip()
        super().__init__(self.stderr or f"command exited with status {rc}")


def run_cmd(args: list[str], timeout: float = 12.0, *, input_text: str | None = None) -> str:
    try:
        p = subprocess.run(
            args,
            cwd=ROOT,
            text=True,
            input=input_text,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise CommandError(args, 127, str(exc)) from exc
    except subprocess.TimeoutExpired as exc:
        raise CommandError(args, 124, f"Command timed out after {timeout:.0f}s") from exc
    if p.returncode != 0:
        raise CommandError(args, p.returncode, p.stderr or p.stdout)
    return p.stdout


def ip_route() -> tuple[str, str]:
    try:
        out = run_cmd(["ip", "-4", "route", "show", "default"], 3.0)
        parts = out.splitlines()[0].split()
        return parts[4], parts[2]
    except (CommandError, IndexError):
        return "unknown", "unavailable"


def local_ipv4(iface: str) -> str:
    try:
        out = run_cmd(["ip", "-4", "addr", "show", "dev", iface], 3.0)
        match = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", out)
        return match.group(1) if match else "unavailable"
    except CommandError:
        return "unavailable"


def local_ipv6(iface: str) -> str:
    try:
        out = run_cmd(["ip", "-6", "addr", "show", "dev", iface, "scope", "global"], 3.0)
        match = re.search(r"\binet6\s+([^/\s]+)", out)
        return match.group(1) if match else "unavailable"
    except CommandError:
        return "unavailable"


def forwarding_state() -> str:
    try:
        return "enabled" if Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() == "1" else "disabled"
    except OSError:
        return "unknown"


def firewall_state() -> str:
    try:
        out = run_cmd(["iptables", "-S", "NETWATCH_BLOCK"], 3.0)
    except CommandError:
        return "NOT PRESENT"
    return "ACTIVE · NETWATCH-OWNED" if "NETWATCH-owner" in out else "UNSAFE · UNOWNED"


def state_dir() -> Path:
    custom = os.environ.get("NETWATCH_CONFIG")
    if custom:
        return Path(custom)
    if os.geteuid() == 0:
        return Path("/etc/netwatch")
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "netwatch"


def count_lines(name: str) -> int:
    path = state_dir() / name
    try:
        return sum(1 for line in path.read_text().splitlines() if line.strip())
    except OSError:
        return 0


def load_devices() -> list[Device]:
    try:
        data = json.loads(run_cmd([str(NETWATCH), "scan", "json"], 20.0))
    except (CommandError, json.JSONDecodeError):
        return []
    return [
        Device(
            ip=str(item.get("ip", "--")),
            mac=str(item.get("mac", "--")),
            hostname=str(item.get("hostname", "-")),
            vendor=str(item.get("vendor", "-")),
            state="ACTIVE",
        )
        for item in data
        if isinstance(item, dict)
    ]


def load_network() -> NetState:
    iface, gateway = ip_route()
    state = NetState(
        iface=iface,
        ipv4=local_ipv4(iface) if iface != "unknown" else "unavailable",
        gateway=gateway,
        ipv6=local_ipv6(iface) if iface != "unknown" else "unavailable",
        forwarding=forwarding_state(),
        firewall=firewall_state(),
    )
    blockers = count_lines("blocked_ips")
    if state.iface == "unknown":
        state.status = "DEGRADED"
    elif state.firewall.startswith("UNSAFE"):
        state.status = "ERROR"
    else:
        state.status = "READY"
    if blockers:
        state.status = "ACTIVE"
    return state


def wrapped(text: str, width: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    line = ""
    for word in words:
        if len(line) + len(word) + 1 <= max(1, width):
            line = f"{line} {word}".strip()
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines or [""]


def add_pair(win: curses.window, y: int, x: int, label: str, value: str, label_attr: int = 0) -> None:
    win.addstr(y, x, label[:24], label_attr | curses.color_pair(C["muted"]))
    win.addstr(value, curses.color_pair(C["text"]))


class UI:
    def __init__(self, stdscr: curses.window) -> None:
        self.stdscr = stdscr
        self.devices: list[Device] = []
        self.net = NetState()
        self.mode = "DASHBOARD"
        self.running = True
        self.selected = 0
        self.search = ""
        self.log_lines: list[str] = []
        self.last_action = "READY"
        self.last_action_detail = "No operation running."
        self.detail: Device | None = None
        self.status_until = 0.0
        self.refresh_all(initial=True)

    def setup(self) -> None:
        curses.curs_set(0)
        self.stdscr.keypad(True)
        self.stdscr.timeout(250)
        curses.start_color()
        curses.use_default_colors()
        for idx in range(1, 11):
            curses.init_pair(idx, curses.COLOR_WHITE, -1)
        curses.init_pair(C["muted"], curses.COLOR_CYAN, -1)
        curses.init_pair(C["accent"], curses.COLOR_BLUE, -1)
        curses.init_pair(C["success"], curses.COLOR_GREEN, -1)
        curses.init_pair(C["warning"], curses.COLOR_YELLOW, -1)
        curses.init_pair(C["danger"], curses.COLOR_RED, -1)
        curses.init_pair(C["info"], curses.COLOR_CYAN, -1)

    def log(self, kind: str, message: str) -> None:
        timestamp = time.strftime("%H:%M:%S")
        self.log_lines.append(f"{timestamp}  {kind:<10} {message}")
        self.log_lines = self.log_lines[-200:]

    def status(self, state: str, detail: str, seconds: float = 4.0) -> None:
        self.last_action = state
        self.last_action_detail = detail
        self.status_until = time.monotonic() + seconds

    @property
    def visible_devices(self) -> list[Device]:
        q = self.search.strip().lower()
        if not q:
            return self.devices
        return [
            d for d in self.devices if q in " ".join([d.ip, d.mac, d.hostname, d.vendor, d.state]).lower()
        ]

    def refresh_all(self, initial: bool = False) -> None:
        self.net = load_network()
        self.devices = load_devices()
        self.log("NETWORK", f"{len(self.devices)} devices discovered")
        if not initial:
            self.status("READY", f"Network state refreshed · {len(self.devices)} devices")

    def clear_screen(self) -> None:
        self.stdscr.erase()

    def panel(self, y: int, x: int, h: int, w: int, title: str) -> curses.window:
        win = self.stdscr.derwin(max(1, h), max(1, w), y, x)
        win.box()
        if title:
            title_text = f" {title} "
            win.addstr(0, 2, title_text[: max(0, w - 4)], curses.color_pair(C["muted"]) | curses.A_BOLD)
        return win

    def header(self) -> None:
        h, w = self.stdscr.getmaxyx()
        self.stdscr.attrset(curses.color_pair(C["text"]))
        title = "NETWATCH"
        self.stdscr.addstr(0, 2, title, curses.A_BOLD)
        self.stdscr.addstr(0, 12, "NETWORK CONTROL", curses.color_pair(C["muted"]))
        mode = f"MODE  {self.mode}"
        version = f"v{VERSION}"
        status = self.net.status
        status_color = C["success"] if status in {"READY", "ACTIVE"} else C["danger"]
        right = f"{mode}   {status}   {version}"
        if len(right) < w - 16:
            self.stdscr.addstr(0, w - len(right) - 2, right, curses.color_pair(status_color) | curses.A_BOLD)
        self.stdscr.addstr(1, 2, "─" * max(1, w - 4), curses.color_pair(C["border"]))

    def footer(self) -> None:
        h, w = self.stdscr.getmaxyx()
        y = h - 2
        self.stdscr.addstr(y, 2, "↑↓ Navigate   Enter Select   / Search   r Refresh   ? Help   q Quit", curses.color_pair(C["muted"]))
        self.stdscr.addstr(h - 1, 2, "ESC Back" if self.mode != "DASHBOARD" else "NETWATCH · professional network control", curses.color_pair(C["muted"]))
        self.stdscr.addstr(h - 1, max(2, w - 28), self.last_action[:26], curses.color_pair(C["accent"]) | curses.A_BOLD)

    def dashboard(self) -> None:
        h, w = self.stdscr.getmaxyx()
        left_w = max(42, int(w * 0.42))
        body_h = h - 5
        summary = self.panel(3, 2, min(10, body_h), left_w, "NETWORK")
        add_pair(summary, 2, 2, "Interface       ", self.net.iface)
        add_pair(summary, 3, 2, "IPv4            ", self.net.ipv4)
        add_pair(summary, 4, 2, "Gateway         ", self.net.gateway)
        add_pair(summary, 5, 2, "IPv6            ", self.net.ipv6)
        add_pair(summary, 6, 2, "Forwarding      ", self.net.forwarding.upper())
        fw_attr = curses.color_pair(C["success"] if self.net.firewall.startswith("ACTIVE") else C["danger"])
        summary.addstr(7, 2, "Firewall        ", curses.color_pair(C["muted"]))
        summary.addstr( self.net.firewall[: left_w - 20], fw_attr | curses.A_BOLD)
        summary.addstr(8, 2, "NETWATCH state  ", curses.color_pair(C["muted"]))
        summary.addstr(self.net.status, curses.color_pair(C["success"] if self.net.status in {"READY", "ACTIVE"} else C["danger"]) | curses.A_BOLD)
        stats_x = left_w + 4
        stats_w = max(36, w - stats_x - 2)
        ops = self.panel(3, stats_x, min(10, body_h), stats_w, "OPERATIONS")
        values = [
            ("DEVICES", str(len(self.devices))),
            ("BLOCKED", str(count_lines("blocked_ips"))),
            ("ACTIVE ARP", str(len(list(state_dir().glob("arp_*.pid"))))),
            ("FIREWALL", "OWNED" if self.net.firewall.startswith("ACTIVE") else "CHECK"),
            ("ROUTER", "CONFIGURED" if os.environ.get("NETWATCH_ROUTER_HOST") else "NOT CONFIGURED"),
        ]
        for idx, (label, value) in enumerate(values):
            y = 2 + idx
            ops.addstr(y, 2, f"{label:<14}", curses.color_pair(C["muted"]))
            ops.addstr(value, curses.color_pair(C["text"]) | curses.A_BOLD)
        log_h = max(7, body_h - 11)
        log = self.panel(13, 2, log_h, w - 4, "ACTIVITY")
        recent = self.log_lines[-(log_h - 3):]
        if not recent:
            log.addstr(2, 2, "NO ACTIVITY", curses.color_pair(C["muted"]))
        for idx, line in enumerate(recent):
            log.addnstr(2 + idx, 2, line, w - 8, curses.color_pair(C["text"]))

    def devices_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        body_h = h - 5
        left_w = max(60, int(w * 0.68))
        table = self.panel(3, 2, body_h, left_w, "DEVICES")
        query_label = f"SEARCH  / {self.search}" if self.search else "SEARCH  / to filter"
        table.addnstr(1, 2, query_label, left_w - 4, curses.color_pair(C["muted"]))
        headers = [("ST", 4), ("IP", 17), ("MAC", 20), ("HOSTNAME", 23), ("VENDOR", 14), ("STATE", 10)]
        x = 2
        for label, width in headers:
            table.addnstr(3, x, label, width, curses.color_pair(C["muted"]) | curses.A_BOLD)
            x += width
        table.hline(4, 1, curses.ACS_HLINE, left_w - 2)
        rows = self.visible_devices
        max_rows = body_h - 6
        if not rows:
            text = "NO MATCHES" if self.search else "NO DEVICES DISCOVERED"
            msg = "Clear the filter or run a network scan to populate the device list."
            table.addstr(6, 3, text, curses.color_pair(C["warning"]) | curses.A_BOLD)
            table.addnstr(7, 3, msg, left_w - 6, curses.color_pair(C["muted"]))
        for idx, dev in enumerate(rows[:max_rows]):
            y = 5 + idx
            selected = idx == self.selected
            attr = curses.A_REVERSE | curses.color_pair(C["accent"]) if selected else curses.color_pair(C["text"])
            mark = "●" if dev.state == "ACTIVE" else "○"
            table.addnstr(y, 2, mark, 2, attr)
            table.addnstr(y, 5, dev.ip, 17, attr)
            table.addnstr(y, 22, dev.mac, 20, attr)
            table.addnstr(y, 42, dev.hostname, 23, attr)
            table.addnstr(y, 65, dev.vendor, 14, attr)
            table.addnstr(y, 79, dev.state, 10, attr)
        details_x = left_w + 4
        details_w = w - details_x - 2
        detail = self.panel(3, details_x, body_h, details_w, "DEVICE DETAIL")
        rows = self.visible_devices
        if rows:
            d = rows[min(self.selected, len(rows) - 1)]
            self.detail = d
            pairs = [
                ("IPv4", d.ip), ("MAC", d.mac), ("Hostname", d.hostname), ("Vendor", d.vendor), ("State", d.state),
            ]
            for idx, (label, value) in enumerate(pairs):
                detail.addstr(2 + idx, 2, f"{label:<12}", curses.color_pair(C["muted"]))
                detail.addnstr(2 + idx, 15, value, details_w - 18, curses.color_pair(C["text"]) | curses.A_BOLD)
            detail.addstr(9, 2, "ACTIONS", curses.color_pair(C["muted"]) | curses.A_BOLD)
            detail.addstr(11, 2, "Enter  Open details", curses.color_pair(C["text"]))
            detail.addstr(12, 2, "b      Block", curses.color_pair(C["danger"]) | curses.A_BOLD)
            detail.addstr(13, 2, "u      Unblock", curses.color_pair(C["success"]) | curses.A_BOLD)
            detail.addstr(14, 2, "i      Identify", curses.color_pair(C["info"]) | curses.A_BOLD)
            detail.addstr(15, 2, "r      Rescan", curses.color_pair(C["text"]))
        else:
            detail.addstr(3, 2, "Select a device to inspect its identity and control state.", curses.color_pair(C["muted"]))

    def detail_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        d = self.detail
        panel = self.panel(3, 2, h - 5, w - 4, "DEVICE DETAIL")
        if d is None:
            panel.addstr(2, 2, "NO DEVICE SELECTED", curses.color_pair(C["warning"]) | curses.A_BOLD)
            return
        sections = [
            ("IDENTITY", [("IPv4", d.ip), ("IPv6", "not discovered by IPv4 scan"), ("MAC", d.mac), ("Hostname", d.hostname), ("Vendor", d.vendor)]),
            ("NETWATCH STATE", [("State", d.state), ("Firewall scope", "NETWATCH-owned IPv4 gateway"), ("Persistence", "configured by --persistent"), ("ARP assist", "optional")]),
        ]
        y = 2
        for title, pairs in sections:
            panel.addstr(y, 2, title, curses.color_pair(C["muted"]) | curses.A_BOLD)
            y += 1
            for label, value in pairs:
                panel.addstr(y, 4, f"{label:<18}", curses.color_pair(C["muted"]))
                panel.addnstr(y, 23, value, w - 30, curses.color_pair(C["text"]) | curses.A_BOLD)
                y += 1
            y += 1
        panel.addstr(y, 2, "ACTIONS", curses.color_pair(C["muted"]) | curses.A_BOLD)
        y += 2
        panel.addstr(y, 4, "b  BLOCK", curses.color_pair(C["danger"]) | curses.A_BOLD)
        panel.addstr(y + 1, 4, "u  UNBLOCK", curses.color_pair(C["success"]) | curses.A_BOLD)
        panel.addstr(y + 2, 4, "i  IDENTIFY", curses.color_pair(C["info"]) | curses.A_BOLD)
        panel.addstr(y + 3, 4, "r  RESCAN", curses.color_pair(C["text"]) | curses.A_BOLD)
        panel.addstr(y + 4, 4, "ESC  BACK", curses.color_pair(C["muted"]))

    def help_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        p = self.panel(3, 2, h - 5, w - 4, "HELP")
        groups = [
            ("NAVIGATION", ["↑ ↓   Navigate", "Enter Select", "Esc   Back"]),
            ("DEVICES", ["b     Block", "u     Unblock", "i     Identify", "r     Refresh"]),
            ("GLOBAL", ["/     Search", "?     Help", "q     Quit"]),
        ]
        y = 2
        for title, items in groups:
            p.addstr(y, 3, title, curses.color_pair(C["muted"]) | curses.A_BOLD)
            y += 1
            for item in items:
                p.addstr(y, 5, item, curses.color_pair(C["text"]))
                y += 1
            y += 1
        p.addstr(y + 1, 3, "Security-sensitive operations always require intentional confirmation.", curses.color_pair(C["warning"]))

    def firewall_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        p = self.panel(3, 2, h - 5, w - 4, "FIREWALL STATE")
        p.addstr(2, 2, "IPv4 FIREWALL", curses.color_pair(C["muted"]) | curses.A_BOLD)
        p.addstr(3, 4, "Chain", curses.color_pair(C["muted"]))
        p.addstr(3, 22, "NETWATCH_BLOCK", curses.color_pair(C["text"]) | curses.A_BOLD)
        p.addstr(4, 4, "Ownership", curses.color_pair(C["muted"]))
        p.addstr(4, 22, "NETWATCH-owner", curses.color_pair(C["success"]) | curses.A_BOLD)
        p.addstr(5, 4, "State", curses.color_pair(C["muted"]))
        p.addstr(5, 22, self.net.firewall, curses.color_pair(C["success"] if self.net.firewall.startswith("ACTIVE") else C["danger"]) | curses.A_BOLD)
        p.addstr(7, 2, "IPv6 FIREWALL", curses.color_pair(C["muted"]) | curses.A_BOLD)
        try:
            v6 = run_cmd(["ip6tables", "-S", "NETWATCH6_BLOCK"], 3.0)
            v6_owned = "NETWATCH6-owner" in v6
            p.addstr(8, 4, "Chain", curses.color_pair(C["muted"]))
            p.addstr(8, 22, "NETWATCH6_BLOCK", curses.color_pair(C["text"]) | curses.A_BOLD)
            p.addstr(9, 4, "Ownership", curses.color_pair(C["muted"]))
            p.addstr(9, 22, "NETWATCH6-owner" if v6_owned else "UNOWNED", curses.color_pair(C["success"] if v6_owned else C["danger"]))
            p.addstr(10, 4, "State", curses.color_pair(C["muted"]))
            p.addstr(10, 22, "ACTIVE" if v6_owned else "CHECK", curses.color_pair(C["success"] if v6_owned else C["warning"]) | curses.A_BOLD)
        except CommandError:
            p.addstr(8, 4, "State", curses.color_pair(C["muted"]))
            p.addstr(8, 22, "NOT PRESENT", curses.color_pair(C["muted"]))
        p.addstr(13, 2, "Ownership policy", curses.color_pair(C["muted"]) | curses.A_BOLD)
        for idx, text in enumerate([
            "NETWATCH modifies only explicitly ownership-marked chains.",
            "Unrelated chains are never treated as NETWATCH resources.",
            "Reset removes NETWATCH state only after ownership validation.",
        ]):
            p.addnstr(14 + idx, 4, text, w - 12, curses.color_pair(C["text"]))

    def ipv6_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        p = self.panel(3, 2, h - 5, w - 4, "IPV6")
        p.addstr(2, 2, "INTERFACE", curses.color_pair(C["muted"]))
        p.addstr(2, 20, self.net.iface, curses.color_pair(C["text"]) | curses.A_BOLD)
        p.addstr(3, 2, "ADDRESS", curses.color_pair(C["muted"]))
        p.addstr(3, 20, self.net.ipv6, curses.color_pair(C["text"]) | curses.A_BOLD)
        try:
            raw = run_cmd([str(NETWATCH6), "scan", "json"], 15.0)
            rows = json.loads(raw)
        except (CommandError, json.JSONDecodeError):
            rows = []
        p.addstr(5, 2, "NEIGHBORS", curses.color_pair(C["muted"]) | curses.A_BOLD)
        p.addstr(6, 4, "IPv6 Address", curses.color_pair(C["muted"]))
        p.addstr(6, 48, "MAC", curses.color_pair(C["muted"]))
        p.addstr(6, 69, "State", curses.color_pair(C["muted"]))
        for idx, row in enumerate(rows[: max(1, h - 12)]):
            p.addnstr(7 + idx, 4, str(row.get("ipv6", "--")), 44, curses.color_pair(C["text"]))
            p.addnstr(7 + idx, 48, str(row.get("mac", "--")), 20, curses.color_pair(C["text"]))
            p.addnstr(7 + idx, 69, str(row.get("state", "--")), 14, curses.color_pair(C["text"]))
        if not rows:
            p.addstr(7, 4, "NO IPV6 NEIGHBORS DISCOVERED", curses.color_pair(C["muted"]))

    def router_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        p = self.panel(3, 2, h - 5, w - 4, "ROUTER")
        host = os.environ.get("NETWATCH_ROUTER_HOST", "not configured")
        user = os.environ.get("NETWATCH_ROUTER_USER", "not configured")
        port = os.environ.get("NETWATCH_ROUTER_PORT", "22")
        key = os.environ.get("NETWATCH_ROUTER_KEY", "not configured")
        vals = [("Host", host), ("User", user), ("Port", port), ("Auth", "SSH key" if key != "not configured" else "not configured"), ("SSH key", key)]
        for idx, (label, value) in enumerate(vals):
            p.addstr(2 + idx, 3, f"{label:<12}", curses.color_pair(C["muted"]))
            p.addnstr(2 + idx, 18, value, w - 24, curses.color_pair(C["text"]) | curses.A_BOLD)
        p.addstr(9, 3, "HOST-KEY VERIFICATION", curses.color_pair(C["muted"]) | curses.A_BOLD)
        try:
            result = run_cmd([str(ROUTER), "check"], 8.0)
            verified = "StrictHostKeyChecking=yes" in result or "StrictHostKeyChecking=yes" in open_router_help()
            text = "VERIFIED POLICY" if verified else "CHECK POLICY"
            attr = C["success"] if verified else C["warning"]
        except CommandError:
            text = "UNAVAILABLE / CHECK CONFIG"
            attr = C["warning"]
        p.addstr(10, 5, text, curses.color_pair(attr) | curses.A_BOLD)
        p.addstr(12, 3, "Router operations are administrator-supplied SSH commands and remain outside UI business logic.", curses.color_pair(C["muted"]))

    def run_action(self, command: list[str], success_label: str, timeout: float = 35.0) -> None:
        self.status("APPLYING", f"Running {shlex.join(command)}")
        self.log("ACTION", shlex.join(command))
        self.draw()
        self.stdscr.refresh()
        curses.def_prog_mode()
        curses.endwin()
        try:
            full = command
            if os.geteuid() != 0 and command[1:2] in {("block",), ("unblock",), ("reset",)}:
                full = ["sudo", *command]
            result = subprocess.run(full, cwd=ROOT, text=True, capture_output=True, check=False, timeout=timeout)
            output = (result.stdout or result.stderr or "").strip().splitlines()
            if result.returncode == 0:
                self.status("READY", success_label)
                self.log("SUCCESS", success_label)
            else:
                cause = output[-1] if output else f"exit status {result.returncode}"
                self.status("FAILED", cause, 8.0)
                self.log("ERROR", cause)
        except subprocess.TimeoutExpired:
            self.status("FAILED", "Operation timed out", 8.0)
            self.log("ERROR", "Operation timed out")
        finally:
            self.stdscr.refresh()
            self.refresh_all()
            curses.reset_prog_mode()
            curses.curs_set(0)

    def confirm(self, title: str, lines: list[str], destructive: bool = False) -> bool:
        h, w = self.stdscr.getmaxyx()
        box_h = min(h - 4, 12 + len(lines))
        box_w = min(w - 6, max(52, max((len(x) for x in lines), default=20) + 8))
        y = (h - box_h) // 2
        x = (w - box_w) // 2
        win = self.stdscr.derwin(box_h, box_w, y, x)
        win.box()
        win.addstr(1, 2, title, curses.color_pair(C["danger"] if destructive else C["warning"]) | curses.A_BOLD)
        for idx, line in enumerate(lines[: box_h - 5]):
            win.addnstr(3 + idx, 2, line, box_w - 4, curses.color_pair(C["text"]))
        win.addstr(box_h - 2, 2, "Enter Confirm    Esc Cancel", curses.color_pair(C["muted"]))
        win.refresh()
        while True:
            key = self.stdscr.getch()
            if key in (10, 13):
                return True
            if key == 27:
                return False

    def search_prompt(self) -> None:
        h, w = self.stdscr.getmaxyx()
        curses.curs_set(1)
        prompt = "/ "
        self.stdscr.addstr(h - 3, 2, prompt, curses.color_pair(C["accent"]) | curses.A_BOLD)
        curses.echo()
        try:
            raw = self.stdscr.getstr(h - 3, 4, max(1, w - 8)).decode(errors="replace")
        finally:
            curses.noecho()
            curses.curs_set(0)
        self.search = raw.strip()
        self.selected = 0
        self.mode = "DEVICES"

    def draw(self) -> None:
        self.clear_screen()
        self.header()
        if self.mode == "DASHBOARD":
            self.dashboard()
        elif self.mode == "DEVICES":
            self.devices_view()
        elif self.mode == "DETAIL":
            self.detail_view()
        elif self.mode == "FIREWALL":
            self.firewall_view()
        elif self.mode == "IPV6":
            self.ipv6_view()
        elif self.mode == "ROUTER":
            self.router_view()
        elif self.mode == "HELP":
            self.help_view()
        self.footer()
        if self.status_until and time.monotonic() > self.status_until:
            self.status_until = 0
            self.last_action = "READY"
            self.last_action_detail = "No operation running."
        self.stdscr.refresh()

    def choose_device_action(self, action: str) -> None:
        rows = self.visible_devices
        if not rows:
            return
        d = rows[min(self.selected, len(rows) - 1)]
        self.detail = d
        if action == "detail":
            self.mode = "DETAIL"
        elif action in {"block", "unblock"}:
            target = d.ip
            label = "BLOCK" if action == "block" else "UNBLOCK"
            lines = [
                f"Target:     {d.ip}",
                f"MAC:        {d.mac}",
                "Scope:      IPv4 gateway firewall",
                "Resources:  NETWATCH-owned state only",
                "",
                ("This will install a firewall block." if action == "block" else "This will remove the NETWATCH-owned block."),
            ]
            if self.confirm(label, lines, destructive=action == "block"):
                self.run_action([str(NETWATCH), action, target], f"{label} completed for {target}")
        elif action == "identify":
            self.run_action([str(NETWATCH), "identify", d.ip], f"Identification completed for {d.ip}", 40.0)
        elif action == "refresh":
            self.refresh_all()

    def handle_key(self, key: int) -> None:
        if key == -1:
            return
        if key in (ord("q"), ord("Q")) and self.mode != "HELP":
            self.running = False
            return
        if key == ord("?"):
            self.mode = "HELP"
            return
        if key == 27:
            if self.mode == "DASHBOARD":
                return
            self.mode = "DASHBOARD"
            self.search = ""
            return
        if key == ord("/"):
            self.search_prompt()
            return
        if key == ord("r"):
            if self.mode in {"DEVICES", "DETAIL"}:
                self.choose_device_action("refresh")
            else:
                self.refresh_all()
            return
        if self.mode == "DASHBOARD":
            if key in (10, 13):
                self.mode = "DEVICES"
            elif key == ord("1"):
                self.mode = "DEVICES"
            elif key == ord("2"):
                self.mode = "IPV6"
            elif key == ord("3"):
                self.mode = "FIREWALL"
            elif key == ord("4"):
                self.mode = "ROUTER"
        elif self.mode == "DEVICES":
            rows = self.visible_devices
            if key in (curses.KEY_UP, ord("k")) and rows:
                self.selected = max(0, self.selected - 1)
            elif key in (curses.KEY_DOWN, ord("j")) and rows:
                self.selected = min(len(rows) - 1, self.selected + 1)
            elif key in (10, 13):
                self.choose_device_action("detail")
            elif key == ord("b"):
                self.choose_device_action("block")
            elif key == ord("u"):
                self.choose_device_action("unblock")
            elif key == ord("i"):
                self.choose_device_action("identify")
        elif self.mode == "DETAIL":
            if key == ord("b"):
                self.choose_device_action("block")
            elif key == ord("u"):
                self.choose_device_action("unblock")
            elif key == ord("i"):
                self.choose_device_action("identify")

    def loop(self) -> None:
        self.setup()
        while self.running:
            self.draw()
            try:
                key = self.stdscr.getch()
            except KeyboardInterrupt:
                break
            self.handle_key(key)


def open_router_help() -> str:
    try:
        return run_cmd([str(ROUTER), "help"], 4.0)
    except CommandError as exc:
        return exc.stderr


def main() -> int:
    if not NETWATCH.exists():
        print(f"NETWATCH core not found: {NETWATCH}", file=sys.stderr)
        return 2
    try:
        curses.wrapper(lambda stdscr: UI(stdscr).loop())
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
