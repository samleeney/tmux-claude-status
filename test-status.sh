#!/usr/bin/env bash

# Test script to verify status bar functionality

STATUS_DIR="$HOME/.cache/tmux-agent-status"
mkdir -p "$STATUS_DIR"

echo "Testing agent status bar..."

# Test 1: No agent sessions
echo "Test 1: No agent sessions"
rm -f "$STATUS_DIR"/*.status
./scripts/status-line.sh

# Test 2: One local agent working
echo -e "\nTest 2: One local agent working"
echo "working" > "$STATUS_DIR/test-session.status"
./scripts/status-line.sh

# Test 3: Multiple agents (including SSH)
echo -e "\nTest 3: Multiple agents (2 working, 1 done)"
echo "working" > "$STATUS_DIR/test-session.status"
echo "working" > "$STATUS_DIR/reachgpu-remote.status"
echo "done" > "$STATUS_DIR/another-session.status"
./scripts/status-line.sh

# Test 4: All agents ready
echo -e "\nTest 4: All agents ready"
echo "done" > "$STATUS_DIR/test-session.status"
echo "done" > "$STATUS_DIR/reachgpu-remote.status"
echo "done" > "$STATUS_DIR/another-session.status"
./scripts/status-line.sh

# Cleanup
echo -e "\nCleaning up test files..."
rm -f "$STATUS_DIR/test-session.status"
rm -f "$STATUS_DIR/another-session.status"
