# shellcheck shell=bash
# Restoring: deciding what each pane should do, saying why, and doing it.
#
# cwterm_* comes from whichever terminal adapter was loaded; the backticks in
# the printf strings are literal, for people reading the output.
# shellcheck disable=SC2154,SC2016
#
# Two paths, both driven by the same evaluation so they can never disagree:
#   inplace  the terminal brought the layout back itself, so each pane is told
#            to resume the session that sat at its position
#   rebuild  the layout is gone, so a new window is built and each new pane is
#            handed its command through the environment

# --- what a pane should do -------------------------------------------------
# Prints "<mode>\t<command>", mode one of run, prefill, none.
pane_command() {   # $1 provider, $2 sessionId, $3 cwd, $4 recorded command, $5 replay policy
    local provider=$1 sid=$2 cwd=$3 cmd=$4 policy=$5 resume
    if [ -n "$provider" ]; then
        # An agent with no recoverable conversation id still has a "carry on
        # where this directory left off" command; provider_resume_command
        # falls back to it when the id is missing or not one it recognises.
        resume=$(provider_resume_command "$provider" "$sid" "$cwd" 2>/dev/null)
        [ -n "$resume" ] && { printf 'run\t%s' "$resume"; return 0; }
    fi
    [ -n "$cmd" ] || { printf 'none\t'; return 0; }
    case $policy in
        off) printf 'none\t' ;;
        all) printf 'run\t%s' "$cmd" ;;
        auto)
            if printf '%s' "$cmd" | grep -Eq "$CW_REPLAY_ALLOW"; then
                printf 'run\t%s' "$cmd"
            else
                printf 'prefill\t%s' "$cmd"
            fi ;;
        *) printf 'prefill\t%s' "$cmd" ;;
    esac
}

