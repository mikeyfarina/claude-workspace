# shellcheck shell=bash
# cwterm_* values are read by the loader in lib/terminal.sh.
# shellcheck disable=SC2034
# kitty adapter, written from the remote-control documentation at
# https://sw.kovidgoyal.net/kitty/remote-control/ and not yet exercised against
# a running kitty. `claude-workspace terminals` says as much.
#
# kitty is the friendliest of the GUI terminals here: `kitten @ ls` reports the
# pid of every pane, so the tty comes straight from ps and the OSC 7 probe the
# other terminals need is skipped, and `launch` takes both --cwd and --env.
#
# Requires in kitty.conf:
#     allow_remote_control yes
#     listen_on unix:/tmp/kitty

cwterm_label="kitty"
cwterm_caps="env tabtitle split type"
cwterm_verified="from documentation"
CW_NATIVE_TTY_MAP=1

# Current kitty documents `kitten @`; older builds used `kitty @`.
_ky() {
    if command -v kitten >/dev/null 2>&1; then kitten @ "$@"; else kitty @ "$@"; fi
}

cwterm_present() {
    command -v kitten >/dev/null 2>&1 || command -v kitty >/dev/null 2>&1 || return 1
    _ky ls >/dev/null 2>&1
}
cwterm_current() { [ -n "${KITTY_WINDOW_ID:-}" ] && cwterm_present; }
cwterm_version() {
    if command -v kitty >/dev/null 2>&1; then kitty --version 2>/dev/null | awk '{print $2; exit}'; fi
}
cwterm_start_epoch() {
    local pid
    pid=$(ps -axo pid=,comm= | awk '$2 ~ /kitty$/ { print $1 }' | sed -n '1p')
    [ -n "$pid" ] || return 1
    date -j -f '%a %b %d %H:%M:%S %Y' "$(ps -o lstart= -p "$pid" | sed 's/ *$//')" '+%s' 2>/dev/null
}
cwterm_launch() {
    cwterm_present && return 0
    command -v kitty >/dev/null 2>&1 || die "kitty is not installed"
    open -a kitty 2>/dev/null || kitty >/dev/null 2>&1 &
    local i
    for (( i = 0; i < 40; i++ )); do sleep 0.5; cwterm_present && return 0; done
    die "kitty did not answer remote control (is allow_remote_control set?)"
}

cwterm_dump() {
    _ky ls 2>/dev/null | jq -r '
        to_entries[] | (.key + 1) as $wi | .value as $w
        | ("W\t\($wi)\t\($w.id)\t\($w.tabs[0].title // "")"),
          ( $w.tabs | to_entries[] | (.key + 1) as $ti | .value as $t
            | ("T\t\($wi)\t\($ti)\t\($t.is_focused // false)\t\($t.active_window_id // ($t.windows[0].id // ""))\t\($t.title // "")"),
              ( $t.windows[] | "S\t\($wi)\t\($ti)\t\(.id)\t\(.cwd // "")\t\(.title // "")" ) )'
}

cwterm_find_pane() {   # $1 directory
    _ky ls 2>/dev/null | jq -r --arg d "$1" '
        [.[].tabs[].windows[] | select(.cwd == $d) | .id] | .[0] // empty'
}

cwterm_tty_pairs() {   # kitty reports each pane's pid, which is better than a probe
    local pid id tty
    while IFS=$'\t' read -r id pid; do
        [ -n "$pid" ] || continue
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$tty" ] && [ "$tty" != "??" ] && printf '%s\t%s\n' "$tty" "$id"
    done < <(_ky ls 2>/dev/null | jq -r '.[].tabs[].windows[] | "\(.id)\t\(.pid // "")"')
}
cwterm_pane_for_tty() { cwterm_tty_pairs | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'; }
cwterm_ttys() { cwterm_tty_pairs | cut -f1; }

cwterm_type() {   # $1 paneId, $2 text, $3 submit
    if [ "${3:-1}" = 1 ]; then
        _ky send-text --match "id:$1" -- "$2"$'\r'
    else
        _ky send-text --match "id:$1" -- "$2"
    fi
}

cwterm_set_tab_title() { _ky set-tab-title --match "id:$1" -- "$2"; }

# kitty can size and place a window only as it is created, and cannot report
# an existing window's geometry, so geometry is left alone.
cwterm_bounds() { :; }
cwterm_apply_bounds() { :; }

_ky_env_args() {   # $1 run, $2 prefill -> fills KY_ENV
    KY_ENV=()
    [ -n "$1" ] && KY_ENV+=(--env "$CW_ENV_RUN=$1")
    [ -n "$2" ] && KY_ENV+=(--env "$CW_ENV_PREFILL=$2")
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
                _ky_env_args "$run" "$prefill"
                pane_id=$(_ky launch --type "$([ "$kind" = W ] && echo os-window || echo tab)" \
                    --cwd "$cwd" ${KY_ENV[@]+"${KY_ENV[@]}"} 2>/dev/null)
                panes=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            P)
                dir=$a; from=$b; cwd=$c; run=$d; prefill=$e
                _ky_env_args "$run" "$prefill"
                pane_id=$(_ky launch --type window --location "$([ "$dir" = down ] && echo hsplit || echo vsplit)" \
                    --match "id:${panes[$from]}" --cwd "$cwd" ${KY_ENV[@]+"${KY_ENV[@]}"} 2>/dev/null)
                panes+=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            N)
                [ -n "${panes[0]:-}" ] && _ky set-tab-title --match "id:${panes[0]}" -- "$a" 2>/dev/null
                ;;
            S)
                [ -n "${panes[0]:-}" ] && _ky focus-window --match "id:${panes[0]}" 2>/dev/null
                ;;
        esac
    done
    return 0
}
