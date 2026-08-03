#!/bin/bash
# monitor.sh — Detect and kill orphaned or wedged MCP server processes.
#
# MCP servers (Cloudflare, GitHub, Todoist, Heroku, etc.) are spawned as child
# node processes by AI coding tools (Claude Code, Cursor, etc.). When sessions
# crash or close uncleanly, these processes survive as orphans, each pegging a
# CPU core at ~50%.
#
# Detection logic (an MCP server is killed if ANY of these hold):
#   1. Direct orphan     — its parent is PID 1 (reparented to launchd/init).
#   2. Wedged / spinning  — it is pinning CPU above CPU_THRESHOLD (a spin loop;
#                           a healthy MCP server sits near 0% when idle).
#   3. Second-level orphan — its parent is an AI-tool session (claude/cursor/…)
#                            that is ITSELF orphaned (that parent's PPID is 1).
#                            This catches abandoned-but-still-alive sessions that
#                            linger for days holding their MCP children — the
#                            case PPID==1 detection alone misses.
#
# This script is designed to run periodically via launchd (every 10 minutes)
# and exit immediately. No persistent background process.
#
# Works on macOS and Linux. On macOS, PPID=1 means reparented to launchd.
# On Linux, PPID=1 means reparented to init/systemd.
#
# Env overrides:
#   MCP_MONITOR_LOG    log file path (default ~/Library/Logs/mcp-orphan-monitor.log)
#   MCP_CPU_THRESHOLD  %CPU above which an MCP server is treated as wedged (default 60)

LOG_FILE="${MCP_MONITOR_LOG:-$HOME/Library/Logs/mcp-orphan-monitor.log}"
CPU_THRESHOLD="${MCP_CPU_THRESHOLD:-60}"
KILLED=0

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

# Find node processes running mcp-server-* or mcp-remote binaries
# ps output: PID PPID %CPU ELAPSED COMMAND
while IFS= read -r line; do
    [ -z "$line" ] && continue

    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    elapsed=$(echo "$line" | awk '{print $4}')
    cmd=$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

    # Extract the MCP server name for logging
    server_name=$(echo "$cmd" | grep -oE 'mcp-server-[^ /]+|mcp-remote' | head -1)
    [ -z "$server_name" ] && server_name="unknown-mcp"

    # Decide whether this process should be killed, and why.
    reason=""
    if [ "$ppid" -eq 1 ]; then
        reason="parent-dead (PPID=1)"
    elif cpu_over "$cpu" "$CPU_THRESHOLD"; then
        # Wedged spin loop — the signature that cooks the machine 24/7.
        reason="wedged (cpu=${cpu}% > ${CPU_THRESHOLD}%)"
    else
        # Second-level orphan: parent is an AI session that is itself orphaned.
        gp=$(ppid_of "$ppid")
        if [ "$gp" = "1" ] && is_ai_session "$ppid"; then
            reason="orphaned under dead session (parent pid=$ppid is PPID=1)"
        fi
    fi

    if [ -n "$reason" ]; then
        kill "$pid" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "KILLED orphan: pid=$pid server=$server_name cpu=${cpu}% uptime=$elapsed reason=$reason"
            KILLED=$((KILLED + 1))
        else
            log "FAILED to kill: pid=$pid server=$server_name reason=$reason (may have already exited)"
        fi
    fi

done < <(ps -eo pid,ppid,%cpu,etime,command | grep -E 'mcp-server-|mcp-remote' | grep -v grep | grep -v monitor.sh)

# Only log the summary line if we actually killed something (keeps log clean)
if [ "$KILLED" -gt 0 ]; then
    log "Summary: killed $KILLED orphaned/wedged MCP process(es)"
fi
