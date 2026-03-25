#!/bin/bash
# install.sh — Install/uninstall the MCP Orphan Monitor as a macOS LaunchAgent.
#
# Components:
#   1. Monitor script — runs every 10 minutes, detects and kills orphaned MCP processes
#   2. Status bar app (optional) — macOS menu bar icon showing monitor status
#
# Usage:
#   ./install.sh                  Install monitor + status bar
#   ./install.sh --no-statusbar   Install monitor only (no menu bar icon)
#   ./install.sh uninstall        Uninstall everything

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.mcp-orphan-monitor"
MONITOR_PLIST="com.mcp-orphan-monitor.plist"
STATUSBAR_PLIST="com.mcp-orphan-monitor-statusbar.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_FILE="$HOME/Library/Logs/mcp-orphan-monitor.log"

SKIP_STATUSBAR=false
if [ "$1" = "--no-statusbar" ]; then
    SKIP_STATUSBAR=true
    shift
fi

install() {
    echo "Installing MCP Orphan Monitor..."
    echo ""

    # Copy files to install directory
    mkdir -p "$INSTALL_DIR"
    cp "$SCRIPT_DIR/monitor.sh" "$INSTALL_DIR/monitor.sh"
    chmod +x "$INSTALL_DIR/monitor.sh"
    echo "  Copied monitor script to $INSTALL_DIR/monitor.sh"

    # Install monitor LaunchAgent
    mkdir -p "$LAUNCH_AGENTS_DIR"

    # Generate plist with correct home directory
    cat > "$LAUNCH_AGENTS_DIR/$MONITOR_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mcp-orphan-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/monitor.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

    launchctl unload "$LAUNCH_AGENTS_DIR/$MONITOR_PLIST" 2>/dev/null || true
    launchctl load "$LAUNCH_AGENTS_DIR/$MONITOR_PLIST"
    echo "  Loaded $MONITOR_PLIST (runs every 10 minutes)"

    # Status bar (optional)
    if [ "$SKIP_STATUSBAR" = false ]; then
        # Check for rumps
        if python3 -c "import rumps" 2>/dev/null; then
            cp "$SCRIPT_DIR/statusbar.py" "$INSTALL_DIR/statusbar.py"
            echo "  Copied status bar app to $INSTALL_DIR/statusbar.py"

            cat > "$LAUNCH_AGENTS_DIR/$STATUSBAR_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mcp-orphan-monitor-statusbar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${INSTALL_DIR}/statusbar.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/mcp-orphan-monitor-statusbar.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/mcp-orphan-monitor-statusbar.log</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST

            launchctl unload "$LAUNCH_AGENTS_DIR/$STATUSBAR_PLIST" 2>/dev/null || true
            pkill -f "mcp-orphan-monitor.*statusbar" 2>/dev/null || true
            sleep 1
            launchctl load "$LAUNCH_AGENTS_DIR/$STATUSBAR_PLIST"
            echo "  Loaded $STATUSBAR_PLIST (shield icon in menu bar)"
        else
            echo ""
            echo "  Status bar requires 'rumps'. Install it and re-run:"
            echo "    pip3 install rumps"
            echo "    ./install.sh"
            echo ""
            echo "  Skipping status bar for now. Monitor is still active."
        fi
    fi

    # Create log file
    touch "$LOG_FILE"

    echo ""
    echo "Done! The monitor is now running."
    echo "  - Background scanner runs every 10 minutes"
    echo "  - Kills logged to: $LOG_FILE"
    if [ "$SKIP_STATUSBAR" = false ] && python3 -c "import rumps" 2>/dev/null; then
        echo "  - Shield icon in your menu bar (right-click for options)"
    fi
    echo ""
    echo "To check for orphans right now:"
    echo "  bash $INSTALL_DIR/monitor.sh"
}

uninstall() {
    echo "Uninstalling MCP Orphan Monitor..."

    # Unload monitor
    if [ -f "$LAUNCH_AGENTS_DIR/$MONITOR_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$MONITOR_PLIST" 2>/dev/null || true
        rm "$LAUNCH_AGENTS_DIR/$MONITOR_PLIST"
        echo "  Removed $MONITOR_PLIST"
    fi

    # Unload statusbar
    if [ -f "$LAUNCH_AGENTS_DIR/$STATUSBAR_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$STATUSBAR_PLIST" 2>/dev/null || true
        rm "$LAUNCH_AGENTS_DIR/$STATUSBAR_PLIST"
        echo "  Removed $STATUSBAR_PLIST"
    fi
    pkill -f "mcp-orphan-monitor.*statusbar" 2>/dev/null || true

    # Remove install directory
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        echo "  Removed $INSTALL_DIR"
    fi

    echo ""
    echo "Done. Log file preserved at: $LOG_FILE"
}

case "${1:-install}" in
    install)   install ;;
    uninstall) uninstall ;;
    *)
        echo "Usage: $0 [install|uninstall|--no-statusbar]"
        exit 1
        ;;
esac