# Every pane of a snapshot with the command it should get.
# TSV: wi ti si cwd provider sid name mode command
snapshot_panes() {   # $1 snapshot json, $2 replay policy
    local wi ti si cwd provider sid name cmd mode out
    while IFS=$CW_US read -r wi ti si cwd provider sid name cmd; do
        [ -n "$wi" ] || continue
        out=$(pane_command "$provider" "$sid" "$cwd" "$cmd" "$2")
        mode=${out%%$'\t'*}
        printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$wi" "$CW_US" "$ti" "$CW_US" "$si" "$CW_US" "$cwd" "$CW_US" "$provider" "$CW_US" \
            "$sid" "$CW_US" "$name" "$CW_US" "$mode" "$CW_US" "${out#*$'\t'}"
    done < <(jq -r ".windows | to_entries[] | (.key + 1) as \$wi | .value.tabs[] | .index as \$ti
        | .terminals | to_entries[]
        | [\$wi, \$ti, (.key + 1), .value.cwd,
           (.value.session.provider // \"\"), (.value.session.sessionId // \"\"),
           (.value.session.name // \"\"), (.value.command // \"\")] | $JQ_REC" <<<"$1")
}

layout_shape() {   # live layout TSV on stdin
    jq -Rn '[inputs | select(length > 0) | split("\t")] as $rows
        | [ $rows[] | select(.[0] == "W") | .[1] | tonumber ] as $wis
        | [ $wis[] as $wi
            | [ $rows[] | select(.[0] == "T" and (.[1] | tonumber) == $wi) | .[2] | tonumber ] as $tis
            | [ $tis[] as $ti
                | [ $rows[] | select(.[0] == "S" and (.[1] | tonumber) == $wi and (.[2] | tonumber) == $ti) | .[4] ] ] ]'
}

live_pane_at() {   # $1 wi, $2 ti, $3 si, $4 layout -> id\tcwd\ttitle
    awk -F'\t' -v w="$1" -v t="$2" -v i="$3" -v us="$CW_US" \
        '$1 == "S" && $2 == w && $3 == t { n++; if (n == i) { print $4 us $5 us $6; exit } }' <<<"$4"
}

session_is_running() {   # $1 sessionId, $2 sessions TSV
    [ -n "$1" ] || return 1
    awk -F'\t' -v s="$1" '$3 == s { found = 1 } END { exit !found }' <<<"$2"
}

session_pid() {   # $1 sessionId, $2 sessions TSV
    awk -F'\t' -v s="$1" '$3 == s { print $6; exit }' <<<"$2"
}

# What the in-place path would do for each pane that has something to run.
# TSV: wi ti si cwd name mode command paneId liveCwd title decision reason
# With relaunch=1 it pretends the terminal just restarted: nothing is running,
# nothing is claimed, and no pane is showing an agent yet.
evaluate_inplace() {   # $1 snapshot, $2 layout, $3 sessions, $4 start epoch, $5 relaunch, $6 policy
    local wi ti si cwd provider sid name mode cmd paneId liveCwd title decision reason pid
    while IFS=$CW_US read -r wi ti si cwd provider sid name mode cmd; do
        [ "$mode" = none ] && continue
        [ -n "$name" ] || name=${cmd%% *}
        paneId=""; liveCwd=""; title=""
        IFS=$CW_US read -r paneId liveCwd title <<<"$(live_pane_at "$wi" "$ti" "$si" "$2")"
        pid=""
        [ "$5" -eq 0 ] && pid=$(session_pid "$sid" "$3")
        if [ -n "$pid" ]; then
            decision="skip"; reason="already running (pid $pid)"
        elif [ "$5" -eq 0 ] && [ -n "$sid" ] && [ -d "$(claimed_dir "$4")/$sid" ]; then
            decision="skip"; reason="another pane is already resuming it"
        elif [ -z "$paneId" ]; then
            decision="newtab"; reason="no pane exists at window $wi tab $ti position $si any more"
        elif [ "$liveCwd" != "$cwd" ]; then
            decision="newtab"; reason="the pane there is in $(short "$liveCwd"), not $(short "$cwd")"
        elif [ "$5" -eq 0 ] && printf '%s' "$title" | grep -qE "$CW_AGENT_TITLE_RE"; then
            decision="skip"; reason="that pane is already running something ($title)"
        elif [ "$mode" = prefill ]; then
            decision="prefill"; reason="$cmd"
        else
            decision="type"; reason="$cmd"
        fi
        printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$wi" "$CW_US" "$ti" "$CW_US" "$si" "$CW_US" "$cwd" "$CW_US" "$name" "$CW_US" "$mode" "$CW_US" \
            "$cmd" "$CW_US" "$paneId" "$CW_US" "$liveCwd" "$CW_US" "$title" "$CW_US" "$decision" "$CW_US" "$reason"
    done < <(snapshot_panes "$1" "$6")
}

describe_decisions() {   # $1 evaluation TSV, $2 "would" or ""
    local wi ti si cwd name mode cmd paneId liveCwd title decision reason verb
    while IFS=$CW_US read -r wi ti si cwd name mode cmd paneId liveCwd title decision reason; do
        [ -n "$wi" ] || continue
        case $decision in
            type) verb="type" ;;
            prefill) verb="type without running" ;;
            skip) verb="skip" ;;
            newtab) verb="open in a new tab" ;;
        esac
        printf '  tab %s pane %s%s  %s  %s -> %s%s: %s\n' \
            "$ti" "$si" "${paneId:+ ${paneId:0:8}}" "$(short "$cwd")" "$name" \
            "${2:+would }" "$verb" "$reason"
    done <<<"$1"
}

# Every live pane in order with what its first prompt would do. This is exactly
# the lookup the shell hook performs, so it is the honest preview.
describe_live_panes() {   # $1 snapshot, $2 layout, $3 sessions, $4 relaunch, $5 policy
    local _ wi ti paneId cwd title si key prev="" n=0 scwd sid provider name cmd mode out pid
    while IFS=$CW_US read -r _ wi ti paneId cwd title; do
        key="$wi,$ti"
        if [ "$key" != "$prev" ]; then n=0; prev=$key; fi
        n=$((n + 1)); si=$n
        IFS=$CW_US read -r scwd provider sid name cmd <<<"$(jq -r --argjson wi "$wi" --argjson ti "$ti" --argjson si "$si" "
            ((.windows[\$wi - 1].tabs // []) | map(select(.index == \$ti)) | .[0].terminals // [])[\$si - 1] // {}
            | [(.cwd // \"\"), (.session.provider // \"\"), (.session.sessionId // \"\"),
               (.session.name // \"\"), (.command // \"\")] | $JQ_REC" <<<"$1")"
        printf '  tab %s pane %s %s  %s' "$ti" "$si" "${paneId:0:8}" "$(short "$cwd")"
        if [ -z "$scwd" ]; then
            printf ' -> nothing: no pane at this position in the snapshot\n'; continue
        fi
        if [ "$scwd" != "$cwd" ]; then
            printf ' -> nothing: the snapshot has %s at this position\n' "$(short "$scwd")"; continue
        fi
        pid=""
        [ "$4" -eq 0 ] && pid=$(session_pid "$sid" "$3")
        if [ -n "$pid" ]; then
            printf ' -> nothing: %s is already running (pid %s)\n' "$name" "$pid"; continue
        fi
        out=$(pane_command "$provider" "$sid" "$cwd" "$cmd" "$5")
        mode=${out%%$'\t'*}
        case $mode in
            run) printf ' -> would run: %s%s\n' "${out#*$'\t'}" "${name:+   ($name)}" ;;
            prefill) printf ' -> would type without running: %s\n' "${out#*$'\t'}" ;;
            *) printf ' -> nothing: plain shell in the snapshot\n' ;;
        esac
    done < <(grep $'^S\t' <<<"$2" | tr '\t' "$CW_US")
}

print_rebuild_plan() {   # $1 snapshot, $2 sessions, $3 relaunch, $4 layout style, $5 policy
    local w t idx tname pinned n k cwd provider sid name cmd mode out how pid
    while IFS=$CW_US read -r w t idx tname pinned n; do
        printf '  tab %s [%s]%s\n' "$idx" "$tname" "$([ "$pinned" = true ] && printf ' (pinned title restored)')"
        for (( k = 0; k < n; k++ )); do
            IFS=$CW_US read -r cwd provider sid name cmd <<<"$(jq -r ".windows[$w].tabs[$t].terminals[$k]
                | [.cwd, (.session.provider // \"\"), (.session.sessionId // \"\"), (.session.name // \"\"), (.command // \"\")] | $JQ_REC" <<<"$1")"
            if [ "$k" -eq 0 ]; then how="new tab"
            elif [ "$4" = grid ] && (( k % 2 == 0 )); then how="split down"
            else how="split right"; fi
            pid=""
            [ "$3" -eq 0 ] && pid=$(session_pid "$sid" "$2")
            printf '    pane %s  %-11s %s' "$((k + 1))" "$how" "$(short "$cwd")"
            if [ -n "$pid" ]; then
                printf ' -> plain shell: %s is already running (pid %s)\n' "$name" "$pid"; continue
            fi
            out=$(pane_command "$provider" "$sid" "$cwd" "$cmd" "$5")
            mode=${out%%$'\t'*}
            case $mode in
                run) printf ' -> runs at its first prompt: %s%s\n' "${out#*$'\t'}" "${name:+   ($name)}" ;;
                prefill) printf ' -> waits at its prompt with: %s\n' "${out#*$'\t'}" ;;
                *) printf ' -> plain shell\n' ;;
            esac
        done
    done < <(jq -r ".windows | to_entries[] | .key as \$w | .value.tabs | to_entries[] | .key as \$t | .value as \$tab
        | [\$w, \$t, \$tab.index, \$tab.name, \$tab.pinned, (\$tab.terminals | length)] | $JQ_REC" <<<"$1")
}

# --- doing it --------------------------------------------------------------
execute_inplace() {   # $1 evaluation, $2 start epoch; prints leftovers as cwd\tprovider\tsid\tname\tcmd
    local wi ti si cwd name mode cmd paneId liveCwd title decision reason n=0
    mkdir -p "$(claimed_dir "$2")"
    while IFS=$CW_US read -r wi ti si cwd name mode cmd paneId liveCwd title decision reason; do
        [ -n "$wi" ] || continue
        case $decision in
            newtab)
                printf '%s%s%s%s%s\n' "$cwd" "$CW_US" "$cmd" "$CW_US" "$name" ;;
            type|prefill)
                wait_ready "$paneId" "$cwd" ||
                    say "tab $ti pane $si: no prompt after ${CW_READY_TIMEOUT}s; sending anyway"
                if [ "$decision" = type ]; then
                    mkdir "$(claimed_dir "$2")/$(printf '%s' "$cmd" | shasum | cut -c1-16)" 2>/dev/null || true
                fi
                cwterm_type "$paneId" "$cmd" "$([ "$decision" = type ] && echo 1 || echo 0)"
                n=$((n + 1)) ;;
        esac
    done <<<"$1"
    say "sent a command to $n pane(s)"
}

# Turn a snapshot into a build plan for the terminal adapter.
build_plan() {   # $1 snapshot, $2 sessions, $3 layout style, $4 policy, $5 relaunch
    local w t k nwin ntab n idx tname pinned selected cwd provider sid name cmd out mode run prefill pid first
    nwin=$(jq '.windows | length' <<<"$1")
    for (( w = 0; w < nwin; w++ )); do
        ntab=$(jq ".windows[$w].tabs | length" <<<"$1")
        for (( t = 0; t < ntab; t++ )); do
            IFS=$CW_US read -r idx tname pinned selected n <<<"$(jq -r ".windows[$w].tabs[$t]
                | [.index, .name, .pinned, .selected, (.terminals | length)] | $JQ_REC" <<<"$1")"
            [ "$n" -gt 0 ] || continue
            first=1
            for (( k = 0; k < n; k++ )); do
                IFS=$CW_US read -r cwd provider sid name cmd <<<"$(jq -r ".windows[$w].tabs[$t].terminals[$k]
                    | [.cwd, (.session.provider // \"\"), (.session.sessionId // \"\"), (.session.name // \"\"), (.command // \"\")] | $JQ_REC" <<<"$1")"
                run=""; prefill=""
                pid=""
                [ "$5" -eq 0 ] && pid=$(session_pid "$sid" "$2")
                if [ -z "$pid" ]; then
                    out=$(pane_command "$provider" "$sid" "$cwd" "$cmd" "$4")
                    mode=${out%%$'\t'*}
                    case $mode in
                        run) run=${out#*$'\t'} ;;
                        prefill) prefill=${out#*$'\t'} ;;
                    esac
                fi
                if [ "$first" = 1 ]; then
                    printf '%s%s%s%s%s%s%s\n' "$([ "$t" -eq 0 ] && echo W || echo T)" \
                        "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                    first=0
                elif [ "$3" = grid ] && (( k % 2 == 0 )); then
                    printf 'P%sdown%s%s%s%s%s%s%s%s\n' "$CW_US" "$CW_US" "$((k - 2))" \
                        "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                else
                    printf 'P%sright%s%s%s%s%s%s%s%s\n' "$CW_US" "$CW_US" "$((k - 1))" \
                        "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                fi
            done
            [ "$pinned" = true ] && printf 'N%s%s\n' "$CW_US" "$tname"
            [ "$selected" = true ] && printf 'S\n'
        done
    done
}

# Screens can be added, removed or resized between snapshot and restore; only
# put a window back at remembered coordinates when the desktop is unchanged.
screens_unchanged() {   # $1 snapshot
    local was now
    was=$(jq -c '.screens // []' <<<"$1")
    now=$(screen_frames)
    [ "$was" = "[]" ] && return 1
    [ "$was" = "$now" ]
}

restore_rebuild() {   # $1 snapshot, $2 sessions, $3 layout style, $4 policy, $5 relaunch
    local created plan paneId cwd run prefill nwin bounds
    plan=$(build_plan "$1" "$2" "$3" "$4" "$5")
    created=$(cwterm_build <<<"$plan") || { say "the terminal refused to build the layout"; return 1; }
    nwin=$(grep -c "^W$CW_US" <<<"$plan" || true)
    say "built $nwin window(s), $(grep -c . <<<"$created") pane(s)"

    # Adapters that cannot pass environment to a new pane get typed into.
    if ! terminal_has env; then
        while IFS=$CW_US read -r paneId cwd run prefill; do
            [ -n "$paneId" ] || continue
            [ -n "$run" ] && { wait_ready "$paneId" "$cwd" || true; cwterm_type "$paneId" "$run" 1; }
            [ -n "$prefill" ] && { wait_ready "$paneId" "$cwd" || true; cwterm_type "$paneId" "$prefill" 0; }
        done <<<"$created"
    fi

    if [ "$CW_RESTORE_BOUNDS" = 1 ] && terminal_has bounds; then
        bounds=$(jq -r '.windows[0].bounds | if . == null then "" else "\(.x)\t\(.y)\t\(.w)\t\(.h)" end' <<<"$1")
        if [ -z "$bounds" ]; then
            :
        elif screens_unchanged "$1"; then
            # The window just built is the frontmost one.
            # shellcheck disable=SC2086
            cwterm_apply_bounds 1 $bounds
            say "put the window back at its remembered position and size"
        else
            say "screen layout changed since the snapshot; left the window where the terminal put it"
        fi
    fi
}

# Sessions with no pane of their own, plus anything the in-place pass could not
# place, get a tab to themselves.
restore_unplaced() {   # $1 snapshot, $2 sessions, $3 extra lines: cwd\tcmd\tname
    local list cwd cmd name plan="" k=0 created paneId run prefill
    list=$(jq -r "[.unplaced[] | [.cwd, (.provider // \"\"), (.sessionId // \"\"), (.name // \"\")]][] | $JQ_REC" <<<"$1")
    local out mode provider sid
    local resolved=""
    while IFS=$CW_US read -r cwd provider sid name; do
        [ -n "$cwd" ] || continue
        session_is_running "$sid" "$2" && { say "$name: already running; no extra pane"; continue; }
        out=$(pane_command "$provider" "$sid" "$cwd" "" run)
        mode=${out%%$'\t'*}
        [ "$mode" = none ] && continue
        resolved+="$cwd$CW_US${out#*$'\t'}$CW_US$name"$'\n'
    done <<<"$list"
    [ -n "${3:-}" ] && resolved+="$3"$'\n'
    resolved=$(sed '/^$/d' <<<"$resolved")
    [ -n "$resolved" ] || return 0

    while IFS=$CW_US read -r cwd cmd name; do
        [ -n "$cwd" ] || continue
        say "${name:-that command} -> its own pane in a 'claude-workspace' tab, $(short "$cwd"): $cmd"
        if [ "$k" -eq 0 ]; then
            plan+="T$CW_US$cwd$CW_US$cmd$CW_US"$'\n'
        else
            plan+="P${CW_US}right$CW_US$((k - 1))$CW_US$cwd$CW_US$cmd$CW_US"$'\n'
        fi
        k=$((k + 1))
    done <<<"$resolved"
    [ "$k" -gt 0 ] || return 0
    plan+="N${CW_US}claude-workspace"$'\n'
    created=$(cwterm_build <<<"$plan") || return 0
    if ! terminal_has env; then
        while IFS=$CW_US read -r paneId cwd run prefill; do
            [ -n "$paneId" ] && [ -n "$run" ] && { wait_ready "$paneId" "$cwd" || true; cwterm_type "$paneId" "$run" 1; }
        done <<<"$created"
    fi
}

# --- commands --------------------------------------------------------------
cmd_restore() {
    local dry=0 force=0 name=latest mode=auto style=row policy=$CW_REPLAY_POLICY
    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run) dry=1; shift ;;
            --force) force=1; shift ;;
            --snapshot|--name) name=$2; shift 2 ;;
            --mode) mode=$2; shift 2 ;;
            --layout) style=$2; shift 2 ;;
            --replay) policy=$2; shift 2 ;;
            -*) die "restore: unknown option $1" ;;
            *) name=$1; shift ;;
        esac
    done
    case $mode in auto|inplace|rebuild) ;; *) die "--mode must be auto, inplace or rebuild" ;; esac
    case $style in row|grid) ;; *) die "--layout must be row or grid" ;; esac
    case $policy in off|prompt|auto|all) ;; *) die "--replay must be off, prompt, auto or all" ;; esac

    local snap
    snap=$(snapshot_read "$name") || die "no snapshot '$name' (try: claude-workspace list)"
    providers_load
    terminal_load
    cwterm_launch

    local sessions layout start evaluation would=""
    [ "$dry" -eq 1 ] && would=would
    sessions=$(providers_sessions)
    layout=$(cwterm_dump)
    start=$(terminal_start_epoch)
    evaluation=$(evaluate_inplace "$snap" "$layout" "$sessions" "$start" 0 "$policy")

    local total already matched actionable
    total=$(jq '[.windows[].tabs[].terminals[] | select(.session != null or .command != null)] + .unplaced | length' <<<"$snap")
    already=$(awk -F"$CW_US" '$11 == "skip" && $12 ~ /^already running/' <<<"$evaluation" | grep -c . || true)
    matched=$(awk -F"$CW_US" '$11 == "type" || $11 == "prefill" || $11 == "skip"' <<<"$evaluation" | grep -c . || true)
    actionable=$(awk -F"$CW_US" '$11 == "type" || $11 == "prefill"' <<<"$evaluation" | grep -c . || true)

    say "$(jq -r '"snapshot \(.name) from \(.savedAtLocal): \(.counts.tabs) tabs, \(.counts.terminals) panes"' <<<"$snap"); $already of $total already running; $matched panes still at their position; $actionable can be resumed in place"

    if [ "$mode" = auto ]; then
        if [ "$matched" -gt 0 ] && [ $((matched * 2)) -ge "$total" ]; then mode=inplace; else mode=rebuild; fi
    fi

    if [ "$mode" = inplace ]; then
        say "mode: inplace ($cwterm_label still has this layout; sessions go back into their panes)"
        describe_decisions "$evaluation" "$would" | tee_log
        if [ "$actionable" -eq 0 ] && [ "$force" -eq 0 ] && [ "$(jq '.unplaced | length' <<<"$snap")" -eq 0 ]; then
            say "nothing to do: no pane can be resumed in place, for the reasons above"
            return 0
        fi
    else
        say "mode: rebuild (only $matched of $total panes are where the snapshot put them; building a new window)"
        if [ "$already" -eq "$total" ] && [ "$total" -gt 0 ] && [ "$force" -eq 0 ]; then
            describe_decisions "$evaluation" "$would" | tee_log
            say "nothing to do: everything is already running, so a rebuilt window would hold only empty shells (--force builds it anyway)"
            return 0
        fi
        printf '%sbuild:\n' "${would:+would }" | tee_log
        print_rebuild_plan "$snap" "$sessions" 0 "$style" "$policy" | tee_log
    fi
    [ "$dry" -eq 1 ] && { say "dry run; nothing changed"; return 0; }

    local extra=""
    case $mode in
        inplace) extra=$(execute_inplace "$evaluation" "$start") ;;
        rebuild) restore_rebuild "$snap" "$sessions" "$style" "$policy" 0 ;;
    esac
    restore_unplaced "$snap" "$sessions" "$extra"

    touch "$CW_STATE_DIR/dismissed-$start"
    nohup "$CW_BIN_DIR/claude-workspace" save --force --delay 20 >/dev/null 2>&1 </dev/null &
    say "done; a fresh snapshot follows in 20s (claude-workspace log shows this run)"
}

