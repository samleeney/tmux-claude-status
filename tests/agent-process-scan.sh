#!/usr/bin/env bash
# scan_agent_processes must register real agent commands (including
# interpreter-run ones like npm's "node .../bin/claude") while ignoring
# command lines that merely mention an agent name.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "-eo" ] || [ "${2:-}" != "pid=,args=" ]; then
    exit 1
fi

cat <<'OUT'
  101 claude --model opus
  102 /usr/local/bin/codex exec
  103 node /home/u/.nvm/versions/node/v24.12.0/bin/claude --resume
  104 /home/u/.local/bin/devin -p
  105 man claude
  106 tail -f logs/claude
  107 vim notes/claude
  108 ssh codex
  109 grep claude TODO.md
OUT
EOF
chmod +x "$FAKE_BIN/ps"

export PATH="$FAKE_BIN:$PATH"

source "$REPO_DIR/scripts/lib/agent-processes.sh"

actual="$(scan_agent_processes | awk '{print $1 ":" $2}' | sort)"
expected="claude:101
claude:103
codex:102
devin:104"

if [ "$actual" != "$expected" ]; then
    echo "Assertion failed: scan_agent_processes classification mismatch" >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
fi

echo "agent process scan checks passed"
