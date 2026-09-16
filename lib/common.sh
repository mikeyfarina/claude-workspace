# shellcheck shell=bash
# Shared state, configuration, logging and small helpers.
#
# Everything here is sourced by bin/paneful and read by the other
# lib files, so shellcheck cannot see the uses from this file alone.
# shellcheck disable=SC2034

PANEFUL_VERSION=0.2.0

PANEFUL_STATE_DIR=${PANEFUL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paneful}
PANEFUL_CONFIG_DIR=${PANEFUL_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/paneful}
PANEFUL_CONFIG_FILE=$PANEFUL_CONFIG_DIR/config
PANEFUL_SNAP_DIR=$PANEFUL_STATE_DIR/snapshots
PANEFUL_HISTORY_DIR=$PANEFUL_STATE_DIR/history
PANEFUL_TTY_DIR=$PANEFUL_STATE_DIR/tty
PANEFUL_NONCE_DIR=$PANEFUL_STATE_DIR/nonce
PANEFUL_LOG_FILE=$PANEFUL_STATE_DIR/activity.log
PANEFUL_LOCK_DIR=$PANEFUL_STATE_DIR/save.lock
PANEFUL_LATEST=$PANEFUL_SNAP_DIR/latest.json

# --- defaults, overridable in $PANEFUL_CONFIG_FILE ------------------------------
# How many history snapshots to keep.
PANEFUL_HISTORY_KEEP=${PANEFUL_HISTORY_KEEP:-40}
# What to do with a pane that was running an ordinary command (not an agent):
#   off    ignore it            prompt  type it, do not press Enter
#   auto   run it if it matches PANEFUL_REPLAY_ALLOW, otherwise prompt
#   all    run whatever it was
PANEFUL_REPLAY_POLICY=${PANEFUL_REPLAY_POLICY:-prompt}
# Commands considered safe to re-run unattended under the "auto" policy.
PANEFUL_REPLAY_ALLOW=${PANEFUL_REPLAY_ALLOW:-'^(npm|pnpm|yarn|bun|deno|node|next|vite|nx|turbo|rails|bundle|mix|cargo|go|air|uvicorn|gunicorn|flask|django-admin|python[0-9.]* -m (http\.server|uvicorn|flask)|docker(-| )compose|make|just|task|watch|tail|less|htop|btop|k9s|lazygit|tmux|ssh|serve|jest|vitest|pytest|storybook)\b'}
# Restore window position and size (macOS, needs Accessibility permission).
PANEFUL_RESTORE_BOUNDS=${PANEFUL_RESTORE_BOUNDS:-1}
# Force a terminal adapter instead of detecting one.
PANEFUL_TERMINAL=${PANEFUL_TERMINAL:-}
# Seconds to wait for a freshly created pane to reach its first prompt.
PANEFUL_READY_TIMEOUT=${PANEFUL_READY_TIMEOUT:-45}
# Providers to consider, in order. Empty means every provider that is installed.
PANEFUL_PROVIDERS=${PANEFUL_PROVIDERS:-}

# Environment variables the shell hook acts on in a freshly created pane.
PANEFUL_ENV_RUN=PANEFUL_RUN
PANEFUL_ENV_PREFILL=PANEFUL_PREFILL

