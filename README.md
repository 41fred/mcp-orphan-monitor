# mcp-orphan-monitor

Detect and kill orphaned MCP servers and dev servers that survive after AI coding tool sessions crash or close uncleanly.

If you use Claude Code, Cursor, or any MCP-based AI tool, you probably have zombie node processes running right now:

```bash
ps aux | grep mcp-server | grep -v grep
```

## The problem

MCP (Model Context Protocol) servers run as child node processes — one per configured server, per session. When a session ends cleanly, they get killed. When it doesn't (crash, force-quit, closed terminal), they survive as orphans stuck in event loops with no parent.

Each orphan pegs a CPU core at ~50% doing nothing useful. We found 11 orphaned `mcp-server-cloudflare` processes running simultaneously — 550% combined CPU, the oldest burning cycles for 48+ hours.

This is a [known Claude Code issue](https://github.com/anthropics/claude-code/issues/1935) — open since June 2025, still unresolved. Users have reported it with Cloudflare, Todoist, Heroku, Azure DevOps, and ESP-IDF MCP servers. One user found 40+ orphaned processes.

## How it works

A small bash script that runs every 10 minutes via macOS LaunchAgent. It scans two
classes of process and applies deliberately different rules to each.

**MCP class** — `mcp-server-*`, `mcp-remote`, `workspace-mcp`. Killed on **any** of
three signatures:

1. **Direct orphan** — the parent is PID 1 (reparented to launchd/init). The classic
   crash case: the session process vanished.
2. **Wedged / spinning** — the server is pinning CPU above `MCP_CPU_THRESHOLD` (default
   60%) *and* has been alive longer than `MCP_MIN_WEDGE_AGE` (default 300s). A healthy
   MCP server sits near 0% when idle, so sustained high CPU means it's stuck in a spin
   loop — the signature that cooks a laptop 24/7. The age floor keeps a server's noisy
   startup burst from tripping the rule.
3. **Second-level orphan** — the parent is an AI-tool session (`claude`/`cursor`/…) that
   is *itself* orphaned (that parent's PPID is 1). This catches abandoned-but-still-alive
   sessions that linger for days holding their MCP children — the case PPID==1 detection
   alone misses.

**Dev-server class** — `astro dev`, Vite, `next dev`, `webpack serve`, `esbuild
--service`, `npm run dev`, `npx … dev`. Killed on **signature 1 only**. Rules 2 and 3 do
not apply: a dev server legitimately pins a core while compiling, and killing a build
mid-flight would be destructive.

A **safelist** protects processes that are *supposed* to run under launchd with PPID=1
(long-running agents, this monitor's own status bar app). Edit `SAFELIST` in
`monitor.sh` to add your own.

Live sessions are safe: an active session's parent chain terminates at your shell or IDE,
not at launchd, and a healthy idle MCP server stays well under the CPU threshold.

No dependencies. No background daemon. Just a periodic scan.

### Tuning

```bash
MCP_CPU_THRESHOLD=40   # more aggressive: kill anything over 40% CPU
MCP_MIN_WEDGE_AGE=60   # let the wedged rule fire on younger processes
MCP_MONITOR_LOG=...    # custom log path
```

## Install

```bash
git clone https://github.com/41fred/mcp-orphan-monitor.git
cd mcp-orphan-monitor
bash install.sh
```

This installs:
- **Monitor script** at `~/.mcp-orphan-monitor/monitor.sh` — runs every 10 minutes via LaunchAgent
- **Status bar app** (optional) — shield icon in your menu bar with scan-on-demand, kill history, and orphan count

To skip the status bar:

```bash
bash install.sh --no-statusbar
```

The status bar requires [rumps](https://github.com/jaredks/rumps):

```bash
pip3 install rumps
```

### Uninstall

```bash
bash install.sh uninstall
```

## Manual scan

Run the monitor immediately without waiting for the next scheduled scan:

```bash
bash ~/.mcp-orphan-monitor/monitor.sh
```

## Logs

Kills are logged to `~/Library/Logs/mcp-orphan-monitor.log`:

```
2026-03-09 14:22:01 KILLED orphan: pid=48291 server=mcp-server-cloudflare cpu=52.3% uptime=2-03:41:12
2026-03-09 14:22:01 KILLED orphan: pid=48295 server=mcp-server-cloudflare cpu=49.8% uptime=2-03:41:10
2026-03-09 14:22:01 Summary: killed 2 orphaned MCP process(es)
```

## Status bar

The optional menu bar app shows:

- Shield icon when all clear, warning icon when orphans are detected
- Current orphan count
- Total kills since install
- Last 5 kill entries
- Scan Now button for immediate cleanup
- View Log to open the log in Console.app

## How it compares to cc-reaper

[cc-reaper](https://github.com/theQuert/cc-reaper) uses a Claude Code Stop hook to clean up when sessions end. This monitor takes a different approach — periodic PPID=1 detection that catches crash scenarios where no hook fires. They're complementary.

| | mcp-orphan-monitor | cc-reaper |
|---|---|---|
| Approach | Periodic scan (launchd) | Stop hook + daemon |
| Catches crashes | Yes (PPID=1 detection) | Via proc-janitor daemon |
| Dependencies | None (bash + launchd) | Rust (proc-janitor) or LaunchAgent |
| Status bar | Yes (Python/rumps) | No |
| Scope | MCP orphans only | MCP + subagents |

## Linux

The monitor script works on Linux (PPID=1 = reparented to init/systemd). Replace the LaunchAgent with a cron job or systemd timer:

```bash
# cron — every 10 minutes
*/10 * * * * MCP_MONITOR_LOG="$HOME/.local/log/mcp-orphan-monitor.log" bash "$HOME/.mcp-orphan-monitor/monitor.sh"
```

## Why this exists

MCP servers should self-terminate when their parent disappears. Until that's fixed upstream in the MCP spec or in Claude Code, every team running MCP-based tools needs to monitor for this — especially daemon setups where sessions are spawned on behalf of users (Slack bots, API gateways), where orphans accumulate from every session with zero visibility.

Built by [Alcanah Partners](https://alcanah.com) — we build AI operations infrastructure.

## License

MIT