cmd_simulate() {
    local name=${1:-latest} snap sessions layout evaluation newtab policy=$CW_REPLAY_POLICY
    snap=$(snapshot_read "$name") || die "no snapshot '$name' (run: claude-workspace save)"
    providers_load
    terminal_load
    cwterm_present || die "$cwterm_label is not running"
    sessions=$(providers_sessions)
    layout=$(cwterm_dump)

    jq -r '"Snapshot \(.name) from \(.savedAtLocal) [\(.terminal.label) \(.terminal.version)]: \(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions (\(.counts.placed) placed, \(.counts.unplaced) unplaced)."' <<<"$snap"
    printf 'Replay policy for ordinary commands: %s. Pretending %s just restarted. Nothing below is executed.\n\n' "$policy" "$cwterm_label"

    printf 'A. %s restored the layout itself (a quit or a reboot). Each pane at its first prompt:\n' "$cwterm_label"
    describe_live_panes "$snap" "$layout" "$sessions" 1 "$policy"

    evaluation=$(evaluate_inplace "$snap" "$layout" "$sessions" 0 1 "$policy")
    newtab=$(awk -F"$CW_US" '$11 == "newtab"' <<<"$evaluation" | grep -c . || true)
    printf '\n   %s pane(s) act on their own' "$(awk -F"$CW_US" '$11 == "type" || $11 == "prefill"' <<<"$evaluation" | grep -c . || true)"
    if [ "$newtab" -gt 0 ]; then
        printf '; %s would need `claude-workspace restore` to open elsewhere:\n' "$newtab"
        describe_decisions "$(awk -F"$CW_US" '$11 == "newtab"' <<<"$evaluation")" would
    else
        printf '; nothing left over.\n'
    fi

    printf '\nB. %s came back empty (a crash). The first shell runs `claude-workspace restore`, which builds:\n' "$cwterm_label"
    print_rebuild_plan "$snap" "$sessions" 1 row "$policy"
    if [ "$CW_RESTORE_BOUNDS" = 1 ] && terminal_has bounds; then
        if screens_unchanged "$snap"; then
            printf '  window position and size: restored (%s)\n' "$(jq -r '.windows[0].bounds | if . then "\(.w)x\(.h) at \(.x),\(.y)" else "not recorded" end' <<<"$snap")"
        else
            printf '  window position and size: skipped, the screen layout changed since the snapshot\n'
        fi
    fi
    printf '\nNothing was changed. `claude-workspace log` shows what real runs did.\n'
}