if [ -f "$PANEFUL_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$PANEFUL_CONFIG_FILE"
fi

mkdir -p "$PANEFUL_STATE_DIR" "$PANEFUL_SNAP_DIR" "$PANEFUL_HISTORY_DIR" "$PANEFUL_TTY_DIR" "$PANEFUL_NONCE_DIR"

# --- output ----------------------------------------------------------------
log() { printf 'paneful: %s\n' "$*" >&2; }
die() { log "$@"; exit 1; }

logfile() {
    # Keep the activity log bounded without a logrotate dependency.
    if [ -f "$PANEFUL_LOG_FILE" ] && [ "$(wc -c < "$PANEFUL_LOG_FILE" | tr -d ' ')" -gt 500000 ]; then
        tail -n 500 "$PANEFUL_LOG_FILE" > "$PANEFUL_LOG_FILE.tmp" && mv "$PANEFUL_LOG_FILE.tmp" "$PANEFUL_LOG_FILE"
    fi
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PANEFUL_LOG_FILE"
}

# Say it to the user and record it, so a restore can be audited afterwards.
say() { log "$*"; logfile "$*"; }

# Print a block to both the terminal and the log.
tee_log() { tee -a "$PANEFUL_LOG_FILE" >&2; }

short() { printf '%s' "${1/#$HOME/\~}"; }

# Records that a shell reads back field by field use the ASCII unit separator,
# never a tab: IFS treats tab as whitespace, so `IFS=$'\t' read` silently
# collapses runs of tabs and every field after an empty one shifts left.
# Tabs are still fine for records only awk and jq parse, which do not collapse.
PANEFUL_US=$'\037'
# jq filter that emits an array as one unit-separated record.
JQ_REC='map(tostring) | join("\u001f")'

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

load() {
    local m
    for m in "$@"; do
        # shellcheck disable=SC1090
        . "$PANEFUL_LIB/$m.sh"
    done
}

# --- process helpers -------------------------------------------------------
# The command a pane is actually running, or nothing when it sits at a prompt.
# Picks the top of the tty's foreground job: a "+" process whose parent is the
# pane's login shell, so `claude` wins over the node processes it spawned.
foreground_command() {   # $1 tty (bare name, e.g. ttys014)
    ps -t "$1" -o stat=,pid=,ppid=,command= 2>/dev/null | awk '
        function is_shell(c) {
            return c ~ /^-?(\/[^ ]*\/)?(zsh|bash|sh|fish|ksh|dash|tcsh|csh)( |$)/ ||
                   c ~ /^\/usr\/bin\/login( |$)/ || c ~ /^login( |$)/
        }
        {
            stat = $1; pid = $2; ppid = $3
            cmd = ""
            for (i = 4; i <= NF; i++) cmd = cmd (i > 4 ? " " : "") $i
            all[pid] = cmd
            if (stat ~ /\+/) { fg[pid] = cmd; par[pid] = ppid }
        }
        END {
            for (p in fg) {
                if (is_shell(fg[p])) continue
                parent = par[p]
                # Only the process the shell itself started, not its children.
                if (parent in all && is_shell(all[parent])) { print fg[p]; exit }
            }
        }' | sed 's/  *$//'
}

# --- json / applescript quoting -------------------------------------------
json_str() { jq -Rn --arg s "$1" '$s'; }

as_str() {   # AppleScript string literal
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# Run an AppleScript from stdin with a hard timeout so a hung terminal cannot
# wedge a shell prompt.
osa() {
    local secs=${1:-10}
    { printf 'with timeout of %s seconds\n' "$secs"; cat; printf '\nend timeout\n'; } | osascript
}

# --- snapshot paths --------------------------------------------------------
snap_path() {   # $1 name (default: latest)
    local name=${1:-latest}
    case $name in
        latest|"") printf '%s' "$PANEFUL_LATEST" ;;
        /*) printf '%s' "$name" ;;
        *) printf '%s/%s.json' "$PANEFUL_SNAP_DIR" "$name" ;;
    esac
}

cmd_log() {
    local n=${1:-40}
    [ -f "$PANEFUL_LOG_FILE" ] || { log "no activity recorded yet"; return 0; }
    tail -n "$n" "$PANEFUL_LOG_FILE"
}

cmd_help() {
    cat <<'EOF'
paneful — put your terminal back exactly as you left it, agents and all.

Everyday use (all of it automatic once `paneful install` has run):

  install [--dry-run]     wire up the shell hook and the Claude Code hooks
  doctor                  check every moving part and say how to fix what is broken
  simulate [NAME]         what each pane would do after a relaunch; changes nothing
  status [NAME]           what the latest snapshot holds
  log [N]                 what the automatic and manual restores actually did, and why

When you want to drive it by hand:

  save [--name NAME]      take a snapshot now
  restore [NAME]          bring a snapshot back (only needed if something was missed)
  diff [NAME]             how the live terminal differs from a snapshot
  list                    named snapshots and how old they are
  history                 the rolling automatic snapshots
  dismiss                 stop offering to restore the pending snapshot
  map                     re-learn which pane each shell is sitting in

  terminals               terminal adapters and which one is active
  providers               agent CLIs this build knows how to resume
  version

Options for restore:
  --dry-run               print the plan, change nothing
  --force                 build the layout even when every session already runs
  --mode auto|inplace|rebuild
  --layout row|grid       how splits are arranged when rebuilding
  --replay off|prompt|auto|all
                          what to do with panes that ran an ordinary command

Configuration: ~/.config/paneful/config   State: ~/.local/state/paneful
EOF
}
