# shellcheck shell=bash
# cwterm_* values are read by the loader in lib/terminal.sh.
# shellcheck disable=SC2034
# WezTerm adapter, written from the `wezterm cli` documentation and not yet
# exercised against a running WezTerm. `claude-workspace terminals` says so.
#
# WezTerm's cli needs no configuration, but it reports neither a pid nor a tty
# for a pane, so this is the one terminal where the OSC 7 probe is the only way
# to tell which pane a shell is sitting in. It also has no way to pass
# environment to a new pane, so the command is handed over by spawning the
# shell through `env` instead.

cwterm_label="WezTerm"
cwterm_caps="env tabtitle split type"
cwterm_verified="from documentation"

cwterm_present() { command -v wezterm >/dev/null 2>&1 && wezterm cli list >/dev/null 2>&1; }
cwterm_current() { [ -n "${WEZTERM_PANE:-}" ] && cwterm_present; }
cwterm_version() { wezterm -V 2>/dev/null | awk '{print $2; exit}'; }
cwterm_start_epoch() {
    local pid
    pid=$(ps -axo pid=,comm= | awk '$2 ~ /wezterm-gui$/ { print $1 }' | sed -n '1p')
    [ -n "$pid" ] || return 1
    date -j -f '%a %b %d %H:%M:%S %Y' "$(ps -o lstart= -p "$pid" | sed 's/ *$//')" '+%s' 2>/dev/null
}
cwterm_launch() {
    cwterm_present && return 0
    command -v wezterm >/dev/null 2>&1 || die "wezterm is not installed"
    open -a WezTerm 2>/dev/null || wezterm start >/dev/null 2>&1 &
    local i
    for (( i = 0; i < 40; i++ )); do sleep 0.5; cwterm_present && return 0; done
    die "wezterm cli did not answer"
}

# `wezterm cli list --format json` is a flat list of panes carrying their
# window and tab ids, so the tree is rebuilt here.
cwterm_dump() {
    wezterm cli list --format json 2>/dev/null | jq -r '
        def path: if (. // "") | startswith("file://") then (. | sub("^file://[^/]*"; "")) else (. // "") end;
        [.[] | {w: .window_id, t: .tab_id, p: .pane_id, cwd: (.cwd | path), title: (.title // "")}] as $panes
        | ($panes | map(.w) | unique) as $wins
        | $wins | to_entries[] | (.key + 1) as $wi | .value as $wid
        | ("W\t\($wi)\t\($wid)\t")
        , ( [$panes[] | select(.w == $wid) | .t] | unique | to_entries[] | (.key + 1) as $ti | .value as $tid
            | ("T\t\($wi)\t\($ti)\tfalse\t\([$panes[] | select(.t == $tid) | .p] | .[0])\t")
            , ($panes[] | select(.t == $tid) | "S\t\($wi)\t\($ti)\t\(.p)\t\(.cwd)\t\(.title)") )'
}

cwterm_find_pane() {   # $1 directory
    wezterm cli list --format json 2>/dev/null | jq -r --arg d "$1" '
        def path: if (. // "") | startswith("file://") then (. | sub("^file://[^/]*"; "")) else (. // "") end;
        [.[] | select((.cwd | path) == $d) | .pane_id] | .[0] // empty'
}

cwterm_ttys() {
    local pid
    pid=$(ps -axo pid=,comm= | awk '$2 ~ /wezterm-gui$/ { print $1 }' | sed -n '1p')
    [ -n "$pid" ] || return 0
    ps -axo ppid=,tty= | awk -v g="$pid" '$1 == g && $2 != "??" { print $2 }' | sort -u
}

cwterm_type() {   # $1 paneId, $2 text, $3 submit
    if [ "${3:-1}" = 1 ]; then
        printf '%s\r' "$2" | wezterm cli send-text --pane-id "$1" --no-paste
    else
        printf '%s' "$2" | wezterm cli send-text --pane-id "$1" --no-paste
    fi
}

cwterm_set_tab_title() {
    local tab
    tab=$(wezterm cli list --format json 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pane_id == $p) | .tab_id] | .[0] // empty')
    [ -n "$tab" ] && wezterm cli set-tab-title --tab-id "$tab" -- "$2"
}

# WezTerm exposes window geometry only to its own Lua config, not to the cli.
cwterm_bounds() { :; }
cwterm_apply_bounds() { :; }

# No --env flag exists, so the shell is started through env(1), which is the
# documented way to get variables into a new pane.
_wz_cmd() {   # $1 run, $2 prefill -> fills WZ_CMD with the trailing "-- ..." part
    WZ_CMD=()
    local shell=${SHELL:-/bin/zsh}
    if [ -n "$1" ] || [ -n "$2" ]; then
        WZ_CMD=(-- /usr/bin/env)
        [ -n "$1" ] && WZ_CMD+=("$CW_ENV_RUN=$1")
        [ -n "$2" ] && WZ_CMD+=("$CW_ENV_PREFILL=$2")
        WZ_CMD+=("$shell" -l)
    fi
    return 0
}

cwterm_build() {
    local line kind a b c d e cwd run prefill dir from pane_id
    local -a panes=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$CW_US read -r kind a b c d e <<<"$line"
        case $kind in
            W|T)
                cwd=$a; run=$b; prefill=$c
                panes=()
                _wz_cmd "$run" "$prefill"
                if [ "$kind" = W ]; then
                    pane_id=$(wezterm cli spawn --new-window --cwd "$cwd" ${WZ_CMD[@]+"${WZ_CMD[@]}"} 2>/dev/null)
                else
                    pane_id=$(wezterm cli spawn --cwd "$cwd" ${WZ_CMD[@]+"${WZ_CMD[@]}"} 2>/dev/null)
                fi
                panes=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            P)
                dir=$a; from=$b; cwd=$c; run=$d; prefill=$e
                _wz_cmd "$run" "$prefill"
                pane_id=$(wezterm cli split-pane --pane-id "${panes[$from]}" \
                    "$([ "$dir" = down ] && echo --bottom || echo --right)" \
                    --cwd "$cwd" ${WZ_CMD[@]+"${WZ_CMD[@]}"} 2>/dev/null)
                panes+=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            N)
                [ -n "${panes[0]:-}" ] && cwterm_set_tab_title "${panes[0]}" "$a"
                ;;
            S)
                [ -n "${panes[0]:-}" ] && wezterm cli activate-pane --pane-id "${panes[0]}" 2>/dev/null
                ;;
        esac
    done
    return 0
}
