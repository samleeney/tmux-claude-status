#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="$REPO_DIR/scripts/hook-based-switcher.sh"

assert_contains() {
    local needle="$1"
    local message="$2"

    if ! grep -Fq -- "$needle" "$SCRIPT_FILE"; then
        echo "Assertion failed: $message" >&2
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1"
    local message="$2"

    if grep -Fq -- "$needle" "$SCRIPT_FILE"; then
        echo "Assertion failed: $message" >&2
        exit 1
    fi
}

assert_contains '--bind="ctrl-x:' "switcher should use ctrl-x for close"
assert_contains '--bind="ctrl-p:' "switcher should use ctrl-p for park"
assert_contains '--bind="ctrl-w:' "switcher should use ctrl-w for wait"
assert_contains 'ctrl-x close  ctrl-p park  ctrl-w wait' "switcher header should advertise control-key actions"

assert_not_contains '--bind="x:' "plain x should not be bound in the switcher"
assert_not_contains '--bind="p:' "plain p should not be bound in the switcher"
assert_not_contains '--bind="w:' "plain w should not be bound in the switcher"
assert_not_contains '--bind="alt-x:' "alt-x should no longer be bound in the switcher"

echo "switcher action binding regression checks passed"
