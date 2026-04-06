#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    display-message)
        printf 'repo\t2\tbuild\t1\t%%4\tnvim\t/home/test/repo\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

PATH="$FAKE_BIN:$PATH"

# shellcheck source=../scripts/lib/preview.sh
source "$REPO_DIR/scripts/lib/preview.sh"

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    if [ "$actual" != "$expected" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

assert_eq \
    "$(sidebar_preview_target "repo" "S")" \
    "repo" \
    "session rows should preview the active pane in the session"

assert_eq \
    "$(sidebar_preview_target "repo:%4" "P")" \
    "%4" \
    "pane rows should preview the selected pane"

assert_eq \
    "$(sidebar_preview_target "repo:w2" "P")" \
    "repo:2" \
    "window rows should preview the active pane in the selected window"

assert_eq \
    "$(sidebar_preview_selection_key "repo:%4" "P")" \
    "P|repo:%4" \
    "pane preview cache keys should include the pane selection"

assert_eq \
    "$(sidebar_preview_selection_key "repo:w2" "P")" \
    "P|repo:w2" \
    "window preview cache keys should be distinct from pane selections in the same session"

assert_eq \
    "$(sidebar_preview_title "repo:w2" "P")" \
    "repo | window 2" \
    "window preview titles should identify the selected window"

assert_eq \
    "$(sidebar_preview_metadata "repo" "S")" \
    $'active window 2: build | pane 1 (%4) | nvim\n/home/test/repo' \
    "session preview metadata should describe the active window and pane"

assert_eq \
    "$(sidebar_preview_metadata "repo:%4" "P")" \
    $'pane 1 (%4) | window 2: build | nvim\n/home/test/repo' \
    "pane preview metadata should describe the selected pane"

assert_eq \
    "$(sidebar_preview_metadata "repo:w2" "P")" \
    $'window 2: build | active pane 1 (%4) | nvim\n/home/test/repo' \
    "window preview metadata should describe the selected window and its active pane"

echo "sidebar preview target regression checks passed"
