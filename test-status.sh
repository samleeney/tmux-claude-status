#!/usr/bin/env bash

# Test script to verify status bar functionality

STATUS_DIR="$HOME/.cache/tmux-claude-status"
mkdir -p "$STATUS_DIR"

echo "Testing Claude status bar..."

# Test 1: No Claude sessions
echo "Test 1: No Claude sessions"
rm -f "$STATUS_DIR"/*.status
./scripts/status-line.sh

# Test 2: One local Claude working
echo -e "\nTest 2: One local Claude working"
echo "working" > "$STATUS_DIR/test-session.status"
./scripts/status-line.sh

# Test 3: Multiple Claudes (including SSH)
echo -e "\nTest 3: Multiple Claudes (2 working, 1 done)"
echo "working" > "$STATUS_DIR/test-session.status"
echo "working" > "$STATUS_DIR/reachgpu-remote.status"
echo "done" > "$STATUS_DIR/another-session.status"
./scripts/status-line.sh

# Test 4: All Claudes ready
echo -e "\nTest 4: All Claudes ready"
echo "done" > "$STATUS_DIR/test-session.status"
echo "done" > "$STATUS_DIR/reachgpu-remote.status"
echo "done" > "$STATUS_DIR/another-session.status"
./scripts/status-line.sh

# Cleanup
echo -e "\nCleaning up test files..."
rm -f "$STATUS_DIR/test-session.status"
rm -f "$STATUS_DIR/another-session.status"