#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"

mkdir -p "$FAKE_BIN" "$STATUS_DIR/sidebar-clients"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-panes)
        printf '%%1\tagent-sidebar\t1\n'
        printf '%%2\tagent-sidebar\t0\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

spawn_listener() {
    local refresh_file="$1"
    local animate_file="$2"

    bash -c '
        refresh_file="$1"
        animate_file="$2"
        trap "printf 1 > \"$refresh_file\"" USR1
        trap "printf 1 > \"$animate_file\"" USR2
        while :; do
            sleep 1
        done
    ' bash "$refresh_file" "$animate_file" >/dev/null 2>&1 &
    echo $!
}

active_refresh="$TMP_DIR/active.refresh"
active_animate="$TMP_DIR/active.animate"
inactive_refresh="$TMP_DIR/inactive.refresh"
inactive_animate="$TMP_DIR/inactive.animate"

active_pid="$(spawn_listener "$active_refresh" "$active_animate")"
inactive_pid="$(spawn_listener "$inactive_refresh" "$inactive_animate")"
trap 'kill "$active_pid" "$inactive_pid" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

printf '%s\n' "$active_pid" > "$STATUS_DIR/sidebar-clients/%1.pid"
printf '%s\n' "$inactive_pid" > "$STATUS_DIR/sidebar-clients/%2.pid"

sleep 0.2

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" bash -c '
    source "'"$REPO_DIR"'/scripts/lib/session-status.sh"
    source "'"$REPO_DIR"'/scripts/lib/sidebar-clients.sh"
    signal_sidebar_clients USR1 all
    signal_sidebar_clients USR2 active
'

sleep 1.2

[ -f "$active_refresh" ] || { echo "active sidebar should receive refresh signal" >&2; exit 1; }
[ -f "$inactive_refresh" ] || { echo "inactive sidebar should receive refresh signal" >&2; exit 1; }
[ -f "$active_animate" ] || { echo "active sidebar should receive animation signal" >&2; exit 1; }
[ ! -f "$inactive_animate" ] || { echo "inactive sidebar should not receive animation signal" >&2; exit 1; }

echo "sidebar client signaling checks passed"
