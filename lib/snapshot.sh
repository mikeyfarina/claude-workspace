# shellcheck shell=bash
# term_* and provider_* come from the adapter and provider files loaded at
# run time; the jq programs are single-quoted on purpose.
# shellcheck disable=SC2154,SC2016
# Taking, reading and describing snapshots.

# Claude Code and friends put a spinner glyph in front of the pane title while
# they work. Used only as a fallback when a session's tty is not mapped yet.
PANEFUL_AGENT_TITLE_RE=${PANEFUL_AGENT_TITLE_RE:-'^(✳|✻|◐|◓|◑|◒|✶|✽|·)'}

terminal_start_epoch() {
    declare -f term_start_epoch >/dev/null 2>&1 || { printf '0'; return 0; }
    term_start_epoch 2>/dev/null || printf '0'
}

# --- restore markers -------------------------------------------------------
# All keyed by the terminal's start time, so they expire when it restarts.
claimed_dir() { printf '%s/claimed-%s' "$PANEFUL_STATE_DIR" "$1"; }

restore_pending() {
    [ -f "$PANEFUL_LATEST" ] || return 1
    local start
    start=$(terminal_start_epoch)
    [ "$start" != 0 ] || return 1
    [ ! -e "$PANEFUL_STATE_DIR/dismissed-$start" ] &&
        [ "$(jq -r '.terminal.start // .ghosttyStart // 0' "$PANEFUL_LATEST")" != "$start" ]
}

prune_markers() {   # $1 current start epoch
    local f
    for f in "$PANEFUL_STATE_DIR"/dismissed-* "$PANEFUL_STATE_DIR"/rebuild-* "$PANEFUL_STATE_DIR"/claimed-*; do
        [ -e "$f" ] || continue
        case $f in *-"$1") ;; *) rm -r -- "$f" ;; esac
    done
    return 0
}

