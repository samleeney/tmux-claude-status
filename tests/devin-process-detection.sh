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
    list-panes) echo 5000 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "5000 1 -bash"
printf '%s\n' "5001 5000 /home/u/.local/bin/devin -p"
EOF
chmod +x "$FAKE_BIN/ps"

export PATH="$FAKE_BIN:$PATH"

source "$REPO_DIR/scripts/lib/agent-processes.sh"

if session_has_agent_process "devin"; then
    echo "devin process detection checks passed"
else
    echo "Assertion failed: a 'devin' descendant process should be detected via the default agent pattern" >&2
    exit 1
fi
