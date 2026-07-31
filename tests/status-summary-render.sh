#!/usr/bin/env bash
# render_status_summary: one glyph per agent, with working glyphs animated
# out of phase (staggered by position) so a row of busy agents pulses
# rather than blinking in unison.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$REPO_DIR/scripts/lib/status-summary.sh"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

frame0="$(render_status_summary 0 claude:working claude:working codex:done)"
assert_eq "#[fg=yellow,bold]✳#[default] #[fg=yellow,bold]✻#[default] #[fg=green]⬢#[default]" \
    "$frame0" "adjacent working glyphs should render staggered at frame 0"

frame1="$(render_status_summary 1 claude:working claude:working codex:done)"
assert_eq "#[fg=yellow,bold]✻#[default] #[fg=yellow,bold]✳#[default] #[fg=green]⬢#[default]" \
    "$frame1" "frame 1 should flip every working glyph but not the done glyph"

assert_eq "" "$(render_status_summary 0)" "no agents should render an empty summary"

echo "status summary render checks passed"
