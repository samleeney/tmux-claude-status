#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
STATE_DIR="$TMP_DIR/state"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$STATE_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    list-panes)
        if [ "\${2:-}" = "-a" ]; then
            printf 'repo${tab}%%1${tab}0${tab}main${tab}bash${tab}\n'
            printf 'repo${tab}%%2${tab}1${tab}review${tab}nvim${tab}\n'
            exit 0
        fi
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "working" > "$STATUS_DIR/repo.status"
echo "working" > "$PANE_DIR/repo_%1.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "done" > "$PANE_DIR/repo_%2.status"
echo "codex" > "$PANE_DIR/repo_%2.agent"

switcher_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --list)"

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local message="$3"

    if ! printf '%s\n' "$haystack" | grep -Fq "$needle"; then
        echo "Assertion failed: $message" >&2
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1"
    local haystack="$2"
    local message="$3"

    if printf '%s\n' "$haystack" | grep -Fq "$needle"; then
        echo "Assertion failed: $message" >&2
        exit 1
    fi
}

assert_contains "[session] repo" "$switcher_output" "switcher should include a session row by default"
assert_not_contains "[window] repo / main" "$switcher_output" "switcher should hide window rows until the session is expanded"
assert_not_contains "[pane] repo / review : nvim" "$switcher_output" "switcher should hide pane rows until the window is expanded"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --toggle-expand "repo" "S"

expanded_session_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --list)"

assert_contains "[window] repo / main" "$expanded_session_output" "expanded sessions should reveal their windows"
assert_contains "[window] repo / review" "$expanded_session_output" "expanded sessions should reveal all windows"
assert_not_contains "[pane] repo / review : nvim" "$expanded_session_output" "panes should stay hidden until the window is expanded"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --toggle-expand "repo:w1" "P"

expanded_window_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --list)"

assert_contains "[pane] repo / review : nvim" "$expanded_window_output" "expanded windows should reveal their panes"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --toggle-expand "repo:w1" "P"

collapsed_window_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --list)"

assert_not_contains "[pane] repo / review : nvim" "$collapsed_window_output" "toggling the same window should collapse its panes"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --toggle-expand "repo" "S"

collapsed_session_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --list)"

assert_not_contains "[window] repo / main" "$collapsed_session_output" "collapsing the session should hide child windows again"

echo "switcher scope list regression checks passed"