cmd_diff() {
    local name=${1:-latest} snap layout sessions
    snap=$(snapshot_read "$name") || die "no snapshot '$name'"
    providers_load
    terminal_load
    sessions=$(providers_sessions)
    layout=$(cwterm_dump)
    local want have
    want=$(jq -c '[ .windows[] | [ .tabs[] | [ .terminals[] | .cwd ] ] ]' <<<"$snap")
    have=$(layout_shape <<<"$layout")
    printf 'snapshot %s from %s vs the live %s\n\n' "$name" "$(jq -r .savedAtLocal <<<"$snap")" "$cwterm_label"
    jq -rn --argjson want "$want" --argjson have "$have" --arg home "$HOME" '
        def short: if startswith($home) then "~" + .[($home | length):] else . end;
        def shape($s): [$s[] | [.[] | length]];
        "tabs:  snapshot \($want[0] // [] | length), live \($have[0] // [] | length)",
        "panes per tab:  snapshot \(shape($want)[0] // [] | tostring), live \(shape($have)[0] // [] | tostring)",
        ( [range(0; ([($want[0] // [] | length), ($have[0] // [] | length)] | max))][]
          | . as $t
          | ($want[0][$t] // null) as $w | ($have[0][$t] // null) as $h
          | if $w == null then "  tab \($t + 1): only live  (\($h | map(short) | join(", ")))"
            elif $h == null then "  tab \($t + 1): only in the snapshot  (\($w | map(short) | join(", ")))"
            elif $w == $h then "  tab \($t + 1): same"
            else "  tab \($t + 1): differs — snapshot \($w | map(short) | join(", ")) / live \($h | map(short) | join(", "))" end )'
    printf '\nsessions:\n'
    local sid name2 provider
    while IFS=$CW_US read -r provider sid name2; do
        [ -n "$sid" ] || continue
        if session_is_running "$sid" "$sessions"; then
            printf '  %-28s %s  running\n' "$name2" "${sid:0:8}"
        else
            printf '  %-28s %s  in the snapshot only\n' "$name2" "${sid:0:8}"
        fi
    done < <(jq -r "[(.windows[].tabs[].terminals[].session | select(. != null)), .unplaced[]
        | [(.provider // \"claude\"), .sessionId, (.name // \"\")]][] | $JQ_REC" <<<"$snap")
    while IFS=$CW_US read -r provider sid name2; do
        [ -n "$sid" ] || continue
        jq -e --arg s "$sid" 'any(.. | objects | select(.sessionId? == $s); true)' <<<"$snap" >/dev/null 2>&1 ||
            printf '  %-28s %s  running, not in the snapshot\n' "$name2" "${sid:0:8}"
    done < <(printf '%s' "$sessions" | awk -F'\t' -v us="$CW_US" 'NF { print $1 us $3 us $5 }')
}

cmd_unplaced() {
    local snap
    snap=$(snapshot_read latest) || return 0
    providers_load
    terminal_load
    restore_unplaced "$snap" "$(providers_sessions)" ""
}

# --- the automatic path ----------------------------------------------------
# Every session in the pending snapshot is running or claimed: the restore is
# finished, so ordinary saves may replace the snapshot again.
finish_if_complete() {   # $1 start epoch
    local total=0 covered=0 sid sessions
    sessions=$(providers_sessions)
    while read -r sid; do
        [ -n "$sid" ] || continue
        total=$((total + 1))
        if [ -d "$(claimed_dir "$1")/$sid" ] || session_is_running "$sid" "$sessions"; then
            covered=$((covered + 1))
        fi
    done < <(jq -r '.windows[].tabs[].terminals[].session | select(. != null) | .sessionId' "$CW_LATEST")
    [ "$covered" -ge "$total" ] || return 0
    touch "$CW_STATE_DIR/dismissed-$1"
    logfile "restore complete: all $total sessions are running or claimed; ordinary snapshots resume"
    if [ "$(jq '.unplaced | length' "$CW_LATEST")" -gt 0 ]; then
        nohup "$CW_BIN_DIR/claude-workspace" unplaced >/dev/null 2>&1 </dev/null &
    fi
    nohup "$CW_BIN_DIR/claude-workspace" save --force --delay 20 >/dev/null 2>&1 </dev/null &
}

# The snapshot pane at a live pane's position.
pane_lookup() {   # $1 paneId, $2 layout -> wi ti si liveCwd snapCwd provider sid name cmd
    local pos wi ti si cwd
    pos=$(awk -F'\t' -v id="$1" -v us="$CW_US" '$1 == "S" { n[$2 "," $3]++; if ($4 == id) { print $2 us $3 us n[$2 "," $3] us $5; exit } }' <<<"$2")
    [ -n "$pos" ] || return 0
    IFS=$CW_US read -r wi ti si cwd <<<"$pos"
    jq -r --argjson wi "$wi" --argjson ti "$ti" --argjson si "$si" --arg cwd "$cwd" "
        ((.windows[\$wi - 1].tabs // []) | map(select(.index == \$ti)) | .[0].terminals // [])[\$si - 1] // {}
        | [\$wi, \$ti, \$si, \$cwd, (.cwd // \"\"), (.session.provider // \"\"), (.session.sessionId // \"\"),
           (.session.name // \"\"), (.command // \"\")] | $JQ_REC" "$CW_LATEST"
}

# Called by the shell hook at a new shell's first prompt. Prints one line the
# hook acts on: "run <cmd>", "prefill <cmd>", "rebuild", "notice <text>", or
# nothing at all. Every decision is logged with its reason.
cmd_first_prompt() {   # $1 tty, $2 cwd
    local tty=${1#/dev/} cwd=$2 paneId layout start
    local wi ti si lcwd scwd provider sid name cmd out mode where sessions

    terminal_load
    if ! restore_pending; then
        nohup "$CW_BIN_DIR/claude-workspace" register-self "$tty" "$cwd" >/dev/null 2>&1 </dev/null &
        # A new pane changes the layout, and agents started before the hooks
        # existed never trigger a save; this keeps the snapshot honest.
        nohup "$CW_BIN_DIR/claude-workspace" save --delay 2 --debounce 300 >/dev/null 2>&1 </dev/null &
        return 0
    fi
    providers_load
    paneId=$(cmd_register_self "$tty" "$cwd")
    if [ -z "$paneId" ]; then
        logfile "$tty: $cwterm_label did not identify this pane; nothing resumed here"
        first_prompt_notice
        return 0
    fi
    layout=$(cwterm_dump)
    start=$(terminal_start_epoch)

    # The terminal came back with a single empty pane: nothing to resume in
    # place, so the first shell to notice rebuilds the whole workspace.
    if [ "$(grep -c $'^S\t' <<<"$layout")" -eq 1 ] && [ "$(grep -c $'^W\t' <<<"$layout")" -eq 1 ]; then
        if mkdir "$CW_STATE_DIR/rebuild-$start" 2>/dev/null; then
            logfile "$tty pane ${paneId:0:8}: $cwterm_label has one empty pane; rebuilding the snapshot from $(jq -r .savedAtLocal "$CW_LATEST")"
            printf 'rebuild\n'
            return 0
        fi
    fi

    IFS=$CW_US read -r wi ti si lcwd scwd provider sid name cmd <<<"$(pane_lookup "$paneId" "$layout")"
    where="$tty pane ${paneId:0:8} (window $wi tab $ti position $si, $(short "$lcwd"))"
    if [ -z "$scwd" ]; then
        logfile "$where: no pane at this position in the snapshot; nothing to resume"
    elif [ "$scwd" != "$lcwd" ]; then
        logfile "$where: the snapshot has $(short "$scwd") at this position; nothing to resume"
    else
        sessions=$(providers_sessions)
        if [ -n "$sid" ] && session_is_running "$sid" "$sessions"; then
            logfile "$where: $name is already running; nothing to do"
        else
            out=$(pane_command "$provider" "$sid" "$lcwd" "$cmd" "$CW_REPLAY_POLICY")
            mode=${out%%$'\t'*}
            if [ "$mode" = none ]; then
                logfile "$where: plain shell in the snapshot; nothing to resume"
            else
                mkdir -p "$(claimed_dir "$start")"
                local key=${sid:-$(printf '%s' "$cmd" | shasum | cut -c1-16)}
                if mkdir "$(claimed_dir "$start")/$key" 2>/dev/null; then
                    logfile "$where: ${name:-pane} -> $mode: ${out#*$'\t'}"
                    printf '%s %s\n' "$mode" "${out#*$'\t'}"
                    finish_if_complete "$start"
                    return 0
                fi
                logfile "$where: ${name:-that command} was already claimed by another pane; nothing to do"
            fi
        fi
    fi
    first_prompt_notice
}

first_prompt_notice() {
    restore_pending || return 0
    jq -r '"claude-workspace: restoring the snapshot from \(.savedAtLocal) (\(.counts.tabs) tabs, \(.counts.sessions) sessions); each pane picks up its own as it opens. `claude-workspace restore` fills in anything missed, `claude-workspace dismiss` stops it."' "$CW_LATEST"
}