# --- reading ---------------------------------------------------------------
# Snapshots written by 0.1 had the Ghostty start time at the top level and no
# provider or command fields. Normalise them on the way in so nothing else has
# to know about the old shape.
snapshot_read() {   # $1 name or path
    local f
    f=$(snap_path "${1:-latest}")
    [ -f "$f" ] || return 1
    jq '
        if (.version // 1) >= 2 then .
        else
          . as $o
          | {
              version: 2,
              name: (.name // "latest"),
              savedAt, savedAtLocal, savedAtEpoch,
              terminal: {id: "ghostty", label: "Ghostty", version: "", start: (.ghosttyStart // 0)},
              host,
              screens: [],
              windows: [ .windows[] | {
                  id, name, bounds: null,
                  tabs: [ .tabs[] | {
                      index, name, selected, pinned,
                      terminals: [ .terminals[] | {
                          id, cwd, title, tty,
                          session: (if .session == null then null
                                    else {provider: "claude", sessionId: .session.sessionId,
                                          name: .session.name, pid: .session.pid,
                                          placement: .session.placement} end),
                          command: null
                      } ]
                  } ]
              } ],
              unplaced: [ .unplaced[] | {provider: "claude", sessionId, name, cwd, tty, pid} ],
              counts
            }
        end' "$f"
}

# --- taking ----------------------------------------------------------------
JQ_BUILD='
def tsv: split("\n") | map(select(length > 0) | split("\t"));
[inputs | select(length > 0) | split("\t")] as $rows
| ($sessions | tsv | map({provider: .[0], tty: .[1], sessionId: .[2], cwd: .[3],
                          name: .[4], pid: ((.[5] // "0") | tonumber? // 0)})) as $sess
| ($commands | tsv | map({key: .[0], value: .[1]}) | from_entries) as $cmdByTty
| ($bounds | tsv | map({key: .[0],
                        value: {x: (.[1] | tonumber), y: (.[2] | tonumber),
                                w: (.[3] | tonumber), h: (.[4] | tonumber)}}) | from_entries) as $boundsByWin
| [ $rows[] | select(.[0] == "W") | {wi: (.[1] | tonumber), id: .[2], name: .[3]} ] as $ws
| [ $rows[] | select(.[0] == "T") | {wi: (.[1] | tonumber), index: (.[2] | tonumber),
                                     selected: (.[3] == "true"), focused: .[4], name: .[5]} ] as $ts
| [ $rows[] | select(.[0] == "S") | {wi: (.[1] | tonumber), ti: (.[2] | tonumber),
                                     id: .[3], cwd: .[4], title: .[5]} ] as $ss
| ($ss | map(.id)) as $liveIds
| ($map | tsv | map(select(.[1] as $id | $liveIds | index($id) != null)
                    | {key: .[0], value: .[1]}) | from_entries) as $ttyToPane
| ($ttyToPane | to_entries | map({key: .value, value: .key}) | from_entries) as $paneToTty
| ($sess | map(select($ttyToPane[.tty] != null)
               | {key: $ttyToPane[.tty], value: (. + {placement: "tty"})}) | from_entries) as $exact
# A session whose tty is not mapped yet is placed only when exactly one free
# pane in the same directory looks like an agent; otherwise it is listed as
# unplaced and restore gives it a pane of its own.
| reduce ($sess | map(select($ttyToPane[.tty] == null)))[] as $s ({byPane: $exact, unplaced: []};
    . as $st
    | ([ $ss[] | select(.cwd == $s.cwd and (.title | test($agentTitle))) | .id ]
       | map(select($st.byPane[.] == null))) as $free
    | if ($free | length) == 1 then .byPane[$free[0]] = ($s + {placement: "cwd"})
      else .unplaced += [$s] end)
| .byPane as $bp | .unplaced as $unplaced
| {
    version: 2,
    name: $name,
    savedAt: $savedAt, savedAtLocal: $savedAtLocal, savedAtEpoch: $savedAtEpoch,
    terminal: {id: $termId, label: $termLabel, version: $termVersion, start: $termStart},
    host: $host,
    screens: ($screens | fromjson? // []),
    windows: [ $ws[] | . as $w | {
      id: .id, name: .name,
      bounds: ($boundsByWin[.wi | tostring] // null),
      tabs: [ $ts[] | select(.wi == $w.wi) | . as $t | {
        index: .index, name: .name, selected: .selected,
        pinned: ([ $ss[] | select(.wi == $t.wi and .ti == $t.index and .id == $t.focused) | .title ]
                 | (length > 0 and .[0] != $t.name)),
        terminals: [ $ss[] | select(.wi == $t.wi and .ti == $t.index) | . as $p | {
          id: .id, cwd: .cwd, title: .title,
          tty: ($paneToTty[.id] // null),
          session: ($bp[.id] | if . == null then null
                    else {provider, sessionId, name, pid, placement} end),
          command: (($paneToTty[$p.id] // "") as $tty
                    | if $tty == "" then null else ($cmdByTty[$tty] // null) end)
        } ]
      } ]
    } ],
    unplaced: [ $unplaced[] | {provider, sessionId, name, cwd, tty, pid} ],
    counts: {
      windows: ($ws | length), tabs: ($ts | length), terminals: ($ss | length),
      sessions: ($sess | length), placed: ($bp | length), unplaced: ($unplaced | length)
    }
  }'

snapshot_capture() {   # $1 name
    local layout sessions commands bounds tty
    layout=$(term_dump) || die "could not read the $term_label layout"
    prune_tty_map
    sessions=$(providers_sessions)
    commands=""
    for tty in $(tty_map | cut -f1); do
        local cmd
        cmd=$(foreground_command "$tty")
        [ -n "$cmd" ] && commands+="$tty"$'\t'"$cmd"$'\n'
    done
    bounds=""
    if [ "$PANEFUL_RESTORE_BOUNDS" = 1 ] && terminal_has bounds; then
        bounds=$(term_bounds 2>/dev/null | sed -n 's/^WB\t//p')
    fi
    jq -Rn \
        --arg sessions "$sessions" --arg map "$(tty_map)" --arg commands "$commands" \
        --arg bounds "$bounds" --arg agentTitle "$PANEFUL_AGENT_TITLE_RE" \
        --arg name "${1:-latest}" \
        --arg savedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg savedAtLocal "$(date '+%Y-%m-%d %H:%M')" \
        --argjson savedAtEpoch "$(date +%s)" \
        --arg termId "$PANEFUL_TERM" --arg termLabel "$term_label" \
        --arg termVersion "$(term_version 2>/dev/null || true)" \
        --argjson termStart "$(terminal_start_epoch)" \
        --arg host "$(hostname)" --arg screens "$(screen_frames)" \
        "$JQ_BUILD" <<<"$layout"
}

# Newest first. `ls -t` cannot be used safely, and a glob cannot sort by time.
history_by_age() {
    local f
    for f in "$PANEFUL_HISTORY_DIR"/*.json; do
        [ -e "$f" ] || continue
        printf '%s\t%s\n' "$(stat -f %m "$f")" "$f"
    done | sort -rn | cut -f2-
}

prune_history() {
    local f n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        [ "$n" -gt "$PANEFUL_HISTORY_KEEP" ] && rm -- "$f"
    done < <(history_by_age)
    return 0
}

cmd_save() {
    local debounce=0 delay=0 force=0 name=latest
    while [ $# -gt 0 ]; do
        case $1 in
            --name) name=$2; shift 2 ;;
            --debounce) debounce=$2; shift 2 ;;
            --delay) delay=$2; shift 2 ;;
            --force) force=1; shift ;;
            *) die "save: unknown option $1" ;;
        esac
    done
    [ "$delay" -gt 0 ] && sleep "$delay"

    terminal_load
    term_present || { log "$term_label is not running; nothing saved"; return 0; }

    local target
    target=$(snap_path "$name")
    if [ "$debounce" -gt 0 ] && [ -f "$target" ]; then
        [ $(( $(date +%s) - $(stat -f %m "$target") )) -ge "$debounce" ] || return 0
    fi

    # One save at a time. A lock older than 60s belongs to a save that died.
    if ! mkdir "$PANEFUL_LOCK_DIR" 2>/dev/null; then
        if [ $(( $(date +%s) - $(stat -f %m "$PANEFUL_LOCK_DIR") )) -gt 60 ]; then
            rmdir "$PANEFUL_LOCK_DIR"; mkdir "$PANEFUL_LOCK_DIR" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    # shellcheck disable=SC2064
    trap "rmdir '$PANEFUL_LOCK_DIR' 2>/dev/null" EXIT

    local start snap
    start=$(terminal_start_epoch)
    snap=$(snapshot_capture "$name")
    # Never let a half-built snapshot replace a good one.
    if [ -z "$snap" ] || ! jq -e '.counts.terminals' <<<"$snap" >/dev/null 2>&1; then
        log "could not build a snapshot from $term_label; kept the previous one"
        return 1
    fi

    if [ "$name" != latest ]; then
        printf '%s\n' "$snap" > "$target"
        jq -r --arg n "$name" '"saved snapshot \($n): \(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions"' <<<"$snap" >&2
        return 0
    fi

    printf '%s\n' "$snap" > "$PANEFUL_HISTORY_DIR/$(date +%Y%m%d-%H%M%S).json"
    prune_history

    if [ "$force" -eq 0 ] && [ -f "$PANEFUL_LATEST" ]; then
        local old_sessions old_start new_sessions
        old_sessions=$(jq '.counts.sessions' "$PANEFUL_LATEST")
        old_start=$(jq -r '.terminal.start // .ghosttyStart // 0' "$PANEFUL_LATEST")
        new_sessions=$(jq '.counts.sessions' <<<"$snap")
        # The terminal restarted since this snapshot: it is the one a restore
        # needs, so keep it until the restore finishes or is dismissed.
        if [ "$old_start" != "$start" ] && [ ! -e "$PANEFUL_STATE_DIR/dismissed-$start" ]; then
            logfile "a restore is pending (snapshot from $(jq -r .savedAtLocal "$PANEFUL_LATEST")); wrote history only"
            return 0
        fi
        if [ "$new_sessions" -eq 0 ] && [ "$old_sessions" -gt 0 ]; then
            log "no agent sessions running; kept the previous snapshot"
            return 0
        fi
    fi

    local tmp
    tmp=$(mktemp "$PANEFUL_SNAP_DIR/.latest.XXXXXX")
    printf '%s\n' "$snap" > "$tmp"
    mv "$tmp" "$PANEFUL_LATEST"
    prune_markers "$start"
    jq -r '"saved \(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions (\(.counts.placed) placed)"' <<<"$snap" >&2
}

# --- describing ------------------------------------------------------------
print_plan() {   # $1 snapshot json
    jq -r --arg home "$HOME" '
        def short: if startswith($home) then "~" + .[($home | length):] else . end;
        "snapshot \(.name) from \(.savedAtLocal) [\(.terminal.label)]: \(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions (\(.counts.placed) placed, \(.counts.unplaced) unplaced)",
        (.windows[] | .tabs[]
            | "  tab \(.index) [\(.name)]\(if .pinned then " (pinned)" else "" end)",
              (.terminals[] | "      \(.cwd | short)"
                 + (if .session then "  -> \(.session.name) \(.session.sessionId[0:8]) [\(.session.provider)]"
                    elif .command then "  -> was running: \(.command)"
                    else "  (shell)" end))),
        (.unplaced[] | "  unplaced: \(.name) \(.sessionId[0:8]) in \(.cwd | short)")
    ' <<<"$1" >&2
}

cmd_status() {
    local snap
    snap=$(snapshot_read "${1:-latest}") || die "no snapshot yet (run: paneful save)"
    terminal_load
    print_plan "$snap"
    if restore_pending; then
        log "restore pending: yes ($term_label restarted since this snapshot)"
    else
        log "restore pending: no"
    fi
    log "panes with a known tty: $(tty_map | wc -l | tr -d ' ')   history: $(history_by_age | wc -l | tr -d ' ') snapshots"
    if [ -f "$PANEFUL_LOG_FILE" ]; then
        log "last activity:"
        tail -n 5 "$PANEFUL_LOG_FILE" | sed 's/^/  /' >&2
    fi
}

cmd_list() {
    local f name
    printf 'named snapshots:\n'
    for f in "$PANEFUL_SNAP_DIR"/*.json; do
        [ -e "$f" ] || continue
        name=${f##*/}; name=${name%.json}
        jq -r --arg n "$name" '"  \($n)\t\(.savedAtLocal)\t\(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions"' "$f"
    done
    printf '\nsave a named one with: paneful save --name <name>\n'
    printf 'restore it with:        paneful restore <name>\n'
}

cmd_history() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        jq -r --arg f "$f" '"\(.savedAtLocal)  \(.counts.tabs) tabs  \(.counts.terminals) panes  \(.counts.sessions) sessions  \($f)"' "$f"
    done < <(history_by_age)
}

cmd_dismiss() {
    terminal_load
    local start
    start=$(terminal_start_epoch)
    [ "$start" != 0 ] || die "$term_label is not running"
    touch "$PANEFUL_STATE_DIR/dismissed-$start"
    say "dismissed; the next save replaces the pending snapshot"
}

# Claude Code hook entrypoint: never blocks, never prints (its stdout would
# become prompt context), hands the work to a detached save.
cmd_hook() {
    local event=${1:-} args
    cat >/dev/null 2>&1 || true
    case $event in
        session-start) args="--delay 3 --debounce 10" ;;
        session-end) args="--delay 5" ;;
        prompt) args="--debounce 60" ;;
        *) exit 0 ;;
    esac
    # shellcheck disable=SC2086
    nohup "$PANEFUL_BIN_DIR/paneful" save $args >/dev/null 2>&1 </dev/null &
    exit 0
}
