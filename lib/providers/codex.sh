# shellcheck shell=bash
# OpenAI Codex CLI.
#
# Codex keeps no live pid -> session map, so a running pane is found by its
# process and working directory. The exact conversation id can usually still be
# recovered: every session appends to a rollout file under ~/.codex/sessions,
# and the first line of that file records the session id and the directory it
# was started in. The newest rollout for this pane's directory that was created
# after the process started is that pane's session.

provider_codex_label() { printf 'Codex CLI'; }
provider_codex_available() { command -v codex >/dev/null 2>&1; }
provider_codex_live() { provider_codex_available; }

_codex_home() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }

# The session id of the newest rollout started in $1 at or after epoch $2.
_codex_session_for() {   # $1 cwd, $2 process start epoch
    local dir f cwd id
    dir=$(_codex_home)/sessions
    [ -d "$dir" ] || return 0
    while read -r f; do
        [ -n "$f" ] || continue
        # A rollout written before the process started belongs to an older run.
        [ "$(stat -f %B "$f" 2>/dev/null || echo 0)" -ge "$(( ${2:-0} - 5 ))" ] || continue
        IFS=$'\t' read -r cwd id <<<"$(head -1 "$f" 2>/dev/null |
            jq -r 'select(.type == "session_meta") | [.payload.cwd, (.payload.session_id // .payload.id)] | @tsv' 2>/dev/null)"
        if [ "$cwd" = "$1" ] && [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
    done < <(find "$dir" -maxdepth 4 -type f -name 'rollout-*.jsonl' -print0 2>/dev/null |
             xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -40 | cut -d' ' -f2-)
    return 0
}

provider_codex_list() {
    local tty cwd pid start id
    while IFS=$'\t' read -r tty cwd pid start; do
        [ -n "$tty" ] || continue
        id=$(_codex_session_for "$cwd" "$start")
        [ -n "$id" ] || id=$(provider_dir_id codex "$cwd")
        printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$id" "$cwd" "codex ${cwd##*/}" "$pid"
    done < <(provider_procs '(^| |/)codex( |$)')
}

provider_codex_resume() {
    if provider_is_uuid "$1"; then printf 'codex resume %s' "$1"; else printf 'codex resume --last'; fi
}
provider_codex_resume_last() { printf 'codex resume --last'; }
