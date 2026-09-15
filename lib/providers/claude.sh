# shellcheck shell=bash
# Claude Code. It keeps a registry file per running process at
# ~/.claude/sessions/<pid>.json, which makes the pane-to-session pairing exact:
# the file names the pid, the pid names the tty, and the tty names the pane.

provider_claude_label() { printf 'Claude Code'; }
provider_claude_available() { command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; }
provider_claude_live() { [ -d "${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}" ]; }

provider_claude_list() {
    local dir=${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions} f pid tty
    for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        pid=${f##*/}; pid=${pid%.json}
        case $pid in ''|*[!0-9]*) continue ;; esac
        kill -0 "$pid" 2>/dev/null || continue
        tty=$(ps -o tty= -p "$pid" | tr -d ' ')
        if [ -z "$tty" ] || [ "$tty" = "??" ]; then continue; fi
        jq -r --arg tty "$tty" --arg pid "$pid" \
            'select(.kind == "interactive" and .sessionId != null)
             | [$tty, .sessionId, .cwd, (.name // ""), $pid] | @tsv' "$f" 2>/dev/null || true
    done
}

provider_claude_resume() { printf 'claude --resume %s' "$1"; }
provider_claude_resume_last() { printf 'claude --continue'; }
