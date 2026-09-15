# shellcheck shell=bash
# opencode.
#
# Each instance runs a server on a random port with no discovery file, so there
# is nothing to read a session id from. A pane is recognised by process and
# directory and reopened with --continue from that directory. Resuming by id is
# supported when an id is known, but opencode has been reported to sometimes
# start in the launch directory rather than the session's own, which is why the
# pane is always recreated in the right directory first.

provider_opencode_label() { printf 'opencode'; }
provider_opencode_available() { command -v opencode >/dev/null 2>&1; }
provider_opencode_live() { provider_opencode_available; }

provider_opencode_list() {
    local tty cwd pid
    while IFS=$'\t' read -r tty cwd pid _; do
        [ -n "$tty" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$(provider_dir_id opencode "$cwd")" "$cwd" "opencode ${cwd##*/}" "$pid"
    done < <(provider_procs '(^| |/)opencode( |$)')
}

provider_opencode_resume() {
    case $1 in opencode:*|"") printf 'opencode --continue' ;; *) printf 'opencode --session %s' "$1" ;; esac
}
provider_opencode_resume_last() { printf 'opencode --continue'; }
