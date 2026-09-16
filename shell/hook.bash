# paneful — bash integration
#
# Runs once, at the first prompt of an interactive shell. bash cannot put text
# into the prompt without running it, so a command that is only meant to be
# offered is pushed onto the history instead: press Up, then Enter.

case $- in *i*) ;; *) return 0 ;; esac
command -v paneful >/dev/null 2>&1 || return 0
export PANEFUL_HOOK_LOADED=1

_paneful_done=0

_paneful_first_prompt() {
    [ "$_paneful_done" = 1 ] && return 0
    _paneful_done=1
    local tty answer command
    tty=$(ps -o tty= -p $$ | tr -d ' ')

    if [ -n "${PANEFUL_RUN:-}" ] || [ -n "${CLAUDE_WS_RESUME:-}" ]; then
        command=${PANEFUL_RUN:-"claude --resume $CLAUDE_WS_RESUME"}
        unset PANEFUL_RUN CLAUDE_WS_RESUME
        paneful register-self "$tty" "$PWD" >/dev/null 2>&1 &
        history -s "$command"
        eval "$command"
        return 0
    fi
    if [ -n "${PANEFUL_PREFILL:-}" ]; then
        command=$PANEFUL_PREFILL
        unset PANEFUL_PREFILL
        paneful register-self "$tty" "$PWD" >/dev/null 2>&1 &
        history -s "$command"
        printf 'paneful: this pane was running: %s\n(press Up then Enter to start it again)\n' "$command"
        return 0
    fi

    answer=$(paneful first-prompt "$tty" "$PWD" 2>/dev/null)
    case $answer in
        'run '*)
            command=${answer#run }
            history -s "$command"
            eval "$command" ;;
        'prefill '*)
            command=${answer#prefill }
            history -s "$command"
            printf 'paneful: this pane was running: %s\n(press Up then Enter to start it again)\n' "$command" ;;
        rebuild)
            local log=${XDG_STATE_HOME:-$HOME/.local/state}/paneful/restore.log
            (paneful restore >"$log" 2>&1 &)
            printf 'paneful: the terminal came back empty; rebuilding the saved workspace (log: %s)\n' "$log" ;;
        ?*)
            printf '%s\n' "$answer" ;;
    esac
}

PROMPT_COMMAND="_paneful_first_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
