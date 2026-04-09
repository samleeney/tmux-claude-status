#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
SIDEBAR_CLIENT_DIR="$STATUS_DIR/sidebar-clients"

mkdir -p "$FAKE_BIN" "$SIDEBAR_CLIENT_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-panes)
        printf '%%1\tagent-sidebar\t1\n'
        printf '%%2\tagent-sidebar\t0\n'
        printf '%%3\tnot-a-sidebar\t1\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

spawn_listener() {
    local log_file="$1"
    bash -c '
        trap "printf \"USR1\n\" >> \"$1\"" USR1
        trap "printf \"USR2\n\" >> \"$1\"" USR2
        while :; do sleep 1; done
    ' _ "$log_file" &
    SPAWNED_PID="$!"
}

wait_for_log() {
    local log_file="$1"
    local expected="$2"
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [ -f "$log_file" ] && grep -qF "$expected" "$log_file"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

listener_one_log="$TMP_DIR/listener-one.log"
listener_two_log="$TMP_DIR/listener-two.log"
listener_three_log="$TMP_DIR/listener-three.log"

spawn_listener "$listener_one_log"
listener_one_pid="$SPAWNED_PID"
spawn_listener "$listener_two_log"
listener_two_pid="$SPAWNED_PID"
spawn_listener "$listener_three_log"
listener_three_pid="$SPAWNED_PID"

printf '%s\n' "$listener_one_pid" > "$SIDEBAR_CLIENT_DIR/%1.pid"
printf '%s\n' "$listener_two_pid" > "$SIDEBAR_CLIENT_DIR/%2.pid"
printf '%s\n' "$listener_three_pid" > "$SIDEBAR_CLIENT_DIR/%3.pid"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/sidebar-signal.sh" refresh
wait_for_log "$listener_one_log" "USR1"
wait_for_log "$listener_two_log" "USR1"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/sidebar-signal.sh" active
wait_for_log "$listener_one_log" "USR2"

if [ -f "$listener_two_log" ] && grep -qF "USR2" "$listener_two_log"; then
    echo "Assertion failed: inactive sidebar should not receive animation ticks" >&2
    exit 1
fi

if [ -f "$SIDEBAR_CLIENT_DIR/%3.pid" ]; then
    echo "Assertion failed: non-sidebar registry entry should be cleaned up" >&2
    exit 1
fi

echo "sidebar client signal regression checks passed"
