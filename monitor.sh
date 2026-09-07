#!/bin/bash
# monitor.sh — Detect and kill orphaned or wedged dev-tool processes.
#
# MCP servers (Cloudflare, GitHub, Todoist, Heroku, …) and dev servers (Vite,
# Next, Astro, webpack, esbuild) are spawned as child processes by AI coding
# tools and shells. When sessions crash or close uncleanly these survive as
# orphans, each pegging a CPU core.
#
# Two classes of process, deliberately treated differently:
#
#   MCP class  (mcp-server-*, mcp-remote, workspace-mcp)
#     Killed if ANY hold:
#       1. Direct orphan      — parent is PID 1 (reparented to launchd/init).
#       2. Wedged / spinning  — CPU above CPU_THRESHOLD *and* older than
#                               MIN_WEDGE_AGE. A healthy MCP server sits near 0%
#                               when idle; the age floor avoids killing a server
#                               during its startup burst.
#       3. Second-level orphan — parent is an AI-tool session (claude/cursor/…)
#                                that is ITSELF orphaned (its PPID is 1). Catches
#                                abandoned-but-alive sessions holding MCP
#                                children — the case PPID==1 alone misses.
#
#   Dev-server class  (astro dev, vite, next dev, webpack serve, esbuild, npm/npx dev)
#     Killed ONLY on condition 1 (PPID==1). Rules 2 and 3 are NOT applied: a
#     dev server legitimately pins the CPU while compiling, and killing a build
#     mid-flight would be destructive.
#
# The SAFELIST protects processes that are *supposed* to run under launchd with
# PPID=1 (the alcanah daemon suite, this monitor's own status bar app).
#
# Runs periodically via launchd (every 10 minutes) and exits immediately.
# No persistent background process.
#
# Works on macOS and Linux. PPID=1 means reparented to launchd / init / systemd.
#
# Env overrides:
#   MCP_MONITOR_LOG    log file path (default ~/Library/Logs/mcp-orphan-monitor.log)
#   MCP_CPU_THRESHOLD  %CPU above which an MCP server is treated as wedged (default 60)
#   MCP_MIN_WEDGE_AGE  seconds a process must have been alive before the wedged
#                      rule can fire (default 300)

LOG_FILE="${MCP_MONITOR_LOG:-$HOME/Library/Logs/mcp-orphan-monitor.log}"
CPU_THRESHOLD="${MCP_CPU_THRESHOLD:-60}"
MIN_WEDGE_AGE="${MCP_MIN_WEDGE_AGE:-300}"
KILLED=0

# --- Configuration ---

# Every process class this monitor considers. Extended grep regex, matched
# against the full command line.
ORPHAN_PATTERNS=(
    'mcp-server-'           # MCP servers (Cloudflare, GitHub, Todoist, …)
    'mcp-remote'            # mcp-remote bridge
    'workspace-mcp'         # Google Workspace MCP (Python/uvx)
    'astro dev'             # Astro dev server
    'node.*vite'            # Vite dev server (must be a node process)
    'next dev'              # Next.js dev server
    'webpack.*serve'        # webpack dev server
    'esbuild --service'     # esbuild service mode (exact flag match)
    'npm run dev'           # generic npm dev scripts
    'npx.*dev'              # generic npx dev commands
)

# The subset above that is an MCP server. Only these are eligible for the
# wedged-CPU and second-level-orphan rules.
MCP_PATTERNS=(
    'mcp-server-'
    'mcp-remote'
    'workspace-mcp'
)

# Processes that legitimately have PPID=1 (managed by launchd). Never kill these.
# Match against the command line — be specific enough to avoid false positives.
SAFELIST=(
    'alcanah-daemon/main.py'
    'alcanah-daemon/dashboard-serve.py'
    'alcanah-daemon/statusbar.py'
    'alcanah-daemon/node-monitor'
    'alcanah-ops-server/server.py'
    '.mcp-orphan-monitor/statusbar.py'
)

