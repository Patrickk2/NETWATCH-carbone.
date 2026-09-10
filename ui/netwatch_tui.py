#!/usr/bin/env python3
"""NETWATCH professional terminal UI.

Presentation layer over the existing NETWATCH command surface. Mutating
operations are delegated to the validated shell commands; the TUI does not
implement firewall, ARP, IPv4/IPv6, or SSH business logic itself.
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

C = {"text": 1, "muted": 2, "accent": 3, "success": 4, "warning": 5, "danger": 6, "info": 7}


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
    forwarding: str = "unknown"
    firewall: str = "unknown"
    status: str = "DEGRADED"


class CommandError(RuntimeError):
    def __init__(self, command: list[str], rc: int, detail: str):
        self.command = command
        self.rc = rc
        self.detail = detail.strip()
        super().__init__(self.detail or f"command exited with status {rc}")


def run_cmd(args: list[str], timeout: float = 12.0) -> str:
    try:
        result = subprocess.run(
            args, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False
        )
    except FileNotFoundError as exc:
        raise CommandError(args, 127, str(exc)) from exc
    except subprocess.TimeoutExpired as exc:
        raise CommandError(args, 124, f"Command timed out after {timeout:.0f}s") from exc
    if result.returncode != 0:
        raise CommandError(args, result.returncode, result.stderr or result.stdout)
    return result.stdout


def ip_route() -> tuple[str, str]:
    try:
        line = run_cmd(["ip", "-4", "route", "show", "default"], 3).splitlines()[0].split()
        via = line.index("via")
        dev = line.index("dev")
        return line[dev + 1], line[via + 1]
    except (CommandError, IndexError, ValueError):
        return "unknown", "unavailable"


def interface_ipv4(iface: str) -> str:
    try:
        out = run_cmd(["ip", "-4", "addr", "show", "dev", iface], 3)
    except CommandError:
        return "unavailable"
    match = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", out)
    return match.group(1) if match else "unavailable"


def interface_ipv6(iface: str) -> str:
    try:
        out = run_cmd(["ip", "-6", "addr", "show", "dev", iface, "scope", "global"], 3)
    except CommandError:
        return "unavailable"
    match = re.search(r"\binet6\s+([^/\s]+)", out)
    return match.group(1) if match else "unavailable"


def forwarding_state() -> str:
    try:
        return "enabled" if Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() == "1" else "disabled"
    except OSError:
        return "unknown"


def firewall_state() -> str:
    try:
        out = run_cmd(["iptables", "-S", "NETWATCH_BLOCK"], 3)
    except CommandError:
        return "NOT PRESENT"
    if "NETWATCH-owner" not in out:
        return "UNSAFE - UNOWNED"
    return "ACTIVE - NETWATCH-OWNED"


def state_dir() -> Path:
    custom = os.environ.get("NETWATCH_CONFIG")
    if custom:
        return Path(custom)
    if os.geteuid() == 0:
        return Path("/etc/netwatch")
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "netwatch"


def count_lines(name: str) -> int:
    try:
        return sum(1 for line in (state_dir() / name).read_text().splitlines() if line.strip())
    except OSError:
        return 0


def load_devices() -> tuple[list[Device], str | None]:
    try:
        raw = run_cmd([str(NETWATCH), "scan", "json"], 20)
        payload = json.loads(raw)
    except CommandError as exc:
        return [], exc.detail or f"scan failed with status {exc.rc}"
    except json.JSONDecodeError as exc:
        return [], f"scan returned invalid JSON: {exc}"
    if not isinstance(payload, list):
        return [], "scan returned an unexpected JSON payload"
    devices = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        devices.append(
            Device(
                ip=str(item.get("ip", "--")),
                mac=str(item.get("mac", "--")),
                hostname=str(item.get("hostname", "-")),
                vendor=str(item.get("vendor", "-")),
            )
        )
    return devices, None


def load_network() -> NetState:
    iface, gateway = ip_route()
    state = NetState(
        iface=iface,
        ipv4=interface_ipv4(iface) if iface != "unknown" else "unavailable",
        gateway=gateway,
        ipv6=interface_ipv6(iface) if iface != "unknown" else "unavailable",
        forwarding=forwarding_state(),
        firewall=firewall_state(),
    )
    if iface == "unknown":
        state.status = "DEGRADED"
    elif state.firewall.startswith("UNSAFE"):
        state.status = "ERROR"
    else:
        state.status = "ACTIVE" if count_lines("blocked_ips") else "READY"
    return state


def main_size(win: curses.window) -> tuple[int, int]:
    return win.getmaxyx()


def safe_add(win: curses.window, y: int, x: int, text: str, attr: int = 0, width: int | None = None) -> None:
    h, w = main_size(win)
    if y < 0 or y >= h or x >= w:
        return
    x = max(0, x)
    room = w - x - 1
    if width is not None:
        room = min(room, max(0, width))
    if room <= 0:
        return
    try:
        win.addnstr(y, x, text, room, attr)
    except curses.error:
        pass


def status_attr(state: str) -> int:
    mapping = {"READY": C["success"], "ACTIVE": C["success"], "FAILED": C["danger"], "ERROR": C["danger"], "DEGRADED": C["warning"], "APPLYING": C["info"], "SCANNING": C["info"], "DRY RUN": C["warning"]}
    return curses.color_pair(mapping.get(state, C["text"]))


class UI:
    MODES = ["DASHBOARD", "DEVICES", "IPV6", "FIREWALL", "ROUTER", "LOG", "HELP"]

    def __init__(self, stdscr: curses.window) -> None:
        self.stdscr = stdscr
        self.mode = "DASHBOARD"
        self.running = True
        self.selected = 0
        self.search = ""
        self.devices: list[Device] = []
        self.scan_error: str | None = None
        self.detail: Device | None = None
        self.net = NetState()
        self.logs: list[str] = []
        self.action_state = "READY"
        self.action_detail = "Idle"
        self.toast_until = 0.0
        self.refresh_all(initial=True)

    def setup(self) -> None:
        self.stdscr.keypad(True)
        self.stdscr.nodelay(False)
        self.stdscr.timeout(250)
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        curses.start_color()
        curses.use_default_colors()
        for pair, color in [(C["text"], curses.COLOR_WHITE), (C["muted"], curses.COLOR_CYAN), (C["accent"], curses.COLOR_BLUE), (C["success"], curses.COLOR_GREEN), (C["warning"], curses.COLOR_YELLOW), (C["danger"], curses.COLOR_RED), (C["info"], curses.COLOR_CYAN)]:
            curses.init_pair(pair, color, -1)

    def log(self, kind: str, text: str) -> None:
        self.logs.append(f"{time.strftime('%H:%M:%S')}  {kind:<9} {text}")
        self.logs = self.logs[-300:]

    def set_status(self, state: str, detail: str, seconds: float = 5.0) -> None:
        self.action_state = state
        self.action_detail = detail
        self.toast_until = time.monotonic() + seconds

    def refresh_all(self, initial: bool = False) -> None:
        self.set_status("SCANNING", "Refreshing network and device inventory", 999 if initial else 3)
        self.net = load_network()
        self.devices, self.scan_error = load_devices()
        self.selected = min(self.selected, max(0, len(self.visible_devices) - 1))
        if self.scan_error:
            self.log("ERROR", self.scan_error)
            if not initial:
                self.set_status("FAILED", self.scan_error, 8)
        else:
            self.log("SCAN", f"{len(self.devices)} devices discovered")
            if not initial:
                self.set_status("READY", f"Refresh complete - {len(self.devices)} devices")

    @property
    def visible_devices(self) -> list[Device]:
        q = self.search.strip().lower()
        if not q:
            return self.devices
        return [d for d in self.devices if q in " ".join((d.ip, d.mac, d.hostname, d.vendor, d.state)).lower()]

    def panel(self, y: int, x: int, h: int, w: int, title: str) -> curses.window | None:
        sh, sw = self.stdscr.getmaxyx()
        if h < 3 or w < 6 or y < 0 or x < 0 or y + h > sh or x + w > sw:
            return None
        try:
            win = self.stdscr.derwin(h, w, y, x)
            win.erase()
            win.box()
            safe_add(win, 0, 2, f" {title} ", curses.color_pair(C["muted"]) | curses.A_BOLD, w - 5)
            return win
        except curses.error:
            return None

    def header(self) -> None:
        _, w = self.stdscr.getmaxyx()
        safe_add(self.stdscr, 0, 2, "NETWATCH", curses.A_BOLD)
        safe_add(self.stdscr, 0, 12, "NETWORK CONTROL", curses.color_pair(C["muted"]))
        right = f"MODE {self.mode}  {self.action_state}  v{VERSION}"
        safe_add(self.stdscr, 0, max(2, w - len(right) - 2), right, status_attr(self.action_state) | curses.A_BOLD)
        safe_add(self.stdscr, 1, 2, "-" * max(1, w - 4), curses.color_pair(C["muted"]))

    def footer(self) -> None:
        h, w = self.stdscr.getmaxyx()
        hints = "Up/Down Select  Enter Details  / Search  b Block  u Unblock  i Identify" if self.mode == "DEVICES" else "1 Dashboard  2 Devices  3 IPv6  4 Firewall  5 Router  l Log  ? Help  q Quit"
        safe_add(self.stdscr, h - 2, 2, hints, curses.color_pair(C["muted"]), max(1, w - 4))
        bottom = "Esc Back" if self.mode != "DASHBOARD" else "NETWATCH professional network control"
        safe_add(self.stdscr, h - 1, 2, bottom, curses.color_pair(C["muted"]), max(1, w - 34))
        toast = self.action_detail if time.monotonic() < self.toast_until else "READY"
        safe_add(self.stdscr, h - 1, max(2, w - min(30, len(toast) + 2)), toast, status_attr(self.action_state) | curses.A_BOLD, min(30, w - 4))

    def dashboard(self) -> None:
        h, w = self.stdscr.getmaxyx()
        body_h = h - 5
        if body_h < 8:
            safe_add(self.stdscr, 4, 2, "Terminal too small. Minimum supported size is 80x24.", curses.color_pair(C["warning"]) | curses.A_BOLD)
            return
        gap = 2
        left = max(34, (w - 4 - gap) // 2)
        right = w - 4 - gap - left
        top_h = min(11, body_h // 2)
        net = self.panel(3, 2, top_h, left, "NETWORK")
        if net:
            fields = [("Interface", self.net.iface), ("IPv4", self.net.ipv4), ("Gateway", self.net.gateway), ("IPv6", self.net.ipv6), ("Forwarding", self.net.forwarding.upper()), ("Firewall", self.net.firewall), ("NETWATCH", self.net.status)]
            for idx, (label, value) in enumerate(fields[: max(1, top_h - 2)]):
                safe_add(net, 2 + idx, 2, f"{label:<12} {value}", status_attr(self.net.status) if label == "NETWATCH" else curses.color_pair(C["text"]), left - 5)
        ops = self.panel(3, 2 + left + gap, top_h, right, "OPERATIONS")
        if ops:
            values = [("DEVICES", str(len(self.devices))), ("BLOCKED", str(count_lines("blocked_ips"))), ("ACTIVE ARP", str(len(list(state_dir().glob("arp_*.pid"))))), ("FIREWALL", "OWNED" if self.net.firewall.startswith("ACTIVE") else "CHECK"), ("ROUTER", "CONFIGURED" if os.environ.get("NETWATCH_ROUTER_HOST") else "NOT CONFIGURED")]
            for idx, (label, value) in enumerate(values[: max(1, top_h - 2)]):
                safe_add(ops, 2 + idx, 2, f"{label:<14} {value}", curses.color_pair(C["muted"]) if idx < 4 else curses.color_pair(C["warning"]))
        log_h = body_h - top_h - 1
        log = self.panel(3 + top_h + 1, 2, log_h, w - 4, "ACTIVITY")
        if log:
            if self.scan_error:
                safe_add(log, 2, 2, "SCAN ERROR", curses.color_pair(C["danger"]) | curses.A_BOLD)
                safe_add(log, 3, 2, self.scan_error, curses.color_pair(C["warning"]), w - 10)
            rows = max(1, log_h - 4)
            for idx, line in enumerate(self.logs[-rows:]):
                safe_add(log, 2 + idx, 2, line, curses.color_pair(C["text"]), w - 10)

    def devices_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        body_h = h - 5
        if w < 90:
            table_w = w - 4
            table = self.panel(3, 2, body_h, table_w, "DEVICES")
            if not table:
                return
            safe_add(table, 1, 2, f"SEARCH / {self.search}" if self.search else "SEARCH / to filter", curses.color_pair(C["muted"]), table_w - 4)
            rows = self.visible_devices
            if not rows:
                safe_add(table, 4, 3, "NO MATCHES" if self.search else "NO DEVICES DISCOVERED", curses.color_pair(C["warning"]) | curses.A_BOLD)
                safe_add(table, 5, 3, self.scan_error or "Clear the filter or press r to scan again.", curses.color_pair(C["muted"]), table_w - 8)
                return
            for idx, d in enumerate(rows[: body_h - 5]):
                attr = curses.A_REVERSE | curses.color_pair(C["accent"]) if idx == self.selected else curses.color_pair(C["text"])
                safe_add(table, 3 + idx, 2, f"> {d.ip:<16} {d.mac:<19} {d.hostname:<18} {d.state:<8}", attr, table_w - 4)
            return
        left_w = int(w * 0.64)
        right_w = w - left_w - 6
        table = self.panel(3, 2, body_h, left_w, "DEVICES")
        detail = self.panel(3, left_w + 4, body_h, right_w, "DEVICE DETAIL")
        if not table or not detail:
            return
        safe_add(table, 1, 2, f"SEARCH / {self.search}" if self.search else "SEARCH / to filter", curses.color_pair(C["muted"]), left_w - 4)
        safe_add(table, 3, 2, "ST   IP              MAC                HOSTNAME            VENDOR", curses.color_pair(C["muted"]) | curses.A_BOLD, left_w - 4)
        rows = self.visible_devices
        if not rows:
            safe_add(table, 5, 3, "NO MATCHES" if self.search else "NO DEVICES DISCOVERED", curses.color_pair(C["warning"]) | curses.A_BOLD)
            safe_add(table, 6, 3, self.scan_error or "Clear the filter or press r to scan again.", curses.color_pair(C["muted"]), left_w - 8)
            safe_add(detail, 3, 2, "No device selected.", curses.color_pair(C["muted"]))
            return
        self.selected = min(self.selected, len(rows) - 1)
        self.detail = rows[self.selected]
        for idx, d in enumerate(rows[: body_h - 6]):
            marker = ">" if idx == self.selected else " "
            line = f"{marker} * {d.ip:<15} {d.mac:<18} {d.hostname:<18} {d.vendor:<14}"
            safe_add(table, 4 + idx, 2, line, curses.A_REVERSE | curses.color_pair(C["accent"]) if idx == self.selected else curses.color_pair(C["text"]), left_w - 4)
        d = self.detail
        values = [("IPv4", d.ip), ("MAC", d.mac), ("Hostname", d.hostname), ("Vendor", d.vendor), ("State", d.state)]
        for idx, (label, value) in enumerate(values):
            safe_add(detail, 2 + idx, 2, f"{label:<10} {value}", curses.color_pair(C["text"]) | (curses.A_BOLD if label in {"IPv4", "State"} else 0), right_w - 4)
        safe_add(detail, 9, 2, "ACTIONS", curses.color_pair(C["muted"]) | curses.A_BOLD, right_w - 4)
        for row, text, attr in [(10, "Enter  Open details", C["text"]), (11, "b      Block", C["danger"]), (12, "u      Unblock", C["success"]), (13, "i      Identify", C["info"]), (14, "r      Refresh", C["text"])]:
            safe_add(detail, row, 2, text, curses.color_pair(attr) | curses.A_BOLD, right_w - 4)

    def detail_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        panel = self.panel(3, 2, h - 5, w - 4, "DEVICE DETAIL")
        if not panel:
            return
        d = self.detail
        if not d:
            safe_add(panel, 3, 3, "NO DEVICE SELECTED", curses.color_pair(C["warning"]) | curses.A_BOLD)
            return
        sections = [("IDENTITY", [("IPv4", d.ip), ("IPv6", "not part of IPv4 scan"), ("MAC", d.mac), ("Hostname", d.hostname), ("Vendor", d.vendor)]), ("NETWATCH STATE", [("State", d.state), ("Scope", "IPv4 gateway firewall"), ("Ownership", "NETWATCH-owned"), ("Persistence", "only when requested"), ("ARP assist", "optional")])]
        y = 2
        for title, fields in sections:
            safe_add(panel, y, 3, title, curses.color_pair(C["muted"]) | curses.A_BOLD); y += 1
            for label, value in fields:
                safe_add(panel, y, 5, f"{label:<15} {value}", curses.color_pair(C["text"]), w - 14); y += 1
            y += 1
        safe_add(panel, y, 3, "b BLOCK   u UNBLOCK   i IDENTIFY   r RESCAN   Esc BACK", curses.color_pair(C["muted"]) | curses.A_BOLD, w - 10)

    def firewall_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        panel = self.panel(3, 2, h - 5, w - 4, "FIREWALL STATE")
        if not panel:
            return
        safe_add(panel, 2, 2, "IPv4", curses.color_pair(C["muted"]) | curses.A_BOLD)
        safe_add(panel, 3, 4, "Chain       NETWATCH_BLOCK", curses.color_pair(C["text"]), w - 10)
        safe_add(panel, 4, 4, "Ownership   NETWATCH-owner", curses.color_pair(C["success"]) | curses.A_BOLD, w - 10)
        safe_add(panel, 5, 4, f"State       {self.net.firewall}", status_attr("ACTIVE" if self.net.firewall.startswith("ACTIVE") else "ERROR") | curses.A_BOLD, w - 10)
        safe_add(panel, 7, 2, "IPv6", curses.color_pair(C["muted"]) | curses.A_BOLD)
        try:
            v6 = run_cmd(["ip6tables", "-S", "NETWATCH6_BLOCK"], 3)
            owned = "NETWATCH6-owner" in v6
            safe_add(panel, 8, 4, "Chain       NETWATCH6_BLOCK", curses.color_pair(C["text"]), w - 10)
            safe_add(panel, 9, 4, f"Ownership   {'NETWATCH6-owner' if owned else 'UNOWNED'}", curses.color_pair(C["success"] if owned else C["danger"]) | curses.A_BOLD, w - 10)
            safe_add(panel, 10, 4, f"State       {'ACTIVE' if owned else 'CHECK'}", curses.color_pair(C["success"] if owned else C["warning"]) | curses.A_BOLD, w - 10)
        except CommandError:
            safe_add(panel, 8, 4, "State       NOT PRESENT", curses.color_pair(C["muted"]), w - 10)
        safe_add(panel, 13, 2, "OWNERSHIP POLICY", curses.color_pair(C["muted"]) | curses.A_BOLD)
        for idx, text in enumerate(["NETWATCH modifies only explicitly owned resources.", "Unrelated firewall chains are not managed by the TUI.", "Reset operates only on validated NETWATCH-owned state."]):
            safe_add(panel, 14 + idx, 4, text, curses.color_pair(C["text"]), w - 12)

    def ipv6_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        panel = self.panel(3, 2, h - 5, w - 4, "IPV6")
        if not panel:
            return
        safe_add(panel, 2, 2, f"Interface  {self.net.iface}", curses.color_pair(C["muted"]))
        safe_add(panel, 3, 2, f"Address    {self.net.ipv6}", curses.color_pair(C["text"]) | curses.A_BOLD, w - 6)
        safe_add(panel, 5, 2, "NEIGHBORS", curses.color_pair(C["muted"]) | curses.A_BOLD)
        try:
            rows = json.loads(run_cmd([str(NETWATCH6), "scan", "json"], 15))
            if not isinstance(rows, list):
                rows = []
        except (CommandError, json.JSONDecodeError):
            rows = []
        safe_add(panel, 6, 4, "IPv6 ADDRESS".ljust(46) + "MAC".ljust(22) + "STATE", curses.color_pair(C["muted"]) | curses.A_BOLD, w - 10)
        for idx, row in enumerate(rows[: max(1, h - 13)]):
            if not isinstance(row, dict):
                continue
            line = f"{str(row.get('ipv6','--')):<46}{str(row.get('mac','--')):<22}{str(row.get('state','--'))}"
            safe_add(panel, 7 + idx, 4, line, curses.color_pair(C["text"]), w - 10)
        if not rows:
            safe_add(panel, 7, 4, "NO IPV6 NEIGHBORS DISCOVERED", curses.color_pair(C["muted"]))

    def router_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        panel = self.panel(3, 2, h - 5, w - 4, "ROUTER / SSH")
        if not panel:
            return
        values = [("Host", os.environ.get("NETWATCH_ROUTER_HOST", "not configured")), ("User", os.environ.get("NETWATCH_ROUTER_USER", "not configured")), ("Port", os.environ.get("NETWATCH_ROUTER_PORT", "22")), ("SSH key", os.environ.get("NETWATCH_ROUTER_KEY", "not configured"))]
        for idx, (label, value) in enumerate(values):
            safe_add(panel, 2 + idx, 3, f"{label:<10} {value}", curses.color_pair(C["text"]), w - 10)
        safe_add(panel, 8, 3, "HOST-KEY VERIFICATION", curses.color_pair(C["muted"]) | curses.A_BOLD)
        try:
            policy = run_cmd([str(ROUTER), "help"], 4)
            verified = "StrictHostKeyChecking=yes" in policy
        except CommandError:
            verified = False
        safe_add(panel, 9, 5, "VERIFIED POLICY" if verified else "CHECK CONFIGURATION", curses.color_pair(C["success"] if verified else C["warning"]) | curses.A_BOLD)
        safe_add(panel, 11, 3, "Router actions remain administrator-supplied SSH operations.", curses.color_pair(C["muted"]), w - 10)

    def log_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        panel = self.panel(3, 2, h - 5, w - 4, "OPERATION LOG")
        if not panel:
            return
        for idx, line in enumerate(self.logs[-max(1, h - 9):]):
            safe_add(panel, 2 + idx, 2, line, curses.color_pair(C["text"]), w - 8)

    def help_view(self) -> None:
        h, w = self.stdscr.getmaxyx()
        panel = self.panel(3, 2, h - 5, w - 4, "HELP")
        if not panel:
            return
        lines = [
            ("NAVIGATION", "1 Dashboard | 2 Devices | 3 IPv6 | 4 Firewall | 5 Router | l Log | ? Help"),
            ("DEVICES", "Up/Down or j/k | Enter details | / filter | b block | u unblock | i identify"),
            ("GLOBAL", "r refresh | Esc back | q quit"),
            ("SECURITY", "Block/reset are always explicitly confirmed; scope and ownership are shown first."),
        ]
        for idx, (title, text) in enumerate(lines):
            safe_add(panel, 2 + idx * 3, 3, title, curses.color_pair(C["muted"]) | curses.A_BOLD)
            safe_add(panel, 3 + idx * 3, 5, text, curses.color_pair(C["text"]), w - 12)

    def confirm(self, title: str, lines: list[str], destructive: bool = False) -> bool:
        h, w = self.stdscr.getmaxyx()
        box_h = min(max(8, len(lines) + 6), h - 2)
        box_w = min(max(58, max((len(x) for x in lines), default=20) + 6), w - 2)
        y = max(1, (h - box_h) // 2)
        x = max(1, (w - box_w) // 2)
        try:
            win = self.stdscr.derwin(box_h, box_w, y, x)
            win.erase(); win.box()
            safe_add(win, 1, 2, title, curses.color_pair(C["danger"] if destructive else C["warning"]) | curses.A_BOLD, box_w - 4)
            for idx, line in enumerate(lines[: box_h - 5]):
                safe_add(win, 3 + idx, 2, line, curses.color_pair(C["text"]), box_w - 4)
            safe_add(win, box_h - 2, 2, "Enter Confirm    Esc Cancel", curses.color_pair(C["muted"]) | curses.A_BOLD, box_w - 4)
            win.refresh()
        except curses.error:
            return False
        while True:
            key = self.stdscr.getch()
            if key in (10, 13):
                return True
            if key == 27:
                return False

    def search_prompt(self) -> None:
        h, w = self.stdscr.getmaxyx()
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        curses.echo()
        try:
            safe_add(self.stdscr, h - 3, 2, "/ ", curses.color_pair(C["accent"]) | curses.A_BOLD)
            raw = self.stdscr.getstr(h - 3, 4, max(1, w - 8)).decode(errors="replace")
        finally:
            curses.noecho()
            try:
                curses.curs_set(0)
            except curses.error:
                pass
        self.search = raw.strip()
        self.selected = 0
        self.mode = "DEVICES"

    def choose_device_action(self, action: str) -> None:
        rows = self.visible_devices
        if not rows:
            return
        self.selected = min(self.selected, len(rows) - 1)
        device = rows[self.selected]
        self.detail = device
        if action == "detail":
            self.mode = "DETAIL"; return
        if action == "refresh":
            self.refresh_all(); return
        if action == "identify":
            self.run_action([str(NETWATCH), "identify", device.ip], f"Identification completed for {device.ip}", 40); return
        if action in {"block", "unblock"}:
            label = action.upper()
            lines = [f"Target:     {device.ip}", f"MAC:        {device.mac}", "Scope:      IPv4 gateway firewall", "Resources:  NETWATCH-owned state only", "", "This will modify network state." if action == "block" else "This removes the NETWATCH-owned block."]
            if self.confirm(label, lines, destructive=action == "block"):
                self.run_action([str(NETWATCH), action, device.ip], f"{label} completed for {device.ip}")

    def run_action(self, command: list[str], success_label: str, timeout: float = 35.0) -> None:
        self.set_status("APPLYING", f"Running {shlex.join(command)}", 999)
        self.log("ACTION", shlex.join(command))
        self.draw(); self.stdscr.refresh(); curses.def_prog_mode(); curses.endwin()
        try:
            full = ["sudo", *command] if os.geteuid() != 0 and len(command) > 1 and command[1] in {"block", "unblock", "reset"} else command
            result = subprocess.run(full, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
            output = (result.stdout or result.stderr or "").strip().splitlines()
            if result.returncode == 0:
                self.log("SUCCESS", success_label); self.set_status("READY", success_label)
            else:
                cause = output[-1] if output else f"exit status {result.returncode}"
                self.log("ERROR", f"{cause} (exit {result.returncode})"); self.set_status("FAILED", cause, 8)
        except subprocess.TimeoutExpired:
            self.log("ERROR", "Operation timed out"); self.set_status("FAILED", "Operation timed out", 8)
        finally:
            self.refresh_all(); curses.reset_prog_mode()
            try: curses.curs_set(0)
            except curses.error: pass

    def draw(self) -> None:
        self.stdscr.erase(); self.header()
        if self.mode == "DASHBOARD": self.dashboard()
        elif self.mode == "DEVICES": self.devices_view()
        elif self.mode == "DETAIL": self.detail_view()
        elif self.mode == "IPV6": self.ipv6_view()
        elif self.mode == "FIREWALL": self.firewall_view()
        elif self.mode == "ROUTER": self.router_view()
        elif self.mode == "LOG": self.log_view()
        elif self.mode == "HELP": self.help_view()
        self.footer(); self.stdscr.refresh()

    def handle_key(self, key: int) -> None:
        if key == -1: return
        if key in (ord("q"), ord("Q")) and self.mode != "HELP": self.running = False; return
        if key == ord("?"): self.mode = "HELP"; return
        if key == 27:
            if self.mode == "DASHBOARD": return
            self.mode = "DASHBOARD"; self.search = ""; return
        if key == ord("/"): self.search_prompt(); return
        if key == ord("r"): self.refresh_all(); return
        if key in (ord("1"), ord("2"), ord("3"), ord("4"), ord("5")):
            self.mode = self.MODES[int(chr(key)) - 1]; self.selected = 0; return
        if key == ord("l"): self.mode = "LOG"; return
        if self.mode in {"DEVICES", "DETAIL"}:
            rows = self.visible_devices
            if key in (curses.KEY_UP, ord("k")) and rows:
                self.selected = max(0, self.selected - 1); self.detail = rows[self.selected]
            elif key in (curses.KEY_DOWN, ord("j")) and rows:
                self.selected = min(len(rows) - 1, self.selected + 1); self.detail = rows[self.selected]
            elif key in (10, 13) and self.mode == "DEVICES": self.choose_device_action("detail")
            elif key == ord("b"): self.choose_device_action("block")
            elif key == ord("u"): self.choose_device_action("unblock")
            elif key == ord("i"): self.choose_device_action("identify")

    def loop(self) -> None:
        self.setup()
        while self.running:
            self.draw()
            try: key = self.stdscr.getch()
            except KeyboardInterrupt: break
            self.handle_key(key)


def main() -> int:
    if not NETWATCH.exists():
        print(f"NETWATCH core not found: {NETWATCH}", file=sys.stderr); return 2
    try:
        curses.wrapper(lambda stdscr: UI(stdscr).loop())
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
