#!/bin/bash
# monitor.sh — Detect and kill orphaned MCP server processes.
#
# MCP servers (Cloudflare, GitHub, Todoist, Heroku, etc.) are spawned as child
# node processes by AI coding tools (Claude Code, Cursor, etc.). When sessions
# crash or close uncleanly, these processes survive as orphans, each pegging a
# CPU core at ~50%.
#
# Detection logic:
#   1. Find all node processes matching "mcp-server-*" or "mcp-remote"
#   2. Check if the parent process is still alive
#   3. If the parent is gone (PPID=1, reparented to launchd/init), it's an orphan
#   4. Kill orphans and log what we did
#
# This script is designed to run periodically via launchd (every 10 minutes)
# and exit immediately. No persistent background process.
#
# Works on macOS and Linux. On macOS, PPID=1 means reparented to launchd.
# On Linux, PPID=1 means reparented to init/systemd.

LOG_FILE="${MCP_MONITOR_LOG:-$HOME/Library/Logs/mcp-orphan-monitor.log}"
KILLED=0

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
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

    # Check if parent is launchd/init (PID 1) — means the original parent died
    if [ "$ppid" -eq 1 ]; then
        kill "$pid" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "KILLED orphan: pid=$pid server=$server_name cpu=${cpu}% uptime=$elapsed"
            KILLED=$((KILLED + 1))
        else
            log "FAILED to kill: pid=$pid server=$server_name (may have already exited)"
        fi
    fi

done < <(ps -eo pid,ppid,%cpu,etime,command | grep -E 'mcp-server-|mcp-remote' | grep -v grep | grep -v monitor.sh)

# Only log the summary line if we actually killed something (keeps log clean)
if [ "$KILLED" -gt 0 ]; then
    log "Summary: killed $KILLED orphaned MCP process(es)"
fi
