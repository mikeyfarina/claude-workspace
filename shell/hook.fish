# paneful — fish integration
#
# Runs once, at the first prompt of an interactive shell.

status is-interactive; or return 0
type -q paneful; or return 0
set -gx PANEFUL_HOOK_LOADED 1

function _paneful_first_prompt --on-event fish_prompt
    functions -e _paneful_first_prompt

    set -l tty (ps -o tty= -p %self | string trim)
    set -l command ""

    if set -q PANEFUL_RUN; or set -q CLAUDE_WS_RESUME
        if set -q PANEFUL_RUN
            set command $PANEFUL_RUN
        else
            set command "claude --resume $CLAUDE_WS_RESUME"
        end
        set -e PANEFUL_RUN
        set -e CLAUDE_WS_RESUME
        paneful register-self "$tty" "$PWD" >/dev/null 2>&1 &
        commandline -r -- $command
        commandline -f execute
        return
    end

    if set -q PANEFUL_PREFILL
        set command $PANEFUL_PREFILL
        set -e PANEFUL_PREFILL
        paneful register-self "$tty" "$PWD" >/dev/null 2>&1 &
        commandline -r -- $command
        return
    end

    set -l answer (paneful first-prompt "$tty" "$PWD" 2>/dev/null)
    switch "$answer"
        case 'run *'
            commandline -r -- (string replace -r '^run ' '' -- "$answer")
            commandline -f execute
        case 'prefill *'
            commandline -r -- (string replace -r '^prefill ' '' -- "$answer")
        case rebuild
            set -l log (set -q XDG_STATE_HOME; and echo $XDG_STATE_HOME; or echo $HOME/.local/state)/paneful/restore.log
            fish -c "paneful restore >$log 2>&1" &
            echo "paneful: the terminal came back empty; rebuilding the saved workspace (log: $log)"
        case ''
            # nothing to do
        case '*'
            echo $answer
    end
end
