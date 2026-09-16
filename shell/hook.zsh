# paneful — zsh integration
#
# Runs once per interactive shell, at the first prompt. It is a ZLE line-init
# hook rather than a precmd hook so that Powerlevel10k's instant prompt has
# already finished and nothing counts as output during initialization.
#
# Three jobs:
#   1. tell paneful which pane this shell is sitting in
#   2. act on a command handed to a pane a restore created
#   3. after the terminal has restarted, resume whatever was in this pane

[[ -o interactive ]] || return 0
(( $+commands[paneful] )) || return 0
export PANEFUL_HOOK_LOADED=1

autoload -Uz add-zle-hook-widget

_paneful_first_line() {
    add-zle-hook-widget -d line-init _paneful_first_line
    local tty=${TTY#/dev/} answer command

    # A pane built by `paneful restore` is handed its command in the
    # environment. CLAUDE_WS_RESUME is the name 0.1 used.
    if [[ -n ${PANEFUL_RUN-} || -n ${CLAUDE_WS_RESUME-} ]]; then
        command=${PANEFUL_RUN:-"claude --resume $CLAUDE_WS_RESUME"}
        unset PANEFUL_RUN CLAUDE_WS_RESUME
        paneful register-self "$tty" "$PWD" &>/dev/null &!
        BUFFER=$command
        zle accept-line
        return
    fi
    if [[ -n ${PANEFUL_PREFILL-} ]]; then
        command=$PANEFUL_PREFILL
        unset PANEFUL_PREFILL
        paneful register-self "$tty" "$PWD" &>/dev/null &!
        BUFFER=$command
        CURSOR=${#BUFFER}
        zle -M "paneful: this pane was running that; press Enter to start it again"
        return
    fi

    answer=$(paneful first-prompt "$tty" "$PWD" 2>/dev/null)
    case $answer in
        'run '*)
            BUFFER=${answer#run }
            zle accept-line ;;
        'prefill '*)
            BUFFER=${answer#prefill }
            CURSOR=${#BUFFER}
            zle -M "paneful: this pane was running that; press Enter to start it again" ;;
        rebuild)
            local log=${XDG_STATE_HOME:-$HOME/.local/state}/paneful/restore.log
            (paneful restore >"$log" 2>&1 &)
            zle -M "paneful: the terminal came back empty; rebuilding the saved workspace (log: $log)" ;;
        ?*)
            zle -M "$answer" ;;
    esac
}
add-zle-hook-widget line-init _paneful_first_line
