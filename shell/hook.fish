# claude-workspace — fish integration
#
# Runs once, at the first prompt of an interactive shell.

status is-interactive; or return 0
type -q claude-workspace; or return 0
set -gx CW_HOOK_LOADED 1

function _claude_workspace_first_prompt --on-event fish_prompt
    functions -e _claude_workspace_first_prompt

    set -l tty (ps -o tty= -p %self | string trim)
    set -l command ""

    if set -q CLAUDE_WORKSPACE_RUN; or set -q CLAUDE_WS_RESUME
        if set -q CLAUDE_WORKSPACE_RUN
            set command $CLAUDE_WORKSPACE_RUN
        else
            set command "claude --resume $CLAUDE_WS_RESUME"
        end
        set -e CLAUDE_WORKSPACE_RUN
        set -e CLAUDE_WS_RESUME
        claude-workspace register-self "$tty" "$PWD" >/dev/null 2>&1 &
        commandline -r -- $command
        commandline -f execute
        return
    end

    if set -q CLAUDE_WORKSPACE_PREFILL
        set command $CLAUDE_WORKSPACE_PREFILL
        set -e CLAUDE_WORKSPACE_PREFILL
        claude-workspace register-self "$tty" "$PWD" >/dev/null 2>&1 &
        commandline -r -- $command
        return
    end

    set -l answer (claude-workspace first-prompt "$tty" "$PWD" 2>/dev/null)
    switch "$answer"
        case 'run *'
            commandline -r -- (string replace -r '^run ' '' -- "$answer")
            commandline -f execute
        case 'prefill *'
            commandline -r -- (string replace -r '^prefill ' '' -- "$answer")
        case rebuild
            set -l log (set -q XDG_STATE_HOME; and echo $XDG_STATE_HOME; or echo $HOME/.local/state)/claude-workspace/restore.log
            fish -c "claude-workspace restore >$log 2>&1" &
            echo "claude-workspace: the terminal came back empty; rebuilding the saved workspace (log: $log)"
        case ''
            # nothing to do
        case '*'
            echo $answer
    end
end
