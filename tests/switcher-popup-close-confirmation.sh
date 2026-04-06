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
    confirm-before)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

PATH="$FAKE_BIN:$PATH" \
HOME="$TMP_DIR/home" \
"$REPO_DIR/scripts/hook-based-switcher.sh" --popup-close "repo:w0" "P"

if ! grep -Fq "confirm-before -b -p Close window repo:0 (build) and all child panes?" "$LOG_FILE"; then
    echo "Assertion failed: popup close should request background confirmation for window targets" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "switcher popup close confirmation regression checks passed"
