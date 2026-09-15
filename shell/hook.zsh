# claude-workspace — zsh integration
#
# Runs once per interactive shell, at the first prompt. It is a ZLE line-init
# hook rather than a precmd hook so that Powerlevel10k's instant prompt has
# already finished and nothing counts as output during initialization.
#
# Three jobs:
#   1. tell claude-workspace which pane this shell is sitting in
#   2. act on a command handed to a pane a restore created
#   3. after the terminal has restarted, resume whatever was in this pane

[[ -o interactive ]] || return 0
(( $+commands[claude-workspace] )) || return 0
export CW_HOOK_LOADED=1

autoload -Uz add-zle-hook-widget

_claude_workspace_first_line() {
    add-zle-hook-widget -d line-init _claude_workspace_first_line
    local tty=${TTY#/dev/} answer command

    # A pane built by `claude-workspace restore` is handed its command in the
    # environment. CLAUDE_WS_RESUME is the name 0.1 used.
    if [[ -n ${CLAUDE_WORKSPACE_RUN-} || -n ${CLAUDE_WS_RESUME-} ]]; then
        command=${CLAUDE_WORKSPACE_RUN:-"claude --resume $CLAUDE_WS_RESUME"}
        unset CLAUDE_WORKSPACE_RUN CLAUDE_WS_RESUME
        claude-workspace register-self "$tty" "$PWD" &>/dev/null &!
        BUFFER=$command
        zle accept-line
        return
    fi
    if [[ -n ${CLAUDE_WORKSPACE_PREFILL-} ]]; then
        command=$CLAUDE_WORKSPACE_PREFILL
        unset CLAUDE_WORKSPACE_PREFILL
        claude-workspace register-self "$tty" "$PWD" &>/dev/null &!
        BUFFER=$command
        CURSOR=${#BUFFER}
        zle -M "claude-workspace: this pane was running that; press Enter to start it again"
        return
    fi

    answer=$(claude-workspace first-prompt "$tty" "$PWD" 2>/dev/null)
    case $answer in
        'run '*)
            BUFFER=${answer#run }
            zle accept-line ;;
        'prefill '*)
            BUFFER=${answer#prefill }
            CURSOR=${#BUFFER}
            zle -M "claude-workspace: this pane was running that; press Enter to start it again" ;;
        rebuild)
            local log=${XDG_STATE_HOME:-$HOME/.local/state}/claude-workspace/restore.log
            (claude-workspace restore >"$log" 2>&1 &)
            zle -M "claude-workspace: the terminal came back empty; rebuilding the saved workspace (log: $log)" ;;
        ?*)
            zle -M "$answer" ;;
    esac
}
add-zle-hook-widget line-init _claude_workspace_first_line
