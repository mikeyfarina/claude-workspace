# shellcheck shell=bash
# Cursor CLI (cursor-agent).
#
# The launcher execs node, so `ps` shows the process as "node" and only the
# full command line still carries the giveaway path. There is no pid -> chat
# registry and no documented on-disk chat location to read an id from, so this
# provider does not invent one: it recognises the pane and reopens the latest
# chat from the same directory.

provider_cursor_label() { printf 'Cursor CLI'; }
provider_cursor_available() { command -v cursor-agent >/dev/null 2>&1; }
provider_cursor_live() { provider_cursor_available; }

provider_cursor_list() {
    local tty cwd pid
    while IFS=$'\t' read -r tty cwd pid _; do
        [ -n "$tty" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$(provider_dir_id cursor "$cwd")" "$cwd" "cursor-agent ${cwd##*/}" "$pid"
    done < <(provider_procs 'cursor-agent(/versions/[^ ]*)?( |$)|cursor-agent/versions')
}

provider_cursor_resume() {
    # Chat ids are not uuid-shaped and are not discoverable from outside, so an
    # id is only used when something else supplied a real one.
    case $1 in cursor:*|"") printf 'cursor-agent resume' ;; *) printf 'cursor-agent --resume %s' "$1" ;; esac
}
provider_cursor_resume_last() { printf 'cursor-agent resume'; }