PATTERN_REGEX=$(IFS='|'; echo "${ORPHAN_PATTERNS[*]}")
MCP_REGEX=$(IFS='|'; echo "${MCP_PATTERNS[*]}")
SAFELIST_REGEX=$(IFS='|'; echo "${SAFELIST[*]}")

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# PPID of a given pid (empty if the process is gone)
ppid_of() {
    ps -p "$1" -o ppid= 2>/dev/null | tr -d ' '
}

# Is this pid an AI-tool session process we recognize as an MCP parent?
is_ai_session() {
    ps -p "$1" -o comm= 2>/dev/null | grep -qiE 'claude|cursor|windsurf|copilot'
}

# Is cpu ($1) strictly greater than the threshold ($2)? (float-safe)
cpu_over() {
    awk -v c="$1" -v t="$2" 'BEGIN { exit !((c + 0) > (t + 0)) }'
}

# Convert ps etime ([DD-]HH:MM:SS or MM:SS) to seconds.
etime_seconds() {
    echo "$1" | awk -F'[-:]' '{
        if (NF == 4)      print ($1*86400) + ($2*3600) + ($3*60) + $4
        else if (NF == 3) print ($1*3600) + ($2*60) + $3
        else if (NF == 2) print ($1*60) + $2
        else              print 0
    }'
}

# --- Main scan ---
# ps output: PID PPID %CPU ELAPSED COMMAND
while IFS= read -r line; do
    [ -z "$line" ] && continue

    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    elapsed=$(echo "$line" | awk '{print $4}')
    cmd=$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

    # Never touch launchd-managed processes that are supposed to have PPID=1.
    echo "$cmd" | grep -qE "$SAFELIST_REGEX" && continue

    # Human-readable name for the log
    process_name=$(echo "$cmd" | grep -oE 'mcp-server-[^ /]+|mcp-remote|workspace-mcp' | head -1)
    [ -z "$process_name" ] && process_name=$(echo "$cmd" | grep -oE 'astro dev|vite|next dev|npm run dev|esbuild' | head -1)
    [ -z "$process_name" ] && process_name="unknown"

    # Is this an MCP server (eligible for the extra rules) or a dev server?
    is_mcp=false
    echo "$cmd" | grep -qE "$MCP_REGEX" && is_mcp=true

    # Decide whether this process should be killed, and why.
    reason=""
    if [ "$ppid" = "1" ]; then
        reason="parent-dead (PPID=1)"
    elif [ "$is_mcp" = true ]; then
        age=$(etime_seconds "$elapsed")
        if cpu_over "$cpu" "$CPU_THRESHOLD" && [ "$age" -ge "$MIN_WEDGE_AGE" ]; then
            # Wedged spin loop — the signature that cooks the machine 24/7.
            reason="wedged (cpu=${cpu}% > ${CPU_THRESHOLD}%, age=${age}s)"
        else
            # Second-level orphan: parent is an AI session that is itself orphaned.
            gp=$(ppid_of "$ppid")
            if [ "$gp" = "1" ] && is_ai_session "$ppid"; then
                reason="orphaned under dead session (parent pid=$ppid is PPID=1)"
            fi
        fi
    fi

    if [ -n "$reason" ]; then
        if kill "$pid" 2>/dev/null; then
            log "KILLED orphan: pid=$pid name=$process_name cpu=${cpu}% uptime=$elapsed reason=$reason cmd=$(echo "$cmd" | head -c 120)"
            KILLED=$((KILLED + 1))
        else
            log "FAILED to kill: pid=$pid name=$process_name reason=$reason (may have already exited)"
        fi
    fi

done < <(ps -eo pid,ppid,%cpu,etime,command | grep -E "$PATTERN_REGEX" | grep -v grep | grep -v monitor.sh)

# Only log the summary line if we actually killed something (keeps log clean)
if [ "$KILLED" -gt 0 ]; then
    log "Summary: killed $KILLED orphaned/wedged process(es)"
fi
