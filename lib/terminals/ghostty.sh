# shellcheck shell=bash
# cwterm_* values are read by the loader in lib/terminal.sh.
# shellcheck disable=SC2034
# Ghostty adapter. Uses the AppleScript dictionary shipped in Ghostty 1.3,
# which exposes windows > tabs > terminals with stable ids, and can create
# windows, tabs and splits with a starting directory and environment.

cwterm_label="Ghostty"
cwterm_caps="env bounds tabtitle split type"
cwterm_verified="verified against Ghostty 1.3"

_gt_app=""
_gt_exe=""

_gt_paths() {
    [ -n "$_gt_exe" ] && return 0
    _gt_app=$(osascript -e 'POSIX path of (path to application id "com.mitchellh.ghostty")' 2>/dev/null) || _gt_app=""
    [ -n "$_gt_app" ] || _gt_app=/Applications/Ghostty.app/
    _gt_exe=${GHOSTTY_BIN_DIR:-${_gt_app%/}/Contents/MacOS}/ghostty
}

_gt_pid() {
    _gt_paths
    # No early exit in awk: under pipefail a SIGPIPE'd ps fails the whole call.
    ps -axo pid=,comm= | awk -v exe="$_gt_exe" '$2 == exe { print $1 }' | sed -n '1p'
}

cwterm_present() { [ -n "$(_gt_pid)" ]; }
cwterm_current() { [ "${TERM_PROGRAM:-}" = ghostty ] && cwterm_present; }

cwterm_version() {
    if [ -n "${TERM_PROGRAM_VERSION:-}" ] && [ "${TERM_PROGRAM:-}" = ghostty ]; then
        printf '%s' "$TERM_PROGRAM_VERSION"
        return 0
    fi
    _gt_paths
    [ -x "$_gt_exe" ] && "$_gt_exe" +version 2>/dev/null | sed -n '1s/^Ghostty //p'
}

# When Ghostty itself restored the layout, this is the launch we are restoring
# into; the epoch tells a snapshot whether it predates the running instance.
cwterm_start_epoch() {
    local pid lstart
    pid=$(_gt_pid) || return 1
    [ -n "$pid" ] || return 1
    lstart=$(ps -o lstart= -p "$pid" | sed 's/ *$//')
    date -j -f '%a %b %d %H:%M:%S %Y' "$lstart" '+%s' 2>/dev/null
}

cwterm_launch() {
    cwterm_present && return 0
    log "starting Ghostty"
    open -a Ghostty
    local i
    for (( i = 0; i < 40; i++ )); do
        sleep 0.5
        osascript -e 'tell application "Ghostty" to count of windows' >/dev/null 2>&1 && return 0
    done
    die "Ghostty did not become scriptable"
}

cwterm_dump() {
    osa 15 <<'APPLESCRIPT'
-- inside a Ghostty tell block the word "tab" is the tab class, not a character
set tabChar to character id 9
tell application "Ghostty"
    set out to ""
    set wi to 0
    repeat with w in windows
        set wi to wi + 1
        set out to out & "W" & tabChar & wi & tabChar & (id of w) & tabChar & (name of w) & linefeed
        repeat with t in tabs of w
            set ft to ""
            try
                set ft to id of (focused terminal of t)
            end try
            set out to out & "T" & tabChar & wi & tabChar & (index of t) & tabChar & (selected of t) & tabChar & ft & tabChar & (name of t) & linefeed
            repeat with s in terminals of t
                set cwd to ""
                try
                    set cwd to working directory of s
                end try
                if cwd is missing value then set cwd to ""
                set out to out & "S" & tabChar & wi & tabChar & (index of t) & tabChar & (id of s) & tabChar & cwd & tabChar & (name of s) & linefeed
            end repeat
        end repeat
    end repeat
    return out
end tell
APPLESCRIPT
}

cwterm_find_pane() {   # $1 directory
    osa 5 <<EOF
tell application "Ghostty"
    repeat with s in terminals
        try
            if (working directory of s) is $(as_str "$1") then return id of s
        end try
    end repeat
    return ""
end tell
EOF
}

cwterm_ttys() {
    local pid
    pid=$(_gt_pid)
    [ -n "$pid" ] || return 0
    ps -axo ppid=,tty= | awk -v g="$pid" '$1 == g && $2 != "??" { print $2 }' | sort -u
}

cwterm_type() {   # $1 paneId, $2 text, $3 submit 0|1
    {
        printf 'tell application "Ghostty"\n'
        printf '    input text %s to terminal id %s\n' "$(as_str "$2")" "$(as_str "$1")"
        [ "${3:-1}" = 1 ] && printf '    send key "enter" to terminal id %s\n' "$(as_str "$1")"
        printf 'end tell\n'
    } | osa 30 >/dev/null
}

