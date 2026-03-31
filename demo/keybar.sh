#!/usr/bin/env bash
# Keystroke display bar — runs in a tiny bottom pane.
# Reads from a FIFO and displays each message with styling.
# Messages auto-clear after 3 seconds.

FIFO="/tmp/demo-keybar-fifo"

# Clear line on exit
trap 'printf "\033[2J\033[H"; exit 0' EXIT INT TERM

printf "\033[2J\033[H"
printf "\033[90m  Ready to record...\033[0m"

while true; do
    if read -r msg < "$FIFO" 2>/dev/null; then
        if [[ "$msg" == "QUIT" ]]; then
            exit 0
        fi
        printf "\033[2J\033[H"
        printf "\033[1;36m  ⌨  %s\033[0m" "$msg"
        # Auto-clear after 3s (in background)
        (sleep 3 && printf "\033[2J\033[H" 2>/dev/null) &
    fi
done
