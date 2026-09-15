# shellcheck shell=bash
# cwterm_* comes from whichever adapter is loaded at run time; CW_TERM and the
# trap path are read by other files, and the trap must expand its path now.
# shellcheck disable=SC2154,SC2034,SC2064
# Terminal adapters: detection, loading, and the parts that are the same
# whatever terminal you use (the OSC 7 pane probe and the tty map).
#
# An adapter lives in lib/terminals/<id>.sh and defines:
#
#   cwterm_label            human name, e.g. "Ghostty"
#   cwterm_caps             space separated: env bounds tabtitle split type
#   cwterm_present()        0 when this terminal is running and controllable
#   cwterm_current()        0 when the calling shell is inside this terminal
#   cwterm_version()        version string, best effort
#   cwterm_launch()         start it and wait until it answers
#   cwterm_dump()           layout as TSV, see below
#   cwterm_find_pane(dir)   pane id currently reporting that directory
#   cwterm_bounds()         WB <windowIndex> <x> <y> <w> <h>
#   cwterm_apply_bounds()   <windowIndex> <x> <y> <w> <h>
#   cwterm_type()           <paneId> <text> <submit 0|1>
#   cwterm_build()          reads a plan on stdin, prints one created pane per
#                           line: <paneId> TAB <cwd> TAB <run> TAB <prefill>
#
# Layout TSV rows:
#   W <windowIndex> <windowId> <windowName>
#   T <windowIndex> <tabIndex> <selected> <focusedPaneId> <tabName>
#   S <windowIndex> <tabIndex> <paneId> <cwd> <title>
#
# Build plan rows (tab separated):
#   W <cwd> <run> <prefill>              start a window, this is its first pane
#   T <cwd> <run> <prefill>              start a tab in the current window
#   P <right|down> <from> <cwd> <run> <prefill>   split, from = pane index in tab
#   N <title>                            pin the current tab's title
#   S                                    the current tab is the selected one
#
# "run" is a command the pane should execute at its first prompt, "prefill" one
# it should type without executing. Adapters without the "env" capability get
# them typed in afterwards by restore.sh instead.

CW_TERMINALS="ghostty kitty wezterm iterm2 tmux"

# Adapters are plain sourced files, so anything one of them sets has to be
# cleared before the next is tried.
_terminal_reset() { CW_NATIVE_TTY_MAP=""; }

# The adapter id is optional; callers that omit it get detection.
# shellcheck disable=SC2120
terminal_load() {   # $1 optional adapter id
    local want=${1:-$CW_TERMINAL} id
    _terminal_reset
    if [ -n "$want" ]; then
        [ -f "$CW_LIB/terminals/$want.sh" ] || die "no terminal adapter named '''$want'''"
        # shellcheck disable=SC1090
        . "$CW_LIB/terminals/$want.sh"
        CW_TERM=$want
        return 0
    fi
    # Prefer the terminal this shell is running inside. tmux is asked first:
    # inside tmux the panes that matter are tmux's, even though TERM_PROGRAM
    # still names the GUI terminal underneath.
    for id in tmux $CW_TERMINALS; do
        [ -f "$CW_LIB/terminals/$id.sh" ] || continue
        _terminal_reset
        # shellcheck disable=SC1090
        . "$CW_LIB/terminals/$id.sh"
        if cwterm_current 2>/dev/null; then CW_TERM=$id; return 0; fi
    done
    for id in $CW_TERMINALS; do
        [ -f "$CW_LIB/terminals/$id.sh" ] || continue
        _terminal_reset
        # shellcheck disable=SC1090
        . "$CW_LIB/terminals/$id.sh"
        if cwterm_present 2>/dev/null; then CW_TERM=$id; return 0; fi
    done
    die "no supported terminal is running (looked for: $CW_TERMINALS)"
}

terminal_has() {   # $1 capability
    case " $cwterm_caps " in *" $1 "*) return 0 ;; esac
    return 1
}

# --- the OSC 7 pane probe --------------------------------------------------
# Terminals learn a pane's working directory from an OSC 7 sequence the shell
# writes at every prompt. Writing one directly to /dev/ttysNNN therefore makes
# the terminal believe that pane moved, and asking which pane reports a unique
# throwaway directory maps a tty to a pane id. The real directory is written
# back immediately, so the pane is unchanged a fraction of a second later.
report_pwd() {   # $1 tty, $2 directory
    printf '\033]7;kitty-shell-cwd://%s%s\a' "$(hostname)" "$2" > "/dev/$1" 2>/dev/null || return 0
}

tty_map() {   # TSV: tty  paneId
    local f
    for f in "$CW_TTY_DIR"/*; do
        [ -e "$f" ] || continue
        printf '%s\t%s\n' "${f##*/}" "$(cat "$f")"
    done
}

prune_tty_map() {
    local live f
    live=$(ps -axo tty= | tr -d ' ' | sort -u)
    for f in "$CW_TTY_DIR"/*; do
        [ -e "$f" ] || continue
        grep -qx -- "${f##*/}" <<<"$live" || rm -- "$f"
    done
}

