# shellcheck shell=bash
# cwterm_* values are read by the loader in lib/terminal.sh.
# shellcheck disable=SC2034
# tmux adapter. A tmux session maps to a window, a tmux window to a tab and a
# tmux pane to a pane. tmux reports each pane's tty itself, so the OSC 7 probe
# the GUI terminals need is skipped entirely.

cwterm_label="tmux"
cwterm_caps="env tabtitle split type"
cwterm_verified="verified against tmux 3.7"
CW_NATIVE_TTY_MAP=1

_tm() { tmux "$@"; }

cwterm_present() { command -v tmux >/dev/null 2>&1 && tmux has-session 2>/dev/null; }
cwterm_current() { [ -n "${TMUX:-}" ] && cwterm_present; }
cwterm_version() { tmux -V 2>/dev/null | sed 's/^tmux //'; }

# tmux gained `-e` (environment for a new pane) in 3.2.
_tm_has_env() {
    local v
    v=$(cwterm_version | sed 's/[^0-9.].*$//')
    [ -n "$v" ] || return 1
    awk -v v="$v" 'BEGIN { split(v, a, "."); exit !((a[1] > 3) || (a[1] == 3 && a[2] >= 2)) }'
}

cwterm_launch() {
    command -v tmux >/dev/null 2>&1 || die "tmux is not installed"
    cwterm_present && return 0
    return 0   # a session is created by the build itself
}

cwterm_start_epoch() {
    local pid
    pid=$(_tm display-message -p '#{pid}' 2>/dev/null) || return 1
    [ -n "$pid" ] || return 1
    date -j -f '%a %b %d %H:%M:%S %Y' "$(ps -o lstart= -p "$pid" | sed 's/ *$//')" '+%s' 2>/dev/null
}

cwterm_dump() {
    local sess wi=0
    while IFS= read -r sess; do
        [ -n "$sess" ] || continue
        wi=$((wi + 1))
        printf 'W\t%s\t%s\t%s\n' "$wi" "$sess" "$sess"
        _tm list-windows -t "$sess" -F '#{window_index}	#{window_active}	#{window_name}	#{pane_id}' 2>/dev/null |
            while IFS=$'\t' read -r widx active wname firstpane; do
                printf 'T\t%s\t%s\t%s\t%s\t%s\n' "$wi" "$widx" \
                    "$([ "$active" = 1 ] && echo true || echo false)" "$firstpane" "$wname"
            done
        _tm list-panes -s -t "$sess" -F '#{window_index}	#{pane_id}	#{pane_current_path}	#{pane_title}' 2>/dev/null |
            while IFS=$'\t' read -r widx pid path title; do
                printf 'S\t%s\t%s\t%s\t%s\t%s\n' "$wi" "$widx" "$pid" "$path" "$title"
            done
    done < <(_tm list-sessions -F '#{session_name}' 2>/dev/null)
}

cwterm_find_pane() {   # $1 directory
    _tm list-panes -a -F '#{pane_current_path}	#{pane_id}' 2>/dev/null |
        awk -F'\t' -v d="$1" '$1 == d { print $2; exit }'
}

cwterm_tty_pairs() {   # TSV: tty  paneId
    _tm list-panes -a -F '#{pane_tty}	#{pane_id}' 2>/dev/null |
        awk -F'\t' '{ sub("^/dev/", "", $1); print $1 "\t" $2 }'
}

cwterm_pane_for_tty() {   # $1 tty
    cwterm_tty_pairs | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'
}

cwterm_ttys() { cwterm_tty_pairs | cut -f1; }

cwterm_type() {   # $1 paneId, $2 text, $3 submit
    _tm send-keys -t "$1" -l -- "$2"
    [ "${3:-1}" = 1 ] && _tm send-keys -t "$1" Enter
    return 0
}

cwterm_set_tab_title() {   # $1 paneId, $2 title
    local win
    win=$(_tm display-message -p -t "$1" '#{session_name}:#{window_index}' 2>/dev/null) || return 0
    _tm set-option -w -t "$win" automatic-rename off 2>/dev/null || true
    _tm rename-window -t "$win" "$2" 2>/dev/null || true
}

# tmux panes have no screen geometry of their own.
cwterm_bounds() { :; }
cwterm_apply_bounds() { :; }

# Fills TM_ENV with the -e flags for a new pane. Kept as an array so values
# with spaces survive; tmux before 3.2 has no -e, and those panes get the
# command typed in by restore.sh instead.
_tm_env() {   # $1 run, $2 prefill
    TM_ENV=()
    _tm_has_env || return 0
    [ -n "$1" ] && TM_ENV+=(-e "$CW_ENV_RUN=$1")
    [ -n "$2" ] && TM_ENV+=(-e "$CW_ENV_PREFILL=$2")
    return 0
}

_tm_free_session_name() {   # $1 wanted name
    local base=${1:-workspace} name=$1 n=2
    [ -n "$name" ] || name=$base
    while _tm has-session -t "=$name" 2>/dev/null; do
        name="$base-$n"; n=$((n + 1))
    done
    printf '%s' "$name"
}

cwterm_build() {
    local line kind a b c d e cwd run prefill dir from
    local sess="" win="" pane_id
    local -a panes=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$CW_US read -r kind a b c d e <<<"$line"
        case $kind in
            W)
                cwd=$a; run=$b; prefill=$c
                sess=$(_tm_free_session_name "$(basename "$cwd")")
                panes=()
                _tm_env "$run" "$prefill"
                pane_id=$(_tm new-session -d -P -F '#{pane_id}' -s "$sess" -c "$cwd" ${TM_ENV[@]+"${TM_ENV[@]}"})
                win=$(_tm display-message -p -t "$pane_id" '#{session_name}:#{window_index}')
                panes=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            T)
                cwd=$a; run=$b; prefill=$c
                panes=()
                _tm_env "$run" "$prefill"
                pane_id=$(_tm new-window -d -P -F '#{pane_id}' -t "$sess:" -c "$cwd" ${TM_ENV[@]+"${TM_ENV[@]}"})
                win=$(_tm display-message -p -t "$pane_id" '#{session_name}:#{window_index}')
                panes=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            P)
                dir=$a; from=$b; cwd=$c; run=$d; prefill=$e
                _tm_env "$run" "$prefill"
                pane_id=$(_tm split-window -d -P -F '#{pane_id}' -t "${panes[$from]}" \
                    "$([ "$dir" = down ] && echo -v || echo -h)" -c "$cwd" ${TM_ENV[@]+"${TM_ENV[@]}"})
                panes+=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$CW_US" "$cwd" "$CW_US" "$run" "$CW_US" "$prefill"
                ;;
            N)
                [ -n "$win" ] || continue
                _tm set-option -w -t "$win" automatic-rename off 2>/dev/null || true
                _tm rename-window -t "$win" "$a" 2>/dev/null || true
                ;;
            S)
                if [ -n "$win" ]; then _tm select-window -t "$win" 2>/dev/null || true; fi
                ;;
        esac
    done
    [ -n "$sess" ] && log "tmux session '$sess' is ready; attach with: tmux attach -t $sess"
    return 0
}
