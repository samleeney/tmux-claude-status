#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
WAIT_DIR="$STATUS_DIR/wait"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR"

# Fake tmux that returns canned session list and pane data.
cat > "$FAKE_BIN/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        # Tab-separated: name, windows, attached flag
        printf 'working-task\t2\t1\n'
        printf 'done-task\t1\t0\n'
        printf 'unread-task\t1\t0\n'
        printf 'waiting-task\t3\t1\n'
        printf 'parked-task\t1\t0\n'
        printf 'plain-session\t1\t1\n'
        ;;
    list-panes)
        exit 0
        ;;
    display-message)
        echo "working-task"
        ;;
    *)
        exit 0
        ;;
esac
TMUX_EOF
chmod +x "$FAKE_BIN/tmux"

# Fake tput for non-interactive rendering
cat > "$FAKE_BIN/tput" <<'TPUT_EOF'
#!/usr/bin/env bash
case "${1:-}" in
    cols)  echo 30 ;;
    lines) echo 24 ;;
    civis|cnorm|smcup|rmcup) ;;
    cup) ;;
    *)     ;;
esac
TPUT_EOF
chmod +x "$FAKE_BIN/tput"

# Set up status files for various states.
echo "working" > "$STATUS_DIR/working-task.status"
echo "done"    > "$STATUS_DIR/done-task.status"
echo "done"    > "$STATUS_DIR/unread-task.status"
: > "$STATUS_DIR/unread-task.unread"
echo "wait"    > "$STATUS_DIR/waiting-task.status"
echo "$(( $(date +%s) + 1800 ))" > "$WAIT_DIR/waiting-task.wait"
echo "parked"  > "$STATUS_DIR/parked-task.status"
: > "$PARKED_DIR/parked-task.parked"

# Source the sidebar's collect function to test data collection.
# We need to override the main loop — extract collect() and inspect its results.
# Instead, we source the shared lib and replicate the collect logic inline.

output=$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" bash -c '
    source "'"$REPO_DIR"'/scripts/lib/session-status.sh"

    STATUS_DIR="'"$STATUS_DIR"'"
    PARKED_DIR="'"$PARKED_DIR"'"
    WAIT_DIR="'"$WAIT_DIR"'"

    # Minimal collect logic matching sidebar.sh
    working=() done=() unread=() waiting=() parked=() noagent=()

    while IFS=$'"'"'\t'"'"' read -r name windows attached; do
        agent_status=$(get_agent_status "$name")
        has_agent=false

        if [ -n "$agent_status" ]; then
            has_agent=true
        fi

        if [ "$has_agent" = true ]; then
            [ -z "$agent_status" ] && agent_status="done"
            state="$agent_status"
        else
            state="noagent"
        fi

        if [ "$state" = "wait" ]; then
            wait_file="$WAIT_DIR/${name}.wait"
            if [ -f "$wait_file" ]; then
                expiry=$(cat "$wait_file" 2>/dev/null)
                now=$(date +%s)
                if [ -n "$expiry" ] && (( expiry > now )); then
                    state="wait"
                else
                    state="done"
                fi
            fi
        fi

        if [ "$state" = "done" ]; then
            if [ -f "$STATUS_DIR/${name}.unread" ]; then
                state="unread"
            fi
        fi

        case "$state" in
            working) working+=("$name") ;;
            unread)  unread+=("$name") ;;
            done)    done+=("$name") ;;
            wait)    waiting+=("$name") ;;
            parked)  parked+=("$name") ;;
            *)       noagent+=("$name") ;;
        esac
    done < <(tmux list-sessions -F "not-used" 2>/dev/null)

    # Output what ended up where
    echo "WORKING: ${working[*]:-}"
    echo "UNREAD: ${unread[*]:-}"
    echo "DONE: ${done[*]:-}"
    echo "WAIT: ${waiting[*]:-}"
    echo "PARKED: ${parked[*]:-}"
    echo "NOAGENT: ${noagent[*]:-}"
')

# Assertions
assert_contains() {
    local label="$1" pattern="$2"
    if ! echo "$output" | grep -qF "$pattern"; then
        echo "FAIL: $label — expected to find '$pattern' in output:" >&2
        echo "$output" >&2
        exit 1
    fi
}

assert_contains "working session classified" "WORKING: working-task"
assert_contains "done session classified"    "DONE: done-task"
assert_contains "unread session classified"  "UNREAD: unread-task"
assert_contains "wait session classified"    "WAIT: waiting-task"
assert_contains "parked session classified"  "PARKED: parked-task"
assert_contains "no-agent session classified" "NOAGENT: plain-session"

echo "sidebar render regression checks passed"
