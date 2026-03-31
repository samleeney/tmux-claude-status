#!/usr/bin/env bash

# Sidebar data collector daemon.
# Runs once per tmux server. Collects session/pane/agent state and writes
# a cache file that all sidebar renderer panes read from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
LOCK_FILE="$STATUS_DIR/.sidebar-collector.lock"
PID_FILE="$STATUS_DIR/.sidebar-collector.pid"

# Ensure only one collector runs
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0  # already running
    fi
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE" "$LOCK_FILE"' EXIT

# ─── State priority ──────────────────────────────────────────────
_state_pri() {
    case "$1" in
        working) echo 4 ;; done) echo 3 ;; ask) echo 3 ;;
        wait)    echo 2 ;; parked)  echo 1 ;; *)       echo 0 ;;
    esac
}

# ─── Main collection loop ────────────────────────────────────────
_last_mtime=""
_tick=0

while true; do
    # Exit if tmux server is gone
    tmux list-sessions >/dev/null 2>&1 || exit 0

    # Change detection: skip if nothing changed (check every ~10 ticks = 10s)
    (( ++_tick >= 10 )) && { _tick=0; _last_mtime=""; }
    cur_mtime=$(stat -c %Y "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR" 2>/dev/null)
    if [[ "$cur_mtime" == "$_last_mtime" ]]; then
        sleep 1
        continue
    fi
    _last_mtime="$cur_mtime"

    # ── Collect all data (mirrors sidebar.sh collect()) ──────────

    local_tab=$'\t'
    declare -A sess_state=() sess_extra=() sess_ssh=() sess_seen=()
    declare -A sess_agents=() pane_to_window=() window_names=()
    declare -A worktree_parent=() worktree_children=()
    declare -A repo_root_session=()
    declare -A PANE_COUNTS=()
    local all_pane_pids=""

    now=$(date +%s)

    # 1+2. Session + pane data
    while IFS="$local_tab" read -r sname pane_id cwd ppid win_idx win_name; do
        [ -z "$sname" ] && continue
        pane_to_window[$pane_id]="$win_idx"
        window_names["${sname}:${win_idx}"]="$win_name"
        all_pane_pids+="$ppid "

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
        rm -f "$STATUS_DIR/${sname}.unread" "$STATUS_DIR/${sname}-remote.unread" 2>/dev/null

        sess_state[$sname]="$state"
        sess_extra[$sname]="$extra"
        sess_ssh[$sname]="$is_ssh"

        # Worktree detection
        if [[ "$cwd" != */.claude/worktrees/* ]]; then
            repo_root_session["$cwd"]="$sname"
        fi
    done < <(tmux list-panes -a -F "#{session_name}${local_tab}#{pane_id}${local_tab}#{pane_current_path}${local_tab}#{pane_pid}${local_tab}#{window_index}${local_tab}#{window_name}" 2>/dev/null)

    # Worktree parent detection (second pass)
    for sname in "${!sess_state[@]}"; do
        # Get cwd for this session
        local cwd
        cwd=$(tmux display-message -t "$sname" -p '#{pane_current_path}' 2>/dev/null) || continue
        if [[ "$cwd" == */.claude/worktrees/* ]]; then
            local repo_root="${cwd%%/.claude/worktrees/*}"
            local parent="${repo_root_session[$repo_root]:-}"
            if [ -n "$parent" ] && [ "$parent" != "$sname" ]; then
                worktree_parent[$sname]="$parent"
                worktree_children[$parent]+="$sname "
            fi
        fi
    done

    # Collapse single-worktree parents
    for parent in "${!worktree_children[@]}"; do
        local children=(${worktree_children[$parent]})
        if (( ${#children[@]} <= 1 )); then
            for child in "${children[@]}"; do
                unset "worktree_parent[$child]"
            done
            unset "worktree_children[$parent]"
        fi
    done

    # 3. Agent process detection (PID map already built by agent-processes.sh)
    _build_agent_pid_map
    for sname in "${!sess_state[@]}"; do
        while IFS="$local_tab" read -r pane_id ppid win_idx; do
            [ -z "$pane_id" ] && continue
            local agent_pid=""
            agent_pid=$(find_matching_descendant_pid "$ppid" "claude|codex" 2>/dev/null) || true
            if [ -n "$agent_pid" ]; then
                local agent_name="${_AP_ARGS[$agent_pid]:-agent}"
                agent_name="${agent_name##*/}"
                agent_name="${agent_name%% *}"
                # Per-pane status
                local pane_status=""
                local psf="$STATUS_DIR/panes/${sname}_${pane_id}.status"
                if [ -f "$psf" ]; then
                    pane_status=$(<"$psf")
                else
                    pane_status="${sess_state[$sname]:-done}"
                    echo "$pane_status" > "$psf"
                fi
                # Check per-pane parked/wait
                [ -f "$PARKED_DIR/${sname}_${pane_id}.parked" ] && pane_status="parked"
                local pwf="$WAIT_DIR/${sname}_${pane_id}.wait"
                if [ -f "$pwf" ]; then
                    local exp=$(<"$pwf")
                    if [ -n "$exp" ] && (( exp > now )); then
                        pane_status="wait"
                    fi
                fi
                sess_agents[$sname]+="${pane_id}:${agent_name}:${pane_status} "
            fi
        done < <(tmux list-panes -t "$sname" -F "#{pane_id}${local_tab}#{pane_pid}${local_tab}#{window_index}" 2>/dev/null)
    done

    # 4. Recompute session states from per-pane agent data
    for sname in "${!sess_agents[@]}"; do
        local agents="${sess_agents[$sname]}"
        local nw=0 nd=0 nwt=0 np=0 best_pri=-1 best_st="noagent"
        for ap in $agents; do
            local st="${ap#*:}"; st="${st#*:}"
            case "$st" in
                working) ((nw++)) ;; done|ask) ((nd++)) ;; wait) ((nwt++)) ;; parked) ((np++)) ;;
            esac
            local pri; pri=$(_state_pri "$st")
            (( pri > best_pri )) && { best_pri=$pri; best_st="$st"; }
        done
        (( nw + nd + nwt > 0 )) && PANE_COUNTS[$sname]="${nw}:${nd}:${nwt}"
        [ "$best_st" != "noagent" ] && sess_state[$sname]="$best_st"
    done

    # Effective state (bubble children up)
    declare -A eff_state=()
    for sname in "${!sess_state[@]}"; do
        eff_state[$sname]="${sess_state[$sname]}"
    done
    for parent in "${!worktree_children[@]}"; do
        local best="${eff_state[$parent]}"
        local best_pri; best_pri=$(_state_pri "$best")
        for child in ${worktree_children[$parent]}; do
            local cp; cp=$(_state_pri "${sess_state[$child]}")
            if (( cp > best_pri )); then
                best_pri=$cp
                best="${sess_state[$child]}"
            fi
        done
        eff_state[$parent]="$best"
    done

    # ── 5. Build ENTRIES ──────────────────────────────────────────

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

    ENTRIES=()
    SEL_NAMES=()
    SEL_TYPES=()
    SESS_START=0

    # INBOX
    local inbox=()
    for sname in "${!sess_agents[@]}"; do
        [[ -f "$PARKED_DIR/${sname}.parked" ]] && continue
        _get_agent_arr "$sname"
        local arr=("${_agent_result[@]}")
        if (( ${#arr[@]} <= 1 )); then
            local ap="${arr[0]:-}"
            local pst="${ap#*:}"; pst="${pst#*:}"
            [[ "$pst" == "done" || "$pst" == "ask" ]] && inbox+=("I|${sname}||${sname}|done")
            continue
        fi
        for ap in "${arr[@]}"; do
            local pid="${ap%%:*}" r="${ap#*:}"
            local aname="${r%%:*}" pst="${r#*:}"
            [[ "$pst" == "done" || "$pst" == "ask" ]] && inbox+=("I|${sname}|${pid}|${sname}/${aname}|done")
        done
    done
    # Single-agent sessions not in sess_agents
    for sname in "${!sess_state[@]}"; do
        [[ -n "${sess_agents[$sname]:-}" ]] && continue
        [[ -f "$PARKED_DIR/${sname}.parked" ]] && continue
        [[ -n "${worktree_parent[$sname]:-}" ]] && continue
        local st="${eff_state[$sname]}"
        [[ "$st" == "done" || "$st" == "ask" ]] && inbox+=("I|${sname}||${sname}|done")
    done

    if (( ${#inbox[@]} > 0 )); then
        IFS=$'\n' inbox=($(sort -t'|' -k4 <<< "${inbox[*]}")); unset IFS
        ENTRIES+=("G|INBOX|green")
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

    # SESSIONS
    local sorted_sessions=()
    for sname in "${!sess_state[@]}"; do
        [[ -n "${worktree_parent[$sname]:-}" ]] && continue
        sorted_sessions+=("$sname")
    done
    IFS=$'\n' sorted_sessions=($(sort <<< "${sorted_sessions[*]}")); unset IFS

    SESS_START=${#SEL_NAMES[@]}
    if (( ${#sorted_sessions[@]} > 0 )); then
        ENTRIES+=("G|SESSIONS|gray")
        for sname in "${sorted_sessions[@]}"; do
            local st="${eff_state[$sname]}"
            local ex="${sess_extra[$sname]}"
            local ss="${sess_ssh[$sname]}"
            ENTRIES+=("S|${sname}|${st}|${ex}|${ss}")
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

                # Agent panes under worktree child
                _get_agent_arr "$wt"
                local agents=("${_agent_result[@]}")
                if (( ${#agents[@]} > 1 )); then
                    local ai=0
                    for ap in "${agents[@]}"; do
                        ((ai++))
                        local pid="${ap%%:*}" r="${ap#*:}"
                        local agent="${r%%:*}" ast="${r#*:}"
                        ENTRIES+=("P|${wt}|${pid}|${agent}|${ast}|$((ai==${#agents[@]}))")
                        SEL_NAMES+=("${wt}:${pid}")
                        SEL_TYPES+=("P")
                    done
                fi
            done

            # Agent panes under session
            _get_agent_arr "$sname"
            local agents=("${_agent_result[@]}")
            if (( ${#agents[@]} > 1 )); then
                # Group by window
                local -A _w_agents=() _w_seen=()
                local -a _w_order=()
                for ap in "${agents[@]}"; do
                    local pid="${ap%%:*}"
                    local widx="${pane_to_window[$pid]:-0}"
                    [[ -z "${_w_seen[$widx]:-}" ]] && { _w_order+=("$widx"); _w_seen[$widx]=1; }
                    _w_agents[$widx]+="$ap "
                done
                if (( ${#_w_order[@]} == 1 )); then
                    local ai=0
                    for ap in "${agents[@]}"; do
                        ((ai++))
                        local pid="${ap%%:*}" r="${ap#*:}"
                        local agent="${r%%:*}" ast="${r#*:}"
                        ENTRIES+=("P|${sname}|${pid}|${agent}|${ast}|$((ai==${#agents[@]}))")
                        SEL_NAMES+=("${sname}:${pid}")
                        SEL_TYPES+=("P")
                    done
                else
                    local nw=${#_w_order[@]} _wi=0
                    for widx in "${_w_order[@]}"; do
                        ((_wi++))
                        local wname="${window_names[${sname}:${widx}]:-window-$widx}"
                        local w_last=$((_wi==nw))
                        local pc=0
                        for _ in ${_w_agents[$widx]}; do ((pc++)); done
                        if (( pc == 1 )); then
                            local ap="${_w_agents[$widx]%% *}"
                            local pid="${ap%%:*}" r="${ap#*:}"
                            local ast="${r#*:}"
                            ENTRIES+=("P|${sname}|${pid}|${wname}|${ast}|${w_last}")
                            SEL_NAMES+=("${sname}:${pid}")
                            SEL_TYPES+=("P")
                        else
                            local best_pri=-1 best_st="noagent"
                            for wap in ${_w_agents[$widx]}; do
                                local ws="${wap#*:}"; ws="${ws#*:}"
                                local wp; wp=$(_state_pri "$ws")
                                (( wp > best_pri )) && { best_pri=$wp; best_st="$ws"; }
                            done
                            ENTRIES+=("P|${sname}|w${widx}|${wname}|${best_st}|${w_last}")
                            SEL_NAMES+=("${sname}:w${widx}")
                            SEL_TYPES+=("P")
                            local ai=0
                            for wap in ${_w_agents[$widx]}; do
                                ((ai++))
                                local pid="${wap%%:*}" r="${wap#*:}"
                                local agent="${r%%:*}" ast="${r#*:}"
                                ENTRIES+=("Q|${sname}|${pid}|${agent}|${ast}|$((ai==pc))|${w_last}")
                                SEL_NAMES+=("${sname}:${pid}")
                                SEL_TYPES+=("P")
                            done
                        fi
                    done
                fi
            fi
        done
    fi

    # ── Write cache ───────────────────────────────────────────────
    {
        echo "TS:$(date +%s)"
        echo "SESS_START:$SESS_START"
        for sname in "${!PANE_COUNTS[@]}"; do
            echo "PC:${sname}:${PANE_COUNTS[$sname]}"
        done
        local i
        for ((i=0; i<${#ENTRIES[@]}; i++)); do
            echo "E:${ENTRIES[$i]}"
            echo "N:${SEL_NAMES[$i]:-}"
            echo "T:${SEL_TYPES[$i]:-}"
        done
    } > "${CACHE_FILE}.tmp"
    mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE"

    sleep 1
done
