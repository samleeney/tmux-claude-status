#!/usr/bin/env bash

# Daemon monitor that ensures smart-monitor is always running
# This script should be called from tmux hooks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-claude-status"
DAEMON_PID_FILE="$STATUS_DIR/smart-monitor.pid"
MONITOR_PID_FILE="$STATUS_DIR/daemon-monitor.pid"
SMART_MONITOR="$SCRIPT_DIR/../smart-monitor.sh"

# Check if we're already monitoring
if [ -f "$MONITOR_PID_FILE" ]; then
    monitor_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
    if [ -n "$monitor_pid" ] && kill -0 "$monitor_pid" 2>/dev/null; then
        # Monitor is already running
        exit 0
    else
        # Remove stale PID file
        rm -f "$MONITOR_PID_FILE"
    fi
fi

# Start monitoring in background
(
    echo $$ > "$MONITOR_PID_FILE"
    
    while tmux list-sessions >/dev/null 2>&1; do
        # Check if smart-monitor is running
        if [ -f "$DAEMON_PID_FILE" ]; then
            daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
            if [ -z "$daemon_pid" ] || ! kill -0 "$daemon_pid" 2>/dev/null; then
                # Daemon is not running, restart it
                rm -f "$DAEMON_PID_FILE"
                "$SMART_MONITOR" start >/dev/null 2>&1
            fi
        else
            # No PID file, start daemon
            "$SMART_MONITOR" start >/dev/null 2>&1
        fi
        
        # Check every 5 seconds
        sleep 5
    done
    
    # Tmux is no longer running, clean up
    rm -f "$MONITOR_PID_FILE"
    
    # Stop smart-monitor
    if [ -f "$DAEMON_PID_FILE" ]; then
        daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [ -n "$daemon_pid" ]; then
            kill "$daemon_pid" 2>/dev/null
        fi
        rm -f "$DAEMON_PID_FILE"
    fi
) &