# Learn one pane. Prints the pane id it found, and remembers it.
cmd_register_self() {   # $1 tty, $2 cwd
    local tty=${1#/dev/} cwd=$2 nonce dir pane
    terminal_load
    [ -c "/dev/$tty" ] || return 0
    cwterm_present || return 0
    if [ -n "${CW_NATIVE_TTY_MAP:-}" ]; then
        # The terminal can tell us directly; no probe needed.
        pane=$(cwterm_pane_for_tty "$tty") || pane=""
        [ -n "$pane" ] || return 0
        printf '%s' "$pane" > "$CW_TTY_DIR/$tty"
        printf '%s\n' "$pane"
        return 0
    fi
    nonce=$(uuidgen | tr '[:upper:]' '[:lower:]')
    dir=$CW_NONCE_DIR/$nonce
    mkdir -p "$dir"
    # Expanded now: the trap fires after this function's locals are gone.
    trap "rmdir '$dir' 2>/dev/null" EXIT
    report_pwd "$tty" "$dir"
    sleep 0.1
    pane=$(cwterm_find_pane "$dir")
    if [ -z "$pane" ]; then
        sleep 0.4
        pane=$(cwterm_find_pane "$dir")
    fi
    report_pwd "$tty" "$cwd"
    [ -n "$pane" ] || return 0
    printf '%s' "$pane" > "$CW_TTY_DIR/$tty"
    printf '%s\n' "$pane"
}

# The working directory of the shell on a tty, read from the process itself.
# Used to repair a pane whose recorded directory is a leftover probe path.
shell_cwd_of_tty() {   # $1 tty
    local pid
    pid=$(ps -axo pid=,tty=,comm= | awk -v t="$1" '$2 == t && $3 ~ /(zsh|bash|fish|sh)$/ { print $1 }' | sort -n | sed -n '1p')
    [ -n "$pid" ] || return 0
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# Learn every pane at once. Used by `install` and after big layout changes.
cmd_map() {
    local before after ttys tty nonce dir pane prev mapped=0 total=0 pending=""
    terminal_load
    cwterm_present || die "$cwterm_label is not running"
    if [ -n "${CW_NATIVE_TTY_MAP:-}" ]; then
        while IFS=$CW_US read -r tty pane; do
            [ -n "$tty" ] || continue
            printf '%s' "$pane" > "$CW_TTY_DIR/$tty"
            mapped=$((mapped + 1)); total=$((total + 1))
        done < <(cwterm_tty_pairs | tr '\t' "$CW_US")
        say "mapped $mapped of $total panes ($cwterm_label reports ttys itself)"
        return 0
    fi
    before=$(cwterm_dump)
    ttys=$(cwterm_ttys)
    [ -n "$ttys" ] || die "no $cwterm_label panes found"
    for tty in $ttys; do
        nonce=$(uuidgen | tr '[:upper:]' '[:lower:]')
        dir=$CW_NONCE_DIR/$nonce
        mkdir -p "$dir"
        report_pwd "$tty" "$dir"
        pending+="$tty$CW_US$dir"$'\n'
        total=$((total + 1))
    done
    sleep 0.5
    after=$(cwterm_dump)
    while IFS=$CW_US read -r tty dir; do
        [ -n "$tty" ] || continue
        pane=$(awk -F'\t' -v d="$dir" '$1 == "S" && $5 == d { print $4; exit }' <<<"$after")
        if [ -n "$pane" ]; then
            prev=$(awk -F'\t' -v id="$pane" '$1 == "S" && $4 == id { print $5; exit }' <<<"$before")
            case $prev in "$CW_NONCE_DIR"/*|"") prev=$(shell_cwd_of_tty "$tty") ;; esac
            [ -n "$prev" ] && report_pwd "$tty" "$prev"
            printf '%s' "$pane" > "$CW_TTY_DIR/$tty"
            mapped=$((mapped + 1))
        else
            log "$tty: $cwterm_label did not report the probe; left unmapped"
        fi
        rmdir "$dir" 2>/dev/null || true
    done <<<"$pending"
    say "mapped $mapped of $total panes"
}

# A pane is ready when its shell has reached a prompt: either it has registered
# itself, or the terminal shows the shell's own title rather than a program's.
pane_is_ready() {   # $1 paneId, $2 cwd, $3 layout TSV
    grep -lqx -- "$1" "$CW_TTY_DIR"/* 2>/dev/null && return 0
    local title
    title=$(awk -F'\t' -v id="$1" '$1 == "S" && $4 == id { print $6; exit }' <<<"$3")
    [ "$title" = "$(short "$2")" ] || [ "$title" = "$2" ]
}

wait_ready() {   # $1 paneId, $2 cwd
    local i live
    for (( i = 0; i < CW_READY_TIMEOUT * 2; i++ )); do
        live=$(cwterm_dump)
        pane_is_ready "$1" "$2" "$live" && return 0
        sleep 0.5
    done
    return 1
}

# The screens this machine has, so a restore can keep a window on one of them.
screen_frames() {
    osascript -l JavaScript -e 'ObjC.import("AppKit"); JSON.stringify($.NSScreen.screens.js.map(function (s) { var f = s.visibleFrame; return {x: Math.round(f.origin.x), y: Math.round(f.origin.y), w: Math.round(f.size.width), h: Math.round(f.size.height)}; }))' 2>/dev/null || printf '[]'
}

cmd_terminals() {
    local id label present current
    for id in $CW_TERMINALS; do
        [ -f "$CW_LIB/terminals/$id.sh" ] || { printf '%-9s %-22s not in this build\n' "$id" ""; continue; }
        # shellcheck disable=SC1090
        ( . "$CW_LIB/terminals/$id.sh"
          present=no; current=no
          cwterm_present 2>/dev/null && present=yes
          cwterm_current 2>/dev/null && current=yes
          label=$cwterm_label
          printf '%-9s %-10s running: %-4s active: %-4s %-26s %s\n' \
              "$id" "$label" "$present" "$current" "${cwterm_verified:-unverified}" "$cwterm_caps" )
    done
    printf '\nThe adapter is chosen by which terminal this shell runs inside, then by\n'
    printf 'which one is running. Force one with CW_TERMINAL in %s.\n' "$(short "$CW_CONFIG_FILE")"
}