cwterm_set_tab_title() {   # $1 paneId, $2 title
    osa 10 <<EOF >/dev/null
tell application "Ghostty" to perform action $(as_str "set_tab_title:$2") on terminal id $(as_str "$1")
EOF
}

# Ghostty's dictionary does not expose window geometry, so this reads and
# writes it through the Accessibility API. Silent when permission is missing.
cwterm_bounds() {
    osascript <<'APPLESCRIPT' 2>/dev/null || true
set tabChar to character id 9
set out to ""
tell application "System Events"
    if not (exists process "Ghostty") then return ""
    tell process "Ghostty"
        set i to 0
        repeat with w in windows
            set i to i + 1
            try
                set p to position of w
                set z to size of w
                set out to out & "WB" & tabChar & i & tabChar & (item 1 of p) & tabChar & (item 2 of p) & tabChar & (item 1 of z) & tabChar & (item 2 of z) & linefeed
            end try
        end repeat
    end tell
end tell
return out
APPLESCRIPT
}

cwterm_apply_bounds() {   # $1 window index (frontmost is 1), $2 x, $3 y, $4 w, $5 h
    osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
    if not (exists process "Ghostty") then return
    tell process "Ghostty"
        if (count of windows) < $1 then return
        set position of window $1 to {$2, $3}
        set size of window $1 to {$4, $5}
    end tell
end tell
APPLESCRIPT
}

_gt_config() {   # $1 cwd, $2 run, $3 prefill
    local cfg env=""
    cfg="{initial working directory:$(as_str "$1")"
    [ -n "$2" ] && env="$(as_str "$CW_ENV_RUN=$2")"
    if [ -n "$3" ]; then
        [ -n "$env" ] && env="$env, "
        env="$env$(as_str "$CW_ENV_PREFILL=$3")"
    fi
    [ -n "$env" ] && cfg="$cfg, environment variables:{$env}"
    printf '%s}' "$cfg"
}

cwterm_build() {
    local plan chunk line kind
    plan=$(cat)
    # One AppleScript per window keeps each run inside a sane timeout.
    local -a windows=()
    chunk=""
    while IFS= read -r line; do
        kind=${line%%"$CW_US"*}
        if [ "$kind" = W ] && [ -n "$chunk" ]; then
            windows+=("$chunk"); chunk=""
        fi
        chunk+="$line"$'\n'
    done <<<"$plan"
    [ -n "$chunk" ] && windows+=("$chunk")

    local w
    for w in "${windows[@]}"; do
        _gt_build_window "$w"
    done
}

_gt_build_window() {   # $1 plan chunk for one window
    local line kind cwd run prefill dir from title
    local script='tell application "Ghostty"'$'\n    set out to ""\n'
    local -a meta=()
    local pane=0 tabno=0 sel=1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$CW_US read -r kind a b c d e <<<"$line"
        case $kind in
            W)
                cwd=$a; run=$b; prefill=$c; pane=0; tabno=1
                script+="    set w to new window with configuration $(_gt_config "$cwd" "$run" "$prefill")"$'\n'
                script+="    set tb to tab 1 of w"$'\n'
                script+="    set s0 to terminal 1 of tb"$'\n'
                script+="    set out to out & (id of s0) & linefeed"$'\n    delay 0.25\n'
                meta+=("$cwd$CW_US$run$CW_US$prefill")
                ;;
            T)
                cwd=$a; run=$b; prefill=$c; pane=0; tabno=$((tabno + 1))
                script+="    set tb to new tab in w with configuration $(_gt_config "$cwd" "$run" "$prefill")"$'\n'
                script+="    set s0 to terminal 1 of tb"$'\n'
                script+="    set out to out & (id of s0) & linefeed"$'\n    delay 0.25\n'
                meta+=("$cwd$CW_US$run$CW_US$prefill")
                ;;
            P)
                dir=$a; from=$b; cwd=$c; run=$d; prefill=$e; pane=$((pane + 1))
                script+="    set s$pane to split s$from direction $dir with configuration $(_gt_config "$cwd" "$run" "$prefill")"$'\n'
                script+="    set out to out & (id of s$pane) & linefeed"$'\n    delay 0.25\n'
                meta+=("$cwd$CW_US$run$CW_US$prefill")
                ;;
            N)
                title=$a
                script+="    perform action $(as_str "set_tab_title:$title") on s0"$'\n'
                ;;
            S)
                sel=$tabno
                ;;
        esac
    done <<<"$1"
    # "select tab" is the command name, so its argument has to be a variable
    # holding the tab: `select tab 1 of w` does not even parse.
    script+="    try"$'\n'
    script+="        set tb to tab $sel of w"$'\n'
    script+="        select tab tb"$'\n'
    script+="    end try"$'\n'
    script+='    return out'$'\n''end tell'

    local ids i=0
    ids=$(osa 300 <<<"$script") || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s%s%s\n' "$line" "$CW_US" "${meta[$i]}"
        i=$((i + 1))
    done <<<"$ids"
}
