# shellcheck shell=bash
# Google Gemini CLI.
#
# No live pid -> session map exists, so a pane is matched by process and
# directory. `gemini --resume` with no argument reopens the most recent session
# for the project you are standing in, which is the right behaviour here; the
# exact session id is not recoverable from outside without guessing, so it is
# not guessed.

provider_gemini_label() { printf 'Gemini CLI'; }
provider_gemini_available() { command -v gemini >/dev/null 2>&1; }
provider_gemini_live() { provider_gemini_available; }

provider_gemini_list() {
    local tty cwd pid
    while IFS=$'\t' read -r tty cwd pid _; do
        [ -n "$tty" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$(provider_dir_id gemini "$cwd")" "$cwd" "gemini ${cwd##*/}" "$pid"
    done < <(provider_procs '(^| |/)gemini( |$)')
}

provider_gemini_resume() {
    if provider_is_uuid "$1"; then printf 'gemini --resume %s' "$1"; else printf 'gemini --resume'; fi
}
provider_gemini_resume_last() { printf 'gemini --resume'; }
