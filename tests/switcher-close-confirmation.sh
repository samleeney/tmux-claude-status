#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
LOG_FILE="$TMP_DIR/tmux.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "\$*" >> "$LOG_FILE"

case "\${1:-}" in
    display-message)
        if [ "\${2:-}" = "-p" ] && [ "\${3:-}" = "-t" ] && [ "\${4:-}" = "repo:0" ] && [ "\${5:-}" = "#{window_name}" ]; then
            echo "build"
            exit 0
        fi
        exit 1
        ;;
    run-shell)
        exit 0
        ;;
    confirm-before)
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

PATH="$FAKE_BIN:$PATH" \
HOME="$TMP_DIR/home" \
"$REPO_DIR/scripts/hook-based-switcher.sh" --close "repo:w0" "P"

if grep -Fq "confirm-before" "$LOG_FILE"; then
    echo "Assertion failed: switcher window close should not request confirmation" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

if ! grep -Fq "run-shell -b $REPO_DIR/scripts/close-target.sh repo:w0 P" "$LOG_FILE"; then
    echo "Assertion failed: switcher window close should dispatch close-target directly" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "switcher close without confirmation regression checks passed"
