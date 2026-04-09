#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
PARKED_DIR="$STATUS_DIR/parked"
WAIT_DIR="$STATUS_DIR/wait"
LOG_FILE="$TMP_DIR/tmux.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$PARKED_DIR" "$WAIT_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "\$*" >> "$LOG_FILE"

case "\${1:-}" in
    display-message)
        if [ "\${2:-}" = "-p" ]; then
            case "\${3:-}" in
                "#{client_session}"|"#{session_name}") echo "repo" ;;
                "#{window_index}") echo "0" ;;
                "#{pane_id}") echo "%1" ;;
                *) exit 1 ;;
            esac
            exit 0
        fi
        exit 0
        ;;
    list-sessions)
        printf 'repo\nzeta\n'
        ;;
    list-panes)
        if [ "\${2:-}" = "-a" ] && [ "\${3:-}" = "-F" ]; then
            case "\${4:-}" in
                "#{session_name}${tab}#{pane_id}${tab}#{pane_current_path}${tab}#{pane_pid}${tab}#{window_index}${tab}#{window_name}")
                    printf 'repo${tab}%%1${tab}/home/test/repo${tab}101${tab}0${tab}main\n'
                    printf 'zeta${tab}%%9${tab}/home/test/zeta${tab}109${tab}0${tab}next\n'
                    exit 0
                    ;;
                "#{session_name}${tab}#{pane_id}")
                    printf 'repo${tab}%%1\n'
                    printf 'zeta${tab}%%9\n'
                    exit 0
                    ;;
            esac
        fi

        if [ "\${2:-}" = "-t" ] && [ "\${4:-}" = "-F" ] && [ "\${5:-}" = "#{pane_id}" ]; then
            case "\${3:-}" in
                repo)
                    printf '%%1\n'
                    ;;
                zeta)
                    printf '%%9\n'
                    ;;
                *)
                    exit 1
                    ;;
            esac
            exit 0
        fi
        exit 1
        ;;
    switch-client|select-window|select-pane)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "-eo" ] || [ "${2:-}" != "pid=,ppid=" ]; then
    exit 1
fi

cat <<'OUT'
101 1
109 1
OUT
EOF
chmod +x "$FAKE_BIN/ps"

echo "done" > "$STATUS_DIR/repo.status"
echo "done" > "$STATUS_DIR/zeta.status"
echo "done" > "$PANE_DIR/repo_%1.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "done" > "$PANE_DIR/zeta_%9.status"
echo "claude" > "$PANE_DIR/zeta_%9.agent"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
bash "$REPO_DIR/scripts/park-session.sh"

if ! grep -Fq "switch-client -t zeta" "$LOG_FILE"; then
    echo "Assertion failed: parking the current session should switch to the next inbox item" >&2
    sed -n '1,120p' "$LOG_FILE" >&2
    exit 1
fi
if [ ! -f "$PARKED_DIR/repo.parked" ] || [ ! -f "$PARKED_DIR/repo_%1.parked" ]; then
    echo "Assertion failed: park-session should still mark the current session as parked" >&2
    exit 1
fi

echo "park session next inbox regression checks passed"
