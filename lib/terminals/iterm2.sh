# shellcheck shell=bash
# term_* values are read by the loader in lib/terminal.sh.
# shellcheck disable=SC2034
# iTerm2 adapter, written from the AppleScript documentation and not yet
# exercised against a running iTerm2. `paneful terminals` says so.
#
# iTerm2's AppleScript exposes each session's tty, which makes the pane map
# exact with no probe. What it does not expose is a starting directory or an
# environment for a new session, so a new pane is sent a `cd` first and its
# command is typed in afterwards rather than handed over in the environment.
#
# Needs "Enable AppleScript" in iTerm2's preferences, and macOS Automation
# permission for whatever is running paneful.

term_label="iTerm2"
term_caps="tabtitle split type"
term_verified="from documentation"
PANEFUL_NATIVE_TTY_MAP=1

term_present() { osascript -e 'tell application "iTerm2" to count windows' >/dev/null 2>&1; }
term_current() { [ -n "${ITERM_SESSION_ID:-}" ] && term_present; }
term_version() { osascript -e 'tell application "iTerm2" to get version' 2>/dev/null; }
term_start_epoch() {
    local pid
    pid=$(ps -axo pid=,comm= | awk '$2 ~ /iTerm2$/ { print $1 }' | sed -n '1p')
    [ -n "$pid" ] || return 1
    date -j -f '%a %b %d %H:%M:%S %Y' "$(ps -o lstart= -p "$pid" | sed 's/ *$//')" '+%s' 2>/dev/null
}
term_launch() {
    term_present && return 0
    open -a iTerm
    local i
    for (( i = 0; i < 40; i++ )); do sleep 0.5; term_present && return 0; done
    die "iTerm2 did not answer AppleScript (is AppleScript enabled in its preferences?)"
}

# iTerm2 reports a session's tty but not its working directory, so the
# directory is read from the shell on that tty instead.
term_dump() {
    local raw wi ti id tty cwd title
    raw=$(osa 15 <<'APPLESCRIPT'
set tabChar to character id 9
set out to ""
tell application "iTerm2"
    set wi to 0
    repeat with w in windows
        set wi to wi + 1
        set out to out & "W" & tabChar & wi & tabChar & (id of w) & tabChar & (name of w) & linefeed
        set ti to 0
        repeat with t in tabs of w
            set ti to ti + 1
            set out to out & "T" & tabChar & wi & tabChar & ti & tabChar & "false" & tabChar & (unique id of (current session of t)) & tabChar & (name of (current session of t)) & linefeed
            repeat with s in sessions of t
                set out to out & "S" & tabChar & wi & tabChar & ti & tabChar & (unique id of s) & tabChar & (tty of s) & tabChar & (name of s) & linefeed
            end repeat
        end repeat
    end repeat
end tell
return out
APPLESCRIPT
) || return 1
    # Swap each pane's tty for the directory its shell is standing in.
    while IFS=$'\t' read -r kind wi ti id tty title; do
        if [ "$kind" = S ]; then
            cwd=$(shell_cwd_of_tty "${tty#/dev/}")
            printf 'S\t%s\t%s\t%s\t%s\t%s\n' "$wi" "$ti" "$id" "$cwd" "$title"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$wi" "$ti" "$id" "$tty" "$title"
        fi
    done <<<"$raw"
}

term_tty_pairs() {
    osa 15 <<'APPLESCRIPT' | awk -F'\t' '{ sub("^/dev/", "", $1); print $1 "\t" $2 }'
set tabChar to character id 9
set out to ""
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                set out to out & (tty of s) & tabChar & (unique id of s) & linefeed
            end repeat
        end repeat
    end repeat
end tell
return out
APPLESCRIPT
}
term_pane_for_tty() { term_tty_pairs | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'; }
term_ttys() { term_tty_pairs | cut -f1; }
term_find_pane() { term_dump | awk -F'\t' -v d="$1" '$1 == "S" && $5 == d { print $4; exit }'; }

term_type() {   # $1 paneId, $2 text, $3 submit
    osa 30 <<EOF >/dev/null
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if (unique id of s) is $(as_str "$1") then
                    write s text $(as_str "$2") newline $([ "${3:-1}" = 1 ] && echo yes || echo no)
                    return
                end if
            end repeat
        end repeat
    end repeat
end tell
EOF
}

term_set_tab_title() {   # $1 paneId, $2 title
    osa 10 <<EOF >/dev/null
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if (unique id of s) is $(as_str "$1") then
                    set name of s to $(as_str "$2")
                    return
                end if
            end repeat
        end repeat
    end repeat
end tell
EOF
}

# Geometry is not reachable from iTerm2's AppleScript dictionary.
term_bounds() { :; }
term_apply_bounds() { :; }

_it_create() {   # $1 kind (window|tab|right|down), $2 fromPaneId, $3 cwd -> new pane id
    local script
    case $1 in
        window) script='set s to current session of (create window with default profile)' ;;
        tab) script='set s to current session of (create tab with default profile)' ;;
        right) script="set s to (split vertically with default profile)" ;;
        down) script="set s to (split horizontally with default profile)" ;;
    esac
    osa 60 <<EOF
tell application "iTerm2"
    activate
    $( [ "$1" = tab ] && printf 'tell current window\n' )
    $( case $1 in right|down) printf 'repeat with w in windows\n repeat with t in tabs of w\n repeat with x in sessions of t\n if (unique id of x) is %s then\n tell x\n' "$(as_str "$2")" ;; esac )
    $script
    $( case $1 in right|down) printf 'end tell\n exit repeat\n end if\n end repeat\n end repeat\n end repeat\n' ;; esac )
    $( [ "$1" = tab ] && printf 'end tell\n' )
    tell s to write text $(as_str "cd $(printf '%q' "$3") && clear")
    return (unique id of s)
end tell
EOF
}

term_build() {
    local line kind a b c d e cwd run prefill dir from pane_id
    local -a panes=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$PANEFUL_US read -r kind a b c d e <<<"$line"
        case $kind in
            W|T)
                cwd=$a; run=$b; prefill=$c
                panes=()
                pane_id=$(_it_create "$([ "$kind" = W ] && echo window || echo tab)" "" "$cwd")
                panes=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$PANEFUL_US" "$cwd" "$PANEFUL_US" "$run" "$PANEFUL_US" "$prefill"
                ;;
            P)
                dir=$a; from=$b; cwd=$c; run=$d; prefill=$e
                pane_id=$(_it_create "$dir" "${panes[$from]}" "$cwd")
                panes+=("$pane_id")
                printf '%s%s%s%s%s%s%s\n' "$pane_id" "$PANEFUL_US" "$cwd" "$PANEFUL_US" "$run" "$PANEFUL_US" "$prefill"
                ;;
            N)
                [ -n "${panes[0]:-}" ] && term_set_tab_title "${panes[0]}" "$a"
                ;;
        esac
    done
    return 0
}
