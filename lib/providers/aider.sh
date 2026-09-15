# shellcheck shell=bash
# Aider.
#
# Aider has no session ids at all: every run in a repository appends to that
# repository's single .aider.chat.history.md. "Resume this exact session" and
# "resume the last one" are therefore the same thing, and the directory is the
# only key there is.

provider_aider_label() { printf 'Aider'; }
provider_aider_available() { command -v aider >/dev/null 2>&1; }
provider_aider_live() { provider_aider_available; }

provider_aider_list() {
    local tty cwd pid
    while IFS=$'\t' read -r tty cwd pid _; do
        [ -n "$tty" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$(provider_dir_id aider "$cwd")" "$cwd" "aider ${cwd##*/}" "$pid"
    done < <(provider_procs '(^| |/)aider( |$)')
}

provider_aider_resume() { provider_aider_resume_last "$2"; }
provider_aider_resume_last() {
    # Only offer the history reload when there is a history to reload.
    if [ -f "${1:-.}/.aider.chat.history.md" ]; then
        printf 'aider --restore-chat-history'
    else
        printf 'aider'
    fi
}
