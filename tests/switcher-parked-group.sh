#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PARKED_DIR" "$PANE_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    list-panes)
        case "\${2:-}" in
            -a)
                # session, pane_id, win_idx, win_name, pane_title, pane_cmd
                printf 'parked-task${tab}%%1${tab}0${tab}bash${tab}${tab}bash\n'
                ;;
            -t)
                case "\${5:-}" in
                    "#{pane_id}") echo "%1" ;;
                    *) exit 0 ;;
                esac
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "parked" > "$PANE_DIR/parked-task_%1.status"
: > "$PARKED_DIR/parked-task_%1.parked"

switcher_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --list)"

# Parked panes should show magenta P icon (ESC[1;35m)
if ! printf '%s\n' "$switcher_output" | grep -q $'\033\[1;35m'; then
    echo "Assertion failed: switcher should show parked icon for parked panes" >&2
    exit 1
fi
if ! printf '%s\n' "$switcher_output" | grep -Fq "parked-task"; then
    echo "Assertion failed: switcher should include the parked-task session" >&2
    exit 1
fi

echo "switcher parked grouping regression checks passed"
