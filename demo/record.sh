#!/usr/bin/env bash
# Record a demo GIF.
# Usage: ./demo/record.sh <name>
#   e.g. ./demo/record.sh sidebar
#
# This records an asciinema cast, then converts to GIF with agg.
# You interact with tmux manually during recording.
# Press ctrl-d or type 'exit' to stop recording.

set -euo pipefail

NAME="${1:?Usage: $0 <name>  (e.g. sidebar, switcher, actions)}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAST="$DEMO_DIR/${NAME}.cast"
GIF="$DEMO_DIR/${NAME}.gif"

if ! command -v asciinema &>/dev/null; then
    echo "Error: asciinema not found. Install with: sudo pacman -S asciinema"
    exit 1
fi

if ! command -v agg &>/dev/null; then
    echo "Warning: agg not found. Cast will be saved but not converted to GIF."
    echo "Install with: cargo install --git https://github.com/asciinema/agg"
fi

echo ""
echo "Recording: $NAME"
echo "Cast file: $CAST"
echo ""
echo "Tips for recording:"
echo "  - Keep it short (10-15 seconds)"
echo "  - Use smooth, deliberate keystrokes"
echo "  - Pause briefly after each action so viewers can see the result"
echo ""
echo "Press Enter to start recording, ctrl-d to stop."
read -r

asciinema rec "$CAST" --overwrite -c "tmux attach" --cols 120 --rows 35

echo ""

if command -v agg &>/dev/null; then
    echo "Converting to GIF..."
    agg "$CAST" "$GIF" \
        --theme mocha \
        --font-size 16 \
        --font-family "JetBrains Mono" \
        --speed 1.0 \
        --idle-time-limit 2
    echo "Saved: $GIF ($(du -h "$GIF" | cut -f1))"
else
    echo "Cast saved: $CAST"
    echo "Convert manually: agg $CAST $GIF --theme mocha --font-size 16"
fi
