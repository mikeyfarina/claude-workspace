# claude-workspace — bash integration
#
# Runs once, at the first prompt of an interactive shell. bash cannot put text
# into the prompt without running it, so a command that is only meant to be
# offered is pushed onto the history instead: press Up, then Enter.

case $- in *i*) ;; *) return 0 ;; esac
command -v claude-workspace >/dev/null 2>&1 || return 0
export CW_HOOK_LOADED=1

_claude_workspace_done=0

_claude_workspace_first_prompt() {
    [ "$_claude_workspace_done" = 1 ] && return 0
    _claude_workspace_done=1
    local tty answer command
    tty=$(ps -o tty= -p $$ | tr -d ' ')

    if [ -n "${CLAUDE_WORKSPACE_RUN:-}" ] || [ -n "${CLAUDE_WS_RESUME:-}" ]; then
        command=${CLAUDE_WORKSPACE_RUN:-"claude --resume $CLAUDE_WS_RESUME"}
        unset CLAUDE_WORKSPACE_RUN CLAUDE_WS_RESUME
        claude-workspace register-self "$tty" "$PWD" >/dev/null 2>&1 &
        history -s "$command"
        eval "$command"
        return 0
    fi
    if [ -n "${CLAUDE_WORKSPACE_PREFILL:-}" ]; then
        command=$CLAUDE_WORKSPACE_PREFILL
        unset CLAUDE_WORKSPACE_PREFILL
        claude-workspace register-self "$tty" "$PWD" >/dev/null 2>&1 &
        history -s "$command"
        printf 'claude-workspace: this pane was running: %s\n(press Up then Enter to start it again)\n' "$command"
        return 0
    fi

    answer=$(claude-workspace first-prompt "$tty" "$PWD" 2>/dev/null)
    case $answer in
        'run '*)
            command=${answer#run }
            history -s "$command"
            eval "$command" ;;
        'prefill '*)
            command=${answer#prefill }
            history -s "$command"
            printf 'claude-workspace: this pane was running: %s\n(press Up then Enter to start it again)\n' "$command" ;;
        rebuild)
            local log=${XDG_STATE_HOME:-$HOME/.local/state}/claude-workspace/restore.log
            (claude-workspace restore >"$log" 2>&1 &)
            printf 'claude-workspace: the terminal came back empty; rebuilding the saved workspace (log: %s)\n' "$log" ;;
        ?*)
            printf '%s\n' "$answer" ;;
    esac
}

PROMPT_COMMAND="_claude_workspace_first_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
