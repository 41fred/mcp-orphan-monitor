"""
MCP Orphan Monitor — macOS Menu Bar App

Lightweight macOS menu bar app that monitors for orphaned MCP server processes.
Uses rumps for the menu bar integration.

Shield icon = monitoring active, no orphans
Warning icon = orphans detected

Install rumps: pip3 install rumps
"""

import os
import subprocess
import rumps

LOG_FILE = os.environ.get(
    "MCP_MONITOR_LOG",
    os.path.expanduser("~/Library/Logs/mcp-orphan-monitor.log"),
)
MONITOR_SCRIPT = os.path.expanduser("~/.mcp-orphan-monitor/monitor.sh")
POLL_SECONDS = 30  # Check for orphans every 30 seconds


def count_orphans():
    """Count current orphaned MCP server processes (PPID=1)."""
    try:
        result = subprocess.run(
            ["bash", "-c",
             "ps -eo pid,ppid,command | grep -E 'mcp-server-|mcp-remote' | grep -v grep | awk '$2 == 1'"],
            capture_output=True, text=True, timeout=5,
        )
        lines = [l for l in result.stdout.strip().split("\n") if l.strip()]
        return len(lines)
    except Exception:
        return 0


def get_total_kills():
    """Count total kills from the log file."""
    if not os.path.exists(LOG_FILE):
        return 0
    try:
        result = subprocess.run(
            ["grep", "-c", "KILLED orphan", LOG_FILE],
            capture_output=True, text=True, timeout=5,
        )
        return int(result.stdout.strip()) if result.stdout.strip() else 0
    except Exception:
        return 0


def get_last_kills(n=5):
    """Get the last N kill log entries."""
    if not os.path.exists(LOG_FILE):
        return ["No log file yet"]
    try:
        result = subprocess.run(
            ["grep", "KILLED orphan", LOG_FILE],
            capture_output=True, text=True, timeout=5,
        )
        lines = [l for l in result.stdout.strip().split("\n") if l.strip()]
        if not lines:
            return ["No kills recorded yet"]
        # Return last N, most recent first
        return lines[-n:][::-1]
    except Exception:
        return ["Could not read log"]


class MCPOrphanMonitor(rumps.App):
    def __init__(self):
        super().__init__("MCPMon", quit_button=None)
        self._dock_hidden = False
        self.title = "\U0001F6E1\uFE0F"  # shield emoji
        self.orphan_count = 0

        # Menu items
        self.status_item = rumps.MenuItem("Checking...")
        self.kills_item = rumps.MenuItem("Total kills: ...")
        self.separator1 = None
        self.recent_header = rumps.MenuItem("Recent Kills")
        self.recent_header.set_callback(None)  # non-clickable header
        self.separator2 = None
        self.scan_item = rumps.MenuItem("Scan Now")
        self.logs_item = rumps.MenuItem("View Log")
        self.separator3 = None
        self.quit_item = rumps.MenuItem("Quit")

        self.menu = [
            self.status_item,
            self.kills_item,
            None,
            self.recent_header,
            None,
            self.scan_item,
            self.logs_item,
            None,
            self.quit_item,
        ]

    @rumps.timer(POLL_SECONDS)
    def poll(self, _):
        """Periodically check for orphans and update display."""
        if not self._dock_hidden:
            try:
                from AppKit import NSApplication
                NSApplication.sharedApplication().setActivationPolicy_(1)
                self._dock_hidden = True
            except Exception:
                pass

        self.orphan_count = count_orphans()
        total_kills = get_total_kills()

        # Update icon — shield with warning if orphans detected
        if self.orphan_count > 0:
            self.title = "\U000026A0\uFE0F"  # warning sign
        else:
            self.title = "\U0001F6E1\uFE0F"  # shield

        # Update menu items
        if self.orphan_count > 0:
            self.status_item.title = f"Orphans detected: {self.orphan_count}"
        else:
            self.status_item.title = "No orphans detected"

        self.kills_item.title = f"Total kills: {total_kills}"

        # Update recent kills submenu
        recent = get_last_kills(5)
        keys_to_remove = [k for k in self.menu.keys()
                          if isinstance(k, str) and k.startswith("20")]
        for k in keys_to_remove:
            del self.menu[k]

        for entry in recent:
            display = entry[:80] if len(entry) > 80 else entry
            item = rumps.MenuItem(display)
            item.set_callback(None)
            self.menu.insert_after(self.recent_header.title, item)

    @rumps.clicked("Scan Now")
    def scan_now(self, _):
        """Run the monitor script immediately."""
        try:
            subprocess.run(
                ["bash", MONITOR_SCRIPT],
                capture_output=True, timeout=10,
            )
            orphans = count_orphans()
            if orphans == 0:
                rumps.notification(
                    "MCP Orphan Monitor", "", "Scan complete — no orphans found",
                    sound=False,
                )
            else:
                rumps.notification(
                    "MCP Orphan Monitor", "",
                    f"Scan complete — {orphans} orphan(s) killed",
                    sound=False,
                )
        except Exception as e:
            rumps.notification(
                "MCP Orphan Monitor", "", f"Scan failed: {e}", sound=False
            )

    @rumps.clicked("View Log")
    def view_logs(self, _):
        """Open the monitor log in Console.app."""
        if os.path.exists(LOG_FILE):
            subprocess.run(["open", "-a", "Console", LOG_FILE])
        else:
            rumps.notification(
                "MCP Orphan Monitor", "", "No log file yet — no kills recorded",
                sound=False,
            )

    @rumps.clicked("Quit")
    def quit_app(self, _):
        rumps.quit_application()


if __name__ == "__main__":
    MCPOrphanMonitor().run()
