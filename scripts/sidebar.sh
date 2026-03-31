#!/usr/bin/env bash

# Agent sidebar — persistent split-pane TUI showing session status.
# Supports worktree nesting and multi-agent pane display.
# Runs inside a tmux pane created by sidebar-toggle.sh.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$CURRENT_DIR")"

# shellcheck source=lib/session-status.sh
source "$CURRENT_DIR/lib/session-status.sh"

# ─── Mode ─────────────────────────────────────────────────────────
PREVIEW_MODE=0
[[ "${1:-}" == "--preview" ]] && PREVIEW_MODE=1

# ─── Terminal setup ───────────────────────────────────────────────
cleanup() {
    printf '\033[?1000l\033[?1006l' 2>/dev/null  # disable mouse
    tput cnorm 2>/dev/null
    stty echo 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

tput civis  # hide cursor
stty -echo 2>/dev/null
# Enable mouse click tracking (SGR mode) only in sidebar pane mode.
# In popup/preview mode, skip mouse to avoid event storms.
if (( ! PREVIEW_MODE )); then
    printf '\033[?1000h\033[?1006h'
fi

# ─── State ────────────────────────────────────────────────────────
SELECTED=0
SCROLL_OFFSET=0
SESS_START=0  # index in SEL_NAMES where SESSIONS section begins
SEARCH_QUERY=""
SEARCH_ACTIVE=0

# Cached values from collect(), used by render().
CUR_SESSION=""
CUR_PANE=""


# Screen row (1-based) → selectable index. Populated by render().
declare -a SCREEN_SEL=()

# Change detection: skip collect when status dir hasn't changed.
_LAST_STATUS_MTIME=""
_COLLECT_TICK=0

# Flat list rebuilt each frame.  Each element is one of:
#   "G|<label>|<color>"                          — group header (not selectable)
#   "S|<name>|<state>|<extra>|<ssh>"             — session (selectable)
#   "W|<name>|<state>|<extra>|<ssh>|<is_last>"   — worktree child (selectable)
#   "P|<session>|<pane_id>|<agent>|<status>|<is_last>" — agent pane (selectable)
ENTRIES=()
# Per-session pane counts: session → "working:done:wait" (only for multi-agent sessions)
declare -A PANE_COUNTS=()

# Parallel arrays for selectable items.
SEL_NAMES=()     # session name (for S/W) or "session:pane_id" (for P)
SEL_TYPES=()     # "S", "W", or "P"
SEL_COUNT=0

# Persistent across collect cycles: tracks known agent panes.
# Key: "session:pane_id"  Value: "agent_name"
declare -A KNOWN_AGENTS=()
# Set of pane IDs that currently exist in tmux (rebuilt each cycle).
declare -A LIVE_PANES=()

# Inline wait-input state.
WAIT_INPUT_ACTIVE=0
WAIT_INPUT_TARGET=""
WAIT_INPUT_BUF=""

# Spinner for working sessions (cycles each render).
SPINNER_FRAMES=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
SPINNER_TICK=0

# Preview cache — only re-capture when selection or data changes.
_PREVIEW_SEL=""
_PREVIEW_LINES=()
_PREVIEW_DIRTY=1

# ─── ANSI helpers ─────────────────────────────────────────────────
RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
UND=$'\033[4m'
YEL=$'\033[33m'
GRN=$'\033[32m'
MAG=$'\033[35m'
CYN=$'\033[36m'
GRY=$'\033[90m'
WHT=$'\033[97m'
BYEL=$'\033[1;33m'
BGRN=$'\033[1;32m'
BMAG=$'\033[1;35m'
BCYN=$'\033[1;36m'
# Selection highlight: subtle background
SEL_BG=$'\033[48;5;236m'   # dark gray bg
CUR_BG=$'\033[48;5;235m'   # slightly darker for current session accent
ACC_GRN=$'\033[38;5;114m'  # soft green accent for current session bar

# ─── Fuzzy match ──────────────────────────────────────────────────
# Returns 0 if all chars in $1 appear in order in $2 (case-insensitive).
_fuzzy_match() {
    local q="${1,,}" t="${2,,}"
    local qi=0 ti=0 qlen=${#q} tlen=${#t}
    (( qlen == 0 )) && return 0
    while (( qi < qlen && ti < tlen )); do
        [[ "${q:$qi:1}" == "${t:$ti:1}" ]] && ((qi++))
        ((ti++))
    done
    (( qi == qlen ))
}

# ─── PID ancestry helpers ─────────────────────────────────────────
# Global PID→PPID map, populated once per collect cycle.
declare -A PID_PPID

_build_pid_map() {
    PID_PPID=()
    while read -r p pp; do
        [ -z "$p" ] && continue
        PID_PPID[$p]="$pp"
    done < <(ps -eo pid=,ppid= 2>/dev/null)
}

# Walk up the process tree from $1 looking for any PID in the
# space-separated set $2.  Returns 0 and prints the matching pane PID.
find_ancestor_pane() {
    local pid="$1"
    local pane_pid_set=" $2 "
    local depth=0
    while (( pid > 1 && depth < 30 )); do
        if [[ "$pane_pid_set" == *" $pid "* ]]; then
            echo "$pid"
            return 0
        fi
        pid="${PID_PPID[$pid]:-}"
        [ -z "$pid" ] && return 1
        ((depth++))
    done
    return 1
}

# ─── Data collection ─────────────────────────────────────────────
_collect_cur_client() {
    local info
    info=$(tmux display-message -p $'#{client_session}\t#{pane_id}' 2>/dev/null || true)
    CUR_SESSION="${info%%	*}"
    CUR_PANE="${info#*	}"
}

collect() {
    # Quick change detection: skip full rebuild if nothing changed.
    # Check mtimes of status dir, parked dir, and wait dir.
    # Force full rebuild every ~10s to catch status content changes and new agents.
    (( ++_COLLECT_TICK >= 10 )) && { _COLLECT_TICK=0; _LAST_STATUS_MTIME=""; }
    local cur_mtime
    cur_mtime=$(stat -c %Y "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR" 2>/dev/null)
    if [[ "$cur_mtime" == "$_LAST_STATUS_MTIME" ]]; then
        _collect_cur_client
        return
    fi
    _LAST_STATUS_MTIME="$cur_mtime"

    ENTRIES=()
    SEL_NAMES=()
    SEL_TYPES=()

    local now
    printf -v now '%(%s)T' -1

    # ── 1+2. Session + pane data (single tmux call) ────────────
    declare -A sess_state sess_extra sess_ssh sess_seen
    declare -A sess_cwd
    declare -A pane_to_session   # pane_pid → session
    declare -A pane_to_id        # pane_pid → pane_id (e.g. %5)
    declare -A pane_to_window    # pane_id → window_index
    declare -A window_names      # session:window_index → window_name
    local all_pane_pids=""

    local _tab=$'\t'
    while IFS=$'\t' read -r sname pane_id pcwd ppid win_idx win_name; do
        [ -z "$sname" ] && continue

        # Pane data
        [[ -z "${sess_cwd[$sname]:-}" ]] && sess_cwd[$sname]="$pcwd"
        pane_to_session[$ppid]="$sname"
        pane_to_id[$ppid]="$pane_id"
        pane_to_window[$pane_id]="$win_idx"
        window_names["${sname}:${win_idx}"]="$win_name"
        all_pane_pids+="$ppid "

        # Session status (first pane per session)
        [[ -n "${sess_seen[$sname]:-}" ]] && continue
        sess_seen[$sname]=1

        local state="noagent" extra="" is_ssh=""
        local status=""

        if [ -f "$PARKED_DIR/${sname}.parked" ]; then
            status="parked"
        elif [ -f "$STATUS_DIR/${sname}-remote.status" ]; then
            status=$(<"$STATUS_DIR/${sname}-remote.status")
            is_ssh="ssh"
        fi
        if [ -f "$STATUS_DIR/${sname}.status" ]; then
            status=$(<"$STATUS_DIR/${sname}.status")
        fi
        [ -n "$status" ] && state="$status"

        if [ "$state" = "wait" ]; then
            local wf="$WAIT_DIR/${sname}.wait"
            if [ -f "$wf" ]; then
                local expiry
                expiry=$(<"$wf")
                if [ -n "$expiry" ] && (( expiry > now )); then
                    extra="$(( (expiry - now + 59) / 60 ))m"
                else
                    state="done"
                fi
            fi
        fi
        # Clear any stale unread markers (unread is no longer a distinct state)
        rm -f "$STATUS_DIR/${sname}.unread" "$STATUS_DIR/${sname}-remote.unread" 2>/dev/null

        sess_state[$sname]="$state"
        sess_extra[$sname]="$extra"
        sess_ssh[$sname]="$is_ssh"
    done < <(tmux list-panes -a -F "#{session_name}${_tab}#{pane_id}${_tab}#{pane_current_path}${_tab}#{pane_pid}${_tab}#{window_index}${_tab}#{window_name}" 2>/dev/null)

    # ── 3. Worktree detection ────────────────────────────────────
    # session → parent session name
    declare -A worktree_parent
    # parent session → space-separated children
    declare -A worktree_children

    # Build reverse map: repo_root → session name (for sessions not under .claude/worktrees)
    declare -A root_to_session
    for sname in "${!sess_cwd[@]}"; do
        local cwd="${sess_cwd[$sname]}"
        # Skip if this cwd is inside a worktree path
        if [[ "$cwd" != */.claude/worktrees/* ]]; then
            root_to_session[$cwd]="$sname"
        fi
    done

    for sname in "${!sess_cwd[@]}"; do
        local cwd="${sess_cwd[$sname]}"
        if [[ "$cwd" == */.claude/worktrees/* ]]; then
            # Extract the repo root (everything before /.claude/worktrees/)
            local repo_root="${cwd%%/.claude/worktrees/*}"
            local parent="${root_to_session[$repo_root]:-}"
            if [ -n "$parent" ] && [ "$parent" != "$sname" ]; then
                worktree_parent[$sname]="$parent"
                worktree_children[$parent]+="$sname "
            fi
        fi
    done

    # ── 4. Multi-agent pane detection ────────────────────────────
    # Track which panes are alive this cycle (for pruning KNOWN_AGENTS).
    LIVE_PANES=()
    for ppid in $all_pane_pids; do
        local pid="${pane_to_id[$ppid]:-}"
        [ -n "$pid" ] && LIVE_PANES[$pid]=1
    done

    # Prune known agents whose pane no longer exists in tmux.
    for key in "${!KNOWN_AGENTS[@]}"; do
        local pid="${key#*:}"
        [[ -z "${LIVE_PANES[$pid]:-}" ]] && unset "KNOWN_AGENTS[$key]"
    done

    # Find agent processes — only build PID map if agents exist.
    # Track which panes have an active agent process THIS cycle.
    declare -A _active_agent_panes=()
    local agent_lines
    agent_lines=$(pgrep -a "claude|codex" 2>/dev/null || true)
    if [[ -n "$agent_lines" ]]; then
        _build_pid_map
        while IFS= read -r apid_line; do
            [ -z "$apid_line" ] && continue
            local apid="${apid_line%% *}"
            local acmd="${apid_line#* }"
            local agent_name="agent"
            [[ "$acmd" == *claude* ]] && agent_name="claude"
            [[ "$acmd" == *codex* ]] && agent_name="codex"

            local pane_pid
            pane_pid=$(find_ancestor_pane "$apid" "$all_pane_pids") || continue
            local owner="${pane_to_session[$pane_pid]:-}"
            [ -z "$owner" ] && continue
            local pid_id="${pane_to_id[$pane_pid]:-}"

            KNOWN_AGENTS["${owner}:${pid_id}"]="$agent_name"
            _active_agent_panes["${owner}:${pid_id}"]=1
        done <<< "$agent_lines"
    fi

    # Build sess_agents: session → "pane_id:agent_name:status ..."
    # Read per-pane status files (written by hooks) when available,
    # fall back to session-level status.
    # If a known pane has no active agent process and its status is
    # "working", the agent exited without firing the Stop hook — fix it.
    local pane_dir="$STATUS_DIR/panes"
    declare -A sess_agents
    for key in "${!KNOWN_AGENTS[@]}"; do
        local owner="${key%%:*}"
        local pid_id="${key#*:}"
        local agent_name="${KNOWN_AGENTS[$key]}"
        local pane_status=""
        local pane_file="$pane_dir/${owner}_${pid_id}.status"
        if [ -f "$pane_file" ]; then
            pane_status=$(<"$pane_file")
        fi
        [ -z "$pane_status" ] && pane_status="${sess_state[$owner]:-done}"
        # Fix stale "working" status when agent process is no longer running
        if [[ "$pane_status" == "working" ]] && [[ -z "${_active_agent_panes[$key]:-}" ]]; then
            pane_status="done"
            [ -f "$pane_file" ] && echo "done" > "$pane_file" 2>/dev/null
        fi
        sess_agents[$owner]+="${pid_id}:${agent_name}:${pane_status} "
    done

    # Priority: done > working > wait > parked > noagent
    _state_pri() {
        case "$1" in
            done)    echo 4 ;; working) echo 3 ;;
            wait)    echo 2 ;; parked)  echo 1 ;; *)       echo 0 ;;
        esac
    }

    # ── 5. Re-derive session state from per-pane statuses ──────
    # When per-pane files exist, the session's display state should be
    # the highest-priority among its panes (not just the session file).
    # Skip sessions with explicit user overrides (wait/parked) since
    # those should not be overridden by stale per-pane statuses.
    for sname in "${!sess_agents[@]}"; do
        local cur_st="${sess_state[$sname]}"
        [[ "$cur_st" == "wait" || "$cur_st" == "parked" ]] && continue
        local best_pri=-1 best_st="$cur_st"
        best_pri=$(_state_pri "$best_st" 2>/dev/null || echo 0)
        for ap in ${sess_agents[$sname]}; do
            local rest="${ap#*:}"; rest="${rest#*:}"
            local ps="${rest%%:*}"
            local pp
            pp=$(_state_pri "$ps" 2>/dev/null || echo 0)
            if (( pp > best_pri )); then
                best_pri=$pp; best_st="$ps"
            fi
        done
        sess_state[$sname]="$best_st"
    done

    # ── 5b. Compute per-session pane counts ─────────────────────
    PANE_COUNTS=()
    for sname in "${!sess_agents[@]}"; do
        local agents="${sess_agents[$sname]}"
        local pw=0 pd=0 pwt=0 count=0
        local seen=""
        for ap in $agents; do
            local pid="${ap%%:*}"
            [[ " $seen " == *" $pid "* ]] && continue
            seen+="$pid "
            local rest="${ap#*:}"; local ps="${rest#*:}"
            case "$ps" in
                working) ((pw++)) ;; done) ((pd++)) ;; wait) ((pwt++)) ;;
            esac
            ((count++))
        done
        (( count > 1 )) && PANE_COUNTS[$sname]="${pw}:${pd}:${pwt}"
    done

    # ── 6. Collapse single-worktree parents ────────────────────
    # Only nest worktrees when a parent has 2+ children.
    for parent in "${!worktree_children[@]}"; do
        local children=(${worktree_children[$parent]})
        if (( ${#children[@]} < 2 )); then
            # Undo the parent-child link; treat the single child as standalone.
            for child in "${children[@]}"; do
                unset "worktree_parent[$child]"
            done
            unset "worktree_children[$parent]"
        fi
    done

    # ── 7. Compute effective state (bubble-up) ─────────────────
    declare -A eff_state
    for sname in "${!sess_state[@]}"; do
        eff_state[$sname]="${sess_state[$sname]}"
    done

    # Bubble children's states up to parent (highest priority wins).
    for parent in "${!worktree_children[@]}"; do
        local best="${eff_state[$parent]}"
        local best_pri
        best_pri=$(_state_pri "$best")
        for child in ${worktree_children[$parent]}; do
            local cp
            cp=$(_state_pri "${sess_state[$child]}")
            if (( cp > best_pri )); then
                best_pri=$cp
                best="${sess_state[$child]}"
            fi
        done
        eff_state[$parent]="$best"
    done

    # ── 8. Build ENTRIES ─────────────────────────────────────────

    # Helper: parse sess_agents into a deduplicated array.
    # Format: "pane_id:agent_name:status ..."
    _get_agent_arr() {
        local session="$1"
        local agents="${sess_agents[$session]:-}"
        _agent_result=()
        [ -z "$agents" ] && return
        local seen=""
        for ap in $agents; do
            local pid="${ap%%:*}"
            [[ " $seen " == *" $pid "* ]] && continue
            seen+="$pid "
            _agent_result+=("$ap")
        done
    }

    # Helper: emit agent panes for a session, grouped by window when needed.
    # Rules: 0-1 agents → nothing. 2+ agents, 1 window → flat P. 2+ agents, 2+ windows → P(window) + Q(pane).
    _emit_agents() {
        local sname="$1"
        _get_agent_arr "$sname"
        local agents=("${_agent_result[@]}")
        (( ${#agents[@]} <= 1 )) && return

        # Group by window
        local -A win_agents=() win_seen=()
        local -a win_order=()
        for ap in "${agents[@]}"; do
            local pid="${ap%%:*}"
            local wi="${pane_to_window[$pid]:-0}"
            [[ -z "${win_seen[$wi]:-}" ]] && { win_order+=("$wi"); win_seen[$wi]=1; }
            win_agents[$wi]+="$ap "
        done

        if (( ${#win_order[@]} == 1 )); then
            # Single window — flat panes under session, skip window header
            local ai=0 total=${#agents[@]}
            for ap in "${agents[@]}"; do
                ((ai++))
                local pid="${ap%%:*}" r="${ap#*:}"
                local agent="${r%%:*}" st="${r#*:}"
                ENTRIES+=("P|${sname}|${pid}|${agent}|${st}|$((ai==total))")
                SEL_NAMES+=("${sname}:${pid}")
                SEL_TYPES+=("P")
            done
        else
            # Multiple windows
            local nw=${#win_order[@]} wi=0
            for widx in "${win_order[@]}"; do
                ((wi++))
                local wname="${window_names[${sname}:${widx}]:-window-$widx}"
                local w_last=$((wi==nw))
                # Count panes in this window
                local pc=0
                for _ in ${win_agents[$widx]}; do ((pc++)); done

                if (( pc == 1 )); then
                    # 1 agent in window — show window as leaf with agent's status
                    local ap="${win_agents[$widx]%% *}"
                    local pid="${ap%%:*}" r="${ap#*:}"
                    local st="${r#*:}"
                    ENTRIES+=("P|${sname}|${pid}|${wname}|${st}|${w_last}")
                    SEL_NAMES+=("${sname}:${pid}")
                    SEL_TYPES+=("P")
                else
                    # 2+ agents — window header + nested panes
                    local best_pri=-1 best_st="noagent"
                    for wap in ${win_agents[$widx]}; do
                        local ws="${wap#*:}"; ws="${ws#*:}"
                        local wp; wp=$(_state_pri "$ws" 2>/dev/null || echo 0)
                        (( wp > best_pri )) && { best_pri=$wp; best_st="$ws"; }
                    done
                    ENTRIES+=("P|${sname}|w${widx}|${wname}|${best_st}|${w_last}")
                    SEL_NAMES+=("${sname}:w${widx}")
                    SEL_TYPES+=("P")
                    local ai=0
                    for wap in ${win_agents[$widx]}; do
                        ((ai++))
                        local pid="${wap%%:*}" r="${wap#*:}"
                        local agent="${r%%:*}" st="${r#*:}"
                        ENTRIES+=("Q|${sname}|${pid}|${agent}|${st}|$((ai==pc))|${w_last}")
                        SEL_NAMES+=("${sname}:${pid}")
                        SEL_TYPES+=("P")
                    done
                fi
            done
        fi
    }

    # Helper: append a session + its children to ENTRIES.
    _emit_session() {
        local entry="$1" sname="$2"
        ENTRIES+=("$entry")
        SEL_NAMES+=("$sname")
        SEL_TYPES+=("S")

        # Worktree children
        local wt_list="${worktree_children[$sname]:-}"
        local wt_names=()
        for wt in $wt_list; do wt_names+=("$wt"); done
        local wi=0
        for wt in "${wt_names[@]}"; do
            ((wi++))
            local is_last=$((wi==${#wt_names[@]}))
            ENTRIES+=("W|${wt}|${sess_state[$wt]}|${sess_extra[$wt]}|${sess_ssh[$wt]}|${is_last}")
            SEL_NAMES+=("$wt")
            SEL_TYPES+=("W")
            _emit_agents "$wt"
        done

        _emit_agents "$sname"
    }

    # ── INBOX: panes/sessions with status "done" that need action ──
    # Rules mirror _emit_agents: 1 agent → session only, 2+ agents 1 window → per pane,
    # 2+ agents multi-window → per window (1 pane windows use window name).
    local inbox=()
    for sname in "${!sess_agents[@]}"; do
        [[ -f "$PARKED_DIR/${sname}.parked" ]] && continue
        _get_agent_arr "$sname"
        local arr=("${_agent_result[@]}")
        if (( ${#arr[@]} <= 1 )); then
            # Single agent — session-level inbox entry
            local ap="${arr[0]:-}"
            local pst="${ap#*:}"; pst="${pst#*:}"
            [[ "$pst" == "done" ]] && inbox+=("I|${sname}||${sname}|done")
            continue
        fi
        # Group by window
        local -A _ib_win=() _ib_wseen=()
        local -a _ib_worder=()
        for ap in "${arr[@]}"; do
            local pid="${ap%%:*}"
            local wi="${pane_to_window[$pid]:-0}"
            [[ -z "${_ib_wseen[$wi]:-}" ]] && { _ib_worder+=("$wi"); _ib_wseen[$wi]=1; }
            _ib_win[$wi]+="$ap "
        done
        if (( ${#_ib_worder[@]} == 1 )); then
            # Single window — per pane entries
            local ai=0
            for ap in "${arr[@]}"; do
                ((ai++))
                local pid="${ap%%:*}" r="${ap#*:}"
                local aname="${r%%:*}" pst="${r#*:}"
                [[ "$pst" == "done" ]] && inbox+=("I|${sname}|${pid}|${sname} › ${aname} #${ai}|done")
            done
        else
            # Multiple windows — per window entries
            for wi in "${_ib_worder[@]}"; do
                local wname="${window_names[${sname}:${wi}]:-window-$wi}"
                # Window status = best of its panes
                local best_pri=-1 best_st="noagent" any_done=0 w_pid=""
                for wap in ${_ib_win[$wi]}; do
                    local pid="${wap%%:*}" ws="${wap#*:}"; ws="${ws#*:}"
                    [[ -z "$w_pid" ]] && w_pid="$pid"
                    [[ "$ws" == "done" ]] && any_done=1
                    local wp; wp=$(_state_pri "$ws" 2>/dev/null || echo 0)
                    (( wp > best_pri )) && { best_pri=$wp; best_st="$ws"; }
                done
                (( any_done )) && inbox+=("I|${sname}|${w_pid}|${sname} › ${wname}|done")
            done
        fi
    done
    # Single-agent sessions (not in sess_agents) with done status
    for sname in "${!sess_state[@]}"; do
        [[ -n "${sess_agents[$sname]:-}" ]] && continue
        [[ -f "$PARKED_DIR/${sname}.parked" ]] && continue
        [[ -n "${worktree_parent[$sname]:-}" ]] && continue
        local st="${eff_state[$sname]}"
        [[ "$st" == "done" ]] && inbox+=("I|${sname}||${sname}|done")
    done

    if (( ${#inbox[@]} > 0 )); then
        # Sort inbox entries by label for consistency
        IFS=$'\n' inbox=($(sort -t'|' -k4 <<< "${inbox[*]}")); unset IFS
        ENTRIES+=("G|INBOX|$BGRN")
        for entry in "${inbox[@]}"; do
            ENTRIES+=("$entry")
            local r="${entry#I|}"
            local sname="${r%%|*}"; r="${r#*|}"
            local pid="${r%%|*}"
            if [[ -n "$pid" ]]; then
                SEL_NAMES+=("${sname}:${pid}")
                SEL_TYPES+=("P")
            else
                SEL_NAMES+=("$sname")
                SEL_TYPES+=("S")
            fi
        done
    fi

    # ── SESSIONS: all sessions sorted alphabetically ──────────────
    local sorted_sessions=()
    for sname in "${!sess_state[@]}"; do
        [[ -n "${worktree_parent[$sname]:-}" ]] && continue
        sorted_sessions+=("$sname")
    done
    IFS=$'\n' sorted_sessions=($(sort <<< "${sorted_sessions[*]}")); unset IFS

    SESS_START=${#SEL_NAMES[@]}
    if (( ${#sorted_sessions[@]} > 0 )); then
        ENTRIES+=("G|SESSIONS|$GRY")
        for sname in "${sorted_sessions[@]}"; do
            local st="${eff_state[$sname]}"
            local ex="${sess_extra[$sname]}"
            local ss="${sess_ssh[$sname]}"
            local entry="S|${sname}|${st}|${ex}|${ss}"
            _emit_session "$entry" "$sname"
        done
    fi

    SEL_COUNT=${#SEL_NAMES[@]}
    (( SEL_COUNT == 0 )) && SELECTED=0
    (( SELECTED >= SEL_COUNT )) && SELECTED=$((SEL_COUNT - 1))
    (( SELECTED < SESS_START )) && SELECTED=$SESS_START

    _collect_cur_client
}

# ─── Render ───────────────────────────────────────────────────────
render() {
    local W H
    read -r H W < <(stty size 2>/dev/null || echo "24 30")
    W=${W:-30}; H=${H:-24}

    # In preview mode, session list takes left portion; preview takes right.
    local LW=$W  # list width
    local preview_col=0 preview_width=0
    if (( PREVIEW_MODE )); then
        LW=$(( W * 35 / 100 ))
        (( LW < 25 )) && LW=25
        (( LW > W - 20 )) && LW=$((W - 20))
        preview_col=$((LW + 2))  # after separator
        preview_width=$((W - LW - 2))
    fi

    # Count by state for the header (per-pane when multi-agent)
    local nw=0 nd=0 nwt=0
    for e in "${ENTRIES[@]}"; do
        [[ "$e" != S\|* && "$e" != W\|* ]] && continue
        local rest="${e#?|}"
        local sname="${rest%%|*}"; rest="${rest#*|}"
        local st="${rest%%|*}"
        local counts="${PANE_COUNTS[$sname]:-}"
        if [[ -n "$counts" ]]; then
            IFS=: read -r _pw _pd _pwt <<< "$counts"
            ((nw += _pw)); ((nd += _pd)); ((nwt += _pwt))
        else
            case "$st" in
                working) ((nw++)) ;; done) ((nd++)) ;; wait) ((nwt++)) ;;
            esac
        fi
    done

    local cur_session="$CUR_SESSION"
    local cur_pane="$CUR_PANE"

    local line=0
    local buf=""

    # ── Header / Search bar ──
    if (( SEARCH_ACTIVE )); then
        buf+=" ${BOLD}/${RST}${SEARCH_QUERY}${DIM}▏${RST}\033[K\n"
    else
        buf+=" "
        (( nw > 0 ))  && buf+="${BYEL}${SPINNER_FRAMES[$SPINNER_TICK]}${nw}${RST} "
        (( nd > 0 ))  && buf+="${BGRN}✓${nd}${RST} "
        (( nwt > 0 )) && buf+="${BCYN}⏸${nwt}${RST} "
        (( nw + nd + nwt == 0 )) && buf+="${DIM}no agents${RST}"
        buf+="\033[K\n"
    fi
    ((line++))

    local sep="${DIM}"
    local i; for ((i=0; i<LW; i++)); do sep+="─"; done
    sep+="${RST}\033[K\n"
    buf+="$sep"
    ((line++))

    # ── Build render list (with search filtering) ──
    local render_lines=()
    local render_types=()
    local render_sel_indices=()

    local first_group=1
    local sel_idx=0
    local pending_group=""  # defer group header until we know it has visible children
    local pending_blank=0
    local group_has_items=0

    for entry in "${ENTRIES[@]}"; do
        local etype="${entry%%|*}"

        if [[ "$etype" == "G" ]]; then
            # Flush pending group if it had items
            # Save this group header for later (only emit if it has visible entries)
            pending_group="$entry"
            pending_blank=$((first_group == 0 ? 1 : 0))
            first_group=0
            group_has_items=0
            continue
        fi

        # Search filter: check if this item matches
        if (( SEARCH_ACTIVE )) && [[ -n "$SEARCH_QUERY" ]]; then
            local match_name=""
            case "$etype" in
                S|W) local r="${entry#?|}"; match_name="${r%%|*}" ;;
                P|Q) local r="${entry#?|}"; match_name="${r%%|*}"; r="${r#*|}"; r="${r#*|}"; match_name+=" ${r%%|*}" ;;
                I) local r="${entry#I|}"; r="${r#*|}"; r="${r#*|}"; match_name="${r%%|*}" ;;
            esac
            if ! _fuzzy_match "$SEARCH_QUERY" "$match_name"; then
                ((sel_idx++))
                continue
            fi
        fi

        # Emit deferred group header if this is the first visible item in group
        if (( group_has_items == 0 )) && [[ -n "$pending_group" ]]; then
            if (( pending_blank )); then
                render_lines+=("")
                render_types+=("B")
                render_sel_indices+=("-1")
            fi
            local rest="${pending_group#G|}"
            local label="${rest%%|*}"
            local color="${rest#*|}"
            render_lines+=("${color} ${label}${RST}")
            render_types+=("G")
            render_sel_indices+=("-1")
            pending_group=""
            group_has_items=1
        fi

        render_lines+=("$entry")
        render_types+=("$etype")
        render_sel_indices+=("$sel_idx")
        ((sel_idx++))
    done

    local total_render=${#render_lines[@]}

    # Ensure selected item is visible (scrolling)
    local sel_render_idx=-1
    for ((i=0; i<total_render; i++)); do
        local rt="${render_types[$i]}"
        if [[ "$rt" == "S" || "$rt" == "W" || "$rt" == "P" || "$rt" == "Q" || "$rt" == "I" ]] \
            && (( ${render_sel_indices[$i]} == SELECTED )); then
            sel_render_idx=$i
            break
        fi
    done

    local avail=$((H - line - 2))  # footer takes 2 lines
    if (( sel_render_idx >= 0 )); then
        if (( sel_render_idx < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$sel_render_idx
        elif (( sel_render_idx >= SCROLL_OFFSET + avail )); then
            SCROLL_OFFSET=$((sel_render_idx - avail + 1))
        fi
    fi
    (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0

    # ── Render visible lines ──
    # Pre-scan: find sessions whose active pane matches a P/Q child entry,
    # so the parent S/W entry can suppress ACTIVE in favour of the child.
    local -A _active_pane_in_child=()
    if [[ -n "$cur_pane" ]]; then
        for entry in "${render_lines[@]}"; do
            case "${entry%%|*}" in
                P|Q)
                    local _r="${entry#?|}"
                    local _s="${_r%%|*}"; _r="${_r#*|}"
                    local _p="${_r%%|*}"
                    [[ "$_p" == "$cur_pane" ]] && _active_pane_in_child[$_s]=1
                    ;;
            esac
        done
    fi

    SCREEN_SEL=()

    local viewport_end=$((H - 2))
    for ((i=SCROLL_OFFSET; i<total_render && line<viewport_end; i++)); do
        local rtype="${render_types[$i]}"
        local sidx="${render_sel_indices[$i]}"

        if [[ "$rtype" == "B" ]]; then
            buf+="\033[K\n"; ((line++)); continue
        fi
        if [[ "$rtype" == "G" ]]; then
            buf+="${render_lines[$i]}\033[K\n"; ((line++)); continue
        fi

        # Map this screen row (1-based) to selectable index for mouse clicks.
        SCREEN_SEL[$((line + 1))]=$sidx

        local entry="${render_lines[$i]}"
        local is_sel=0 is_cur=0
        (( sidx >= 0 && sidx == SELECTED )) && is_sel=1

        # Inline icon/color lookup (no subshells)
        _set_icon_color() {
            case "$1" in
                working) _ic="$YEL"; _icon="${SPINNER_FRAMES[$SPINNER_TICK]}" ;;
                done)    _ic="$GRN"; _icon="✓" ;;
                wait)    _ic="$CYN"; _icon="⏸" ;;
                parked)  _ic="$GRY"; _icon="P" ;;
                *)       _ic="$GRY"; _icon="·" ;;
            esac
        }

        # Build compact multi-status string from pane counts "w:d:wt"
        _render_counts() {
            IFS=: read -r _cw _cd _cwt <<< "$1"
            _count_str="" ; _count_vlen=0
            if (( _cw > 0 )); then
                _count_str+="${YEL}${SPINNER_FRAMES[$SPINNER_TICK]}${_cw}${RST}"
                ((_count_vlen += ${#_cw} + 1))
            fi
            if (( _cd > 0 )); then
                (( _count_vlen > 0 )) && { _count_str+=" "; ((_count_vlen++)); }
                _count_str+="${GRN}✓${_cd}${RST}"
                ((_count_vlen += ${#_cd} + 1))
            fi
            if (( _cwt > 0 )); then
                (( _count_vlen > 0 )) && { _count_str+=" "; ((_count_vlen++)); }
                _count_str+="${CYN}⏸${_cwt}${RST}"
                ((_count_vlen += ${#_cwt} + 1))
            fi
        }

        if [[ "$rtype" == "S" ]]; then
            local rest="${entry#S|}"
            local name="${rest%%|*}"; rest="${rest#*|}"
            local state="${rest%%|*}"; rest="${rest#*|}"
            local extra="${rest%%|*}"; rest="${rest#*|}"
            local ssh="$rest"
            [[ "$name" == "$cur_session" && -z "${_active_pane_in_child[$name]:-}" ]] && is_cur=1

            # Build status indicator: compact counts or single icon
            local icon_str icon_vlen
            local counts="${PANE_COUNTS[$name]:-}"
            if [[ -n "$counts" ]]; then
                _render_counts "$counts"
                icon_str="$_count_str"; icon_vlen=$_count_vlen
            else
                local _icon _ic; _set_icon_color "$state"
                icon_str="${_ic}${_icon}${RST}"; icon_vlen=1
            fi

            local max_n=$((LW - 5 - icon_vlen))
            (( max_n < 4 )) && max_n=4
            local dname="$name"
            (( ${#dname} > max_n )) && dname="${dname:0:$((max_n-1))}…"

            local suffix=""
            [[ -n "$extra" ]] && suffix=" (${extra})"
            [[ -n "$ssh" ]] && suffix+=" [ssh]"
            local active_tag=""
            (( is_cur )) && active_tag=" ${DIM}ACTIVE${RST}"
            local tag_vlen=0
            (( is_cur )) && tag_vlen=7

            local vlen=$(( ${#dname} + ${#suffix} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 4 - icon_vlen))
                (( pad < 0 )) && pad=0
                buf+="${SEL_BG} ${BOLD}▸ ${RST}${SEL_BG}${dname}${suffix}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 4 - icon_vlen))
                (( pad < 0 )) && pad=0
                buf+="${CUR_BG} ${ACC_GRN}▌${RST}${CUR_BG} ${dname}${suffix}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            else
                pad=$((LW - vlen - 3 - icon_vlen))
                (( pad < 0 )) && pad=0
                buf+="  ${dname}${suffix}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            fi

        elif [[ "$rtype" == "W" ]]; then
            local rest="${entry#W|}"
            local name="${rest%%|*}"; rest="${rest#*|}"
            local state="${rest%%|*}"; rest="${rest#*|}"
            local extra="${rest%%|*}"; rest="${rest#*|}"
            local ssh="${rest%%|*}"; rest="${rest#*|}"
            local is_last="$rest"
            [[ "$name" == "$cur_session" && -z "${_active_pane_in_child[$name]:-}" ]] && is_cur=1

            # Build status indicator: compact counts or single icon
            local icon_str icon_vlen
            local counts="${PANE_COUNTS[$name]:-}"
            if [[ -n "$counts" ]]; then
                _render_counts "$counts"
                icon_str="$_count_str"; icon_vlen=$_count_vlen
            else
                local _icon _ic; _set_icon_color "$state"
                icon_str="${_ic}${_icon}${RST}"; icon_vlen=1
            fi

            local tree="├"; [[ "$is_last" == "1" ]] && tree="└"
            local max_n=$((LW - 9 - icon_vlen))
            (( max_n < 4 )) && max_n=4
            local dname="$name"
            (( ${#dname} > max_n )) && dname="${dname:0:$((max_n-1))}…"

            local suffix=""
            [[ -n "$extra" ]] && suffix=" (${extra})"
            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }

            local vlen=$(( ${#dname} + ${#suffix} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 8 - icon_vlen))
                (( pad < 0 )) && pad=0
                buf+="${SEL_BG}   ${BOLD}▸${RST}${SEL_BG} ${DIM}${tree}${RST}${SEL_BG} ${dname}${suffix}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 8 - icon_vlen))
                (( pad < 0 )) && pad=0
                buf+="${CUR_BG}   ${ACC_GRN}▌${RST}${CUR_BG} ${DIM}${tree}${RST}${CUR_BG} ${dname}${suffix}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            else
                pad=$((LW - vlen - 7 - icon_vlen))
                (( pad < 0 )) && pad=0
                buf+="    ${DIM}${tree}${RST} ${dname}${suffix}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            fi

        elif [[ "$rtype" == "I" ]]; then
            # Inbox item: I|session|pane_id|label|status
            local rest="${entry#I|}"
            local sess="${rest%%|*}"; rest="${rest#*|}"
            local pane_id="${rest%%|*}"; rest="${rest#*|}"
            local label="${rest%%|*}"; rest="${rest#*|}"
            local istatus="$rest"
            if [[ -n "$pane_id" ]]; then
                [[ "$sess" == "$cur_session" && "$pane_id" == "$cur_pane" ]] && is_cur=1
            else
                [[ "$sess" == "$cur_session" ]] && is_cur=1
            fi
            # Mirror selection from SESSIONS section (match specific pane, not whole session)
            local sel_name="${SEL_NAMES[$SELECTED]:-}"
            local sel_type="${SEL_TYPES[$SELECTED]:-}"
            if [[ "$sel_type" == "P" ]]; then
                # Selected a specific pane — only highlight matching pane inbox entry
                local sel_sess="${sel_name%%:*}" sel_pane="${sel_name#*:}"
                if [[ -n "$pane_id" ]]; then
                    [[ "$sess" == "$sel_sess" && "$pane_id" == "$sel_pane" ]] && is_sel=1
                else
                    [[ "$sess" == "$sel_sess" ]] && is_sel=1
                fi
            else
                # Selected a session — highlight session-level inbox entry only
                [[ -z "$pane_id" && "$sess" == "$sel_name" ]] && is_sel=1
            fi

            local _icon _ic; _set_icon_color "$istatus"
            local max_n=$((LW - 6))
            (( max_n < 4 )) && max_n=4
            local dlabel="$label"
            (( ${#dlabel} > max_n )) && dlabel="${dlabel:0:$((max_n-1))}…"

            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }

            local vlen=$(( ${#dlabel} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 5))
                (( pad < 0 )) && pad=0
                buf+="${SEL_BG} ${BOLD}▸ ${RST}${SEL_BG}${dlabel}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 5))
                (( pad < 0 )) && pad=0
                buf+="${CUR_BG} ${ACC_GRN}▌${RST}${CUR_BG} ${dlabel}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            else
                pad=$((LW - vlen - 4))
                (( pad < 0 )) && pad=0
                buf+="  ${dlabel}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            fi

        elif [[ "$rtype" == "P" ]]; then
            local rest="${entry#P|}"
            local sess="${rest%%|*}"; rest="${rest#*|}"
            local pane_id="${rest%%|*}"; rest="${rest#*|}"
            local agent="${rest%%|*}"; rest="${rest#*|}"
            local pstatus="${rest%%|*}"; rest="${rest#*|}"
            local is_last="$rest"
            [[ "$sess" == "$cur_session" && "$pane_id" == "$cur_pane" ]] && is_cur=1

            local _icon _ic; _set_icon_color "$pstatus"
            local tree="├"; [[ "$is_last" == "1" ]] && tree="└"
            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }
            local vlen=$(( ${#agent} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 8))
                (( pad < 0 )) && pad=0
                buf+="${SEL_BG}  ${BOLD}▸${RST}${SEL_BG} ${DIM}${tree}${RST}${SEL_BG} ${DIM}${agent}${RST}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 8))
                (( pad < 0 )) && pad=0
                buf+="${CUR_BG}  ${ACC_GRN}▌${RST}${CUR_BG} ${DIM}${tree}${RST}${CUR_BG} ${DIM}${agent}${RST}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            else
                pad=$((LW - ${#agent} - 8))
                (( pad < 0 )) && pad=0
                buf+="    ${DIM}${tree} ${agent}${RST}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            fi

        elif [[ "$rtype" == "Q" ]]; then
            local rest="${entry#Q|}"
            local sess="${rest%%|*}"; rest="${rest#*|}"
            local pane_id="${rest%%|*}"; rest="${rest#*|}"
            local agent="${rest%%|*}"; rest="${rest#*|}"
            local pstatus="${rest%%|*}"; rest="${rest#*|}"
            local is_last="${rest%%|*}"; rest="${rest#*|}"
            local parent_is_last="$rest"
            [[ "$sess" == "$cur_session" && "$pane_id" == "$cur_pane" ]] && is_cur=1

            local _icon _ic; _set_icon_color "$pstatus"
            local tree="├"; [[ "$is_last" == "1" ]] && tree="└"
            local vert="│"; [[ "$parent_is_last" == "1" ]] && vert=" "
            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }
            local vlen=$(( ${#agent} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 10))
                (( pad < 0 )) && pad=0
                buf+="${SEL_BG}  ${BOLD}▸${RST}${SEL_BG} ${DIM}${vert} ${tree}${RST}${SEL_BG} ${DIM}${agent}${RST}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 10))
                (( pad < 0 )) && pad=0
                buf+="${CUR_BG}  ${ACC_GRN}▌${RST}${CUR_BG} ${DIM}${vert} ${tree}${RST}${CUR_BG} ${DIM}${agent}${RST}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            else
                pad=$((LW - ${#agent} - 10))
                (( pad < 0 )) && pad=0
                buf+="    ${DIM}${vert} ${tree} ${agent}${RST}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            fi
        fi

        ((line++))
    done

    # Fill remaining space
    while (( line < viewport_end )); do
        buf+="\033[K\n"
        ((line++))
    done

    # ── Footer ──
    buf+="$sep"
    if (( WAIT_INPUT_ACTIVE )); then
        buf+=" ${BCYN}Wait minutes for ${WAIT_INPUT_TARGET}: ${RST}${WAIT_INPUT_BUF}\033[K"
    elif (( SEARCH_ACTIVE )); then
        buf+=" ${DIM}type to filter  ⏎ select  esc cancel${RST}\033[K"
    else
        buf+=" ${DIM}⏎ select  / search  w wait  p park  q quit${RST}\033[K"
    fi

    # Flush entire frame at once (no flicker)
    printf '\033[H%b' "$buf"

    # ── Preview panel (popup mode only) ──
    if (( PREVIEW_MODE && SEL_COUNT > 0 )); then
        local sel_session="${SEL_NAMES[$SELECTED]}"
        local sel_type="${SEL_TYPES[$SELECTED]}"
        [[ "$sel_type" == "P" ]] && sel_session="${sel_session%%:*}"

        # Only re-capture pane content when selection or data changed
        local sel_key="${sel_session}:${sel_type}"
        if [[ "$sel_key" != "$_PREVIEW_SEL" ]] || (( _PREVIEW_DIRTY )); then
            _PREVIEW_SEL="$sel_key"
            _PREVIEW_DIRTY=0
            _PREVIEW_LINES=()

            local pane_target="$sel_session"
            if [[ "$sel_type" == "P" ]]; then
                local pane_id="${SEL_NAMES[$SELECTED]#*:}"
                pane_target="$pane_id"
            fi

            while IFS= read -r pline; do
                _PREVIEW_LINES+=("$pline")
            done < <(tmux capture-pane -peJ -t "$pane_target" 2>/dev/null | tail -$((H - 4)))
        fi

        # Separator + preview title
        local pbuf=""
        local row
        for ((row=1; row<=H; row++)); do
            pbuf+="\033[${row};$((LW+1))H${DIM}│${RST}"
        done
        pbuf+="\033[1;${preview_col}H ${BOLD}${sel_session}${RST}\033[K"

        # Separator line under preview title
        pbuf+="\033[2;${preview_col}H${DIM}"
        for ((i=0; i<preview_width; i++)); do pbuf+="─"; done
        pbuf+="${RST}"

        # Render cached preview lines
        local prow=3
        local pi=0
        for ((pi=0; pi<${#_PREVIEW_LINES[@]} && prow<H-1; pi++)); do
            local ptext="${_PREVIEW_LINES[$pi]}"
            if (( ${#ptext} > preview_width )); then
                ptext="${ptext:0:$preview_width}"
            fi
            pbuf+="\033[${prow};${preview_col}H${ptext}\033[K"
            ((prow++))
        done
        for (( ; prow<H-1; prow++ )); do
            pbuf+="\033[${prow};${preview_col}H\033[K"
        done

        printf '%b' "$pbuf"
    fi

    # Advance spinner
    SPINNER_TICK=$(( (SPINNER_TICK + 1) % ${#SPINNER_FRAMES[@]} ))
}

# ─── Actions ──────────────────────────────────────────────────────
action_switch() {
    (( SEL_COUNT == 0 )) && return
    local target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    [[ -z "$target" ]] && return

    if [[ "$ttype" == "P" ]]; then
        local sess="${target%%:*}"
        local pane_id="${target#*:}"
        if [[ "$pane_id" == w* ]]; then
            # Window entry — switch to session and select window
            local win_idx="${pane_id#w}"
            tmux switch-client -t "$sess" 2>/dev/null
            tmux select-window -t "$sess:$win_idx" 2>/dev/null
        else
            # Pane entry — switch to session, window, and pane
            local win
            win=$(tmux display-message -t "$pane_id" -p '#{window_index}' 2>/dev/null)
            tmux switch-client -t "$sess" 2>/dev/null
            [ -n "$win" ] && tmux select-window -t "$sess:$win" 2>/dev/null
            tmux select-pane -t "$pane_id" 2>/dev/null
        fi
    else
        tmux switch-client -t "$target" 2>/dev/null
    fi

    if (( PREVIEW_MODE )); then
        # Popup mode: close on select.
        exit 0
    fi
    # Sidebar mode: keep running. The new session has its own sidebar.
    NEEDS_COLLECT=1
}

# Get the session name for the currently selected item (works for S, W, and P).
_selected_session() {
    local target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    if [[ "$ttype" == "P" ]]; then
        echo "${target%%:*}"
    else
        echo "$target"
    fi
}

# Get the state of the selected entry by scanning ENTRIES.
_selected_state() {
    local sidx=0
    for e in "${ENTRIES[@]}"; do
        case "${e%%|*}" in
            S|W)
                if (( sidx == SELECTED )); then
                    local rest="${e#?|}" ; rest="${rest#*|}"
                    echo "${rest%%|*}"
                    return
                fi
                ((sidx++))
                ;;
            P|Q)
                if (( sidx == SELECTED )); then
                    # Return the actual pane/window status, not a generic tag
                    local rest="${e#?|}" ; rest="${rest#*|}"
                    rest="${rest#*|}" ; rest="${rest#*|}"
                    echo "${rest%%|*}"
                    return
                fi
                ((sidx++))
                ;;
            I)
                if (( sidx == SELECTED )); then
                    # Inbox items resolve to their parent session's state
                    local rest="${e#I|}"
                    local sname="${rest%%|*}"
                    echo "$(get_agent_status "$sname")"
                    return
                fi
                ((sidx++))
                ;;
            *) ;;
        esac
    done
}

action_wait() {
    (( SEL_COUNT == 0 )) && return
    local raw_target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    local state
    state=$(_selected_state)
    [[ "$state" == "noagent" ]] && return

    # Toggle: if already waiting, cancel wait
    if [[ "$state" == "wait" ]]; then
        if [[ "$ttype" == "P" ]]; then
            local session="${raw_target%%:*}"
            local pane_id="${raw_target#*:}"

            if [[ "$pane_id" == w* ]]; then
                # Window-level cancel
                local win_idx="${pane_id#w}"
                while IFS= read -r wp_id; do
                    [ -z "$wp_id" ] && continue
                    rm -f "$WAIT_DIR/${session}_${wp_id}.wait"
                    local pf="$STATUS_DIR/panes/${session}_${wp_id}.status"
                    [ -f "$pf" ] && [ "$(cat "$pf")" = "wait" ] && echo "done" > "$pf"
                done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_id}' 2>/dev/null)
            else
                # Pane-level cancel
                rm -f "$WAIT_DIR/${session}_${pane_id}.wait"
                echo "done" > "$STATUS_DIR/panes/${session}_${pane_id}.status" 2>/dev/null
            fi
            # Clear session-level wait if no pane waits remain
            local has_remaining=0
            for remaining in "$WAIT_DIR/${session}_"*.wait; do
                [ -f "$remaining" ] && { has_remaining=1; break; }
            done
            if [ "$has_remaining" -eq 0 ]; then
                rm -f "$WAIT_DIR/${session}.wait"
                echo "done" > "$STATUS_DIR/${session}.status" 2>/dev/null
            fi
        else
            # Session-level cancel
            local session="$raw_target"
            rm -f "$WAIT_DIR/${session}.wait"
            rm -f "$WAIT_DIR/${session}_"*.wait 2>/dev/null
            if [ -f "$STATUS_DIR/${session}-remote.status" ]; then
                echo "done" > "$STATUS_DIR/${session}-remote.status"
            else
                echo "done" > "$STATUS_DIR/${session}.status"
            fi
            for pf in "$STATUS_DIR/panes/${session}_"*.status; do
                [ -f "$pf" ] && [ "$(cat "$pf")" = "wait" ] && echo "done" > "$pf"
            done
        fi
        _LAST_STATUS_MTIME=""
        return
    fi

    # Inline prompt: read minutes directly in the sidebar.
    # Pass the full target (session or session:pane_id) so the handler
    # knows whether to wait at session or pane level.
    WAIT_INPUT_ACTIVE=1
    if [[ "$ttype" == "P" ]]; then
        WAIT_INPUT_TARGET="$raw_target"
    else
        WAIT_INPUT_TARGET="$(_selected_session)"
    fi
    WAIT_INPUT_BUF=""
}

action_park() {
    (( SEL_COUNT == 0 )) && return
    local target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    local state
    state=$(_selected_state)
    [[ "$state" == "noagent" ]] && return

    local session_name
    if [[ "$ttype" == "P" ]]; then
        session_name="${target%%:*}"
        local pane_id="${target#*:}"

        if [[ "$pane_id" == w* ]]; then
            # Window-level park: park/unpark all panes in this window
            local win_idx="${pane_id#w}"
            if [[ "$state" == "parked" ]]; then
                while IFS= read -r wp_id; do
                    [ -z "$wp_id" ] && continue
                    rm -f "$PARKED_DIR/${session_name}_${wp_id}.parked"
                    local pf="$STATUS_DIR/panes/${session_name}_${wp_id}.status"
                    [ -f "$pf" ] && [ "$(cat "$pf")" = "parked" ] && echo "done" > "$pf"
                done < <(tmux list-panes -t "${session_name}:${win_idx}" -F '#{pane_id}' 2>/dev/null)
                rm -f "$PARKED_DIR/${session_name}.parked"
            else
                mkdir -p "$PARKED_DIR"
                while IFS= read -r wp_id; do
                    [ -z "$wp_id" ] && continue
                    : > "$PARKED_DIR/${session_name}_${wp_id}.parked"
                    echo "parked" > "$STATUS_DIR/panes/${session_name}_${wp_id}.status"
                    rm -f "$WAIT_DIR/${session_name}_${wp_id}.wait" 2>/dev/null
                done < <(tmux list-panes -t "${session_name}:${win_idx}" -F '#{pane_id}' 2>/dev/null)
            fi
        elif [[ "$state" == "parked" ]]; then
            # Unpark this pane
            rm -f "$PARKED_DIR/${session_name}_${pane_id}.parked"
            local pf="$STATUS_DIR/panes/${session_name}_${pane_id}.status"
            [ -f "$pf" ] && echo "done" > "$pf"
            # If session was fully parked, remove session marker too
            rm -f "$PARKED_DIR/${session_name}.parked"
        else
            # Park this pane
            mkdir -p "$PARKED_DIR"
            rm -f "$WAIT_DIR/${session_name}_${pane_id}.wait" 2>/dev/null
            : > "$PARKED_DIR/${session_name}_${pane_id}.parked"
            local pf="$STATUS_DIR/panes/${session_name}_${pane_id}.status"
            [ -f "$pf" ] && echo "parked" > "$pf"
        fi
    else
        # Session-level park/unpark
        session_name="$target"
        if [[ "$state" == "parked" ]]; then
            rm -f "$PARKED_DIR/${session_name}.parked"
            rm -f "$PARKED_DIR/${session_name}_"*.parked 2>/dev/null
            if [ -f "$STATUS_DIR/${session_name}-remote.status" ]; then
                echo "done" > "$STATUS_DIR/${session_name}-remote.status"
            else
                echo "done" > "$STATUS_DIR/${session_name}.status"
            fi
            for pf in "$STATUS_DIR/panes/${session_name}_"*.status; do
                [ -f "$pf" ] && [ "$(cat "$pf")" = "parked" ] && echo "done" > "$pf"
            done
        else
            mkdir -p "$PARKED_DIR"
            rm -f "$WAIT_DIR/${session_name}.wait"
            : > "$PARKED_DIR/${session_name}.parked"
            if [ -f "$STATUS_DIR/${session_name}-remote.status" ]; then
                echo "parked" > "$STATUS_DIR/${session_name}-remote.status"
            else
                echo "parked" > "$STATUS_DIR/${session_name}.status"
            fi
            # Park all panes
            for pf in "$STATUS_DIR/panes/${session_name}_"*.status; do
                [ -f "$pf" ] || continue
                local pid
                pid=$(basename "$pf" .status)
                pid="${pid#${session_name}_}"
                : > "$PARKED_DIR/${session_name}_${pid}.parked"
                echo "parked" > "$pf"
                rm -f "$WAIT_DIR/${session_name}_${pid}.wait" 2>/dev/null
            done
        fi
    fi
    _LAST_STATUS_MTIME=""
}

# ─── Main loop ────────────────────────────────────────────────────
NEEDS_COLLECT=1
_idle_ticks=0
while true; do
    # Exit if our pane/TTY is gone (prevents orphaned processes).
    [[ ! -t 0 ]] && exit 0

    if (( NEEDS_COLLECT )); then
        collect
        _PREVIEW_DIRTY=1
    fi
    NEEDS_COLLECT=0
    render

    if read -rsn1 -t 0.08 key; then
        # Handle escape sequences (arrows, mouse) shared by both modes.
        _handle_escape() {
            read -rsn2 -t 0.1 seq
            case "$seq" in
                '[A') (( SELECTED > SESS_START )) && ((SELECTED--)); return 0 ;;
                '[B') (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++)); return 0 ;;
                '[<')
                    # SGR mouse: read "button;x;yM" or "button;x;ym"
                    local mdata="" mc=""
                    while read -rsn1 -t 0.1 mc; do
                        [[ "$mc" == "M" || "$mc" == "m" ]] && break
                        mdata+="$mc"
                    done
                    if [[ "$mc" == "M" ]]; then  # press only
                        local mb mx my
                        IFS=';' read -r mb mx my <<< "$mdata"
                        if (( mb == 64 )); then
                            # Scroll up
                            (( SELECTED > SESS_START )) && ((SELECTED--))
                        elif (( mb == 65 )); then
                            # Scroll down
                            (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++))
                        elif (( mb == 0 )); then
                            # Left click — select + switch
                            local clicked="${SCREEN_SEL[$my]:-}"
                            if [[ -n "$clicked" ]] && (( clicked >= 0 && clicked < SEL_COUNT )); then
                                SELECTED=$clicked
                                action_switch
                            fi
                        fi
                    fi
                    return 0
                    ;;
            esac
            return 1  # unhandled
        }

        if (( WAIT_INPUT_ACTIVE )); then
            # Wait-input mode: accept digits, Enter to confirm, Esc to cancel
            case "$key" in
                $'\x1b')
                    WAIT_INPUT_ACTIVE=0; WAIT_INPUT_BUF="" ;;
                $'\x7f'|$'\b')
                    WAIT_INPUT_BUF="${WAIT_INPUT_BUF%?}"
                    [[ -z "$WAIT_INPUT_BUF" ]] && { WAIT_INPUT_ACTIVE=0; WAIT_INPUT_BUF=""; } ;;
                '')  # Enter — confirm
                    if [[ -n "$WAIT_INPUT_BUF" ]] && [[ "$WAIT_INPUT_BUF" =~ ^[0-9]+$ ]] && (( WAIT_INPUT_BUF > 0 )); then
                        bash "$CURRENT_DIR/wait-session-handler.sh" "$WAIT_INPUT_TARGET" "$WAIT_INPUT_BUF"
                        NEEDS_COLLECT=1
                        _LAST_STATUS_MTIME=""
                    fi
                    WAIT_INPUT_ACTIVE=0; WAIT_INPUT_BUF="" ;;
                [0-9])
                    WAIT_INPUT_BUF+="$key" ;;
            esac
        elif (( SEARCH_ACTIVE )); then
            # Search mode input handling
            case "$key" in
                $'\x1b')
                    if ! _handle_escape; then
                        # Plain Escape — cancel search
                        SEARCH_QUERY=""
                        SEARCH_ACTIVE=0
                        SELECTED=0
                    fi
                    ;;
                $'\x7f'|$'\b')  # Backspace
                    if [[ -n "$SEARCH_QUERY" ]]; then
                        SEARCH_QUERY="${SEARCH_QUERY%?}"
                        SELECTED=0
                    else
                        SEARCH_ACTIVE=0
                    fi
                    ;;
                '')  # Enter — select current match and exit search
                    SEARCH_ACTIVE=0
                    action_switch
                    ;;
                j|k)
                    # Allow navigation even in search mode via ctrl sequences
                    [[ "$key" == "j" ]] && (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++))
                    [[ "$key" == "k" ]] && (( SELECTED > SESS_START )) && ((SELECTED--))
                    ;;
                [[:print:]])
                    SEARCH_QUERY+="$key"
                    SELECTED=0
                    ;;
            esac
        else
            # Normal mode input handling
            case "$key" in
                j)  (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++)) ;;
                k)  (( SELECTED > SESS_START )) && ((SELECTED--)) ;;
                $'\x1b')
                    if ! _handle_escape; then
                        exit 0
                    fi
                    ;;
                '')  action_switch ;;
                w)   action_wait; NEEDS_COLLECT=1 ;;
                p)   action_park; NEEDS_COLLECT=1 ;;
                r)   "$CURRENT_DIR/hook-based-switcher.sh" --reset >/dev/null 2>&1
                     KNOWN_AGENTS=()
                     NEEDS_COLLECT=1
                     ;;
                /)   SEARCH_ACTIVE=1; SEARCH_QUERY="" ;;
                q)   exit 0 ;;
            esac
        fi
    else
        # Timeout (no keypress) — refresh data every ~1s (12 ticks × 0.08s)
        (( ++_idle_ticks >= 12 )) && { NEEDS_COLLECT=1; _idle_ticks=0; }
    fi
done
