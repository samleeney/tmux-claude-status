#!/usr/bin/env bash

# Shared notification sound player for tmux-claude-status
# Reads @claude-notification-sound from tmux options and plays the appropriate sound.
# Usage: play-sound.sh [&]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SOUND_CHOICE=$(tmux show-option -gqv @claude-notification-sound 2>/dev/null)
: "${SOUND_CHOICE:=bell}"

case "$SOUND_CHOICE" in
    none)
        exit 0
        ;;
esac

# Map choice to sound files
# Bundled sounds live in $PLUGIN_DIR/sounds/; system sounds used as fallback
case "$SOUND_CHOICE" in
    speech)
        BUNDLED_SOUND="$PLUGIN_DIR/sounds/speech.wav"
        LINUX_SOUND=""
        MAC_SOUND=""
        ;;
    bell)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/bell.oga"
        MAC_SOUND="Ping.aiff"
        ;;
    fanfare)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/dialog-information.oga"
        MAC_SOUND="Hero.aiff"
        ;;
    frog)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/phone-incoming-call.oga"
        MAC_SOUND="Frog.aiff"
        ;;
    chime)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/complete.oga"
        MAC_SOUND="Glass.aiff"
        ;;
    *)
        # unrecognised value falls back to bell
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/bell.oga"
        MAC_SOUND="Ping.aiff"
        ;;
esac

if [ -n "${BUNDLED_SOUND:-}" ] && [ -f "$BUNDLED_SOUND" ]; then
    if command -v paplay >/dev/null 2>&1; then
        paplay "$BUNDLED_SOUND" 2>/dev/null &
    elif command -v afplay >/dev/null 2>&1; then
        afplay "$BUNDLED_SOUND" 2>/dev/null &
    elif command -v aplay >/dev/null 2>&1; then
        aplay "$BUNDLED_SOUND" 2>/dev/null &
    fi
elif command -v paplay >/dev/null 2>&1 && [ -f "$LINUX_SOUND" ]; then
    paplay "$LINUX_SOUND" 2>/dev/null &
elif command -v afplay >/dev/null 2>&1; then
    afplay "/System/Library/Sounds/$MAC_SOUND" 2>/dev/null &
elif command -v beep >/dev/null 2>&1; then
    beep 2>/dev/null &
else
    echo -ne '\a'
fi

exit 0
