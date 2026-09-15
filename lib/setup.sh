# shellcheck shell=bash
# cwterm_* and CW_PROVIDER_IDS come from the adapter and providers loaded at
# run time, which shellcheck cannot see from this file.
# shellcheck disable=SC2154,SC2016
# install / uninstall / doctor: wiring the tool into a shell and into Claude
# Code, and telling the user exactly which part is broken when it is.

CW_MARK_BEGIN='# >>> claude-workspace >>>'
CW_MARK_END='# <<< claude-workspace <<<'
CW_CLAUDE_SETTINGS=${CW_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}

cmd_shell_init() {   # $1 shell name
    local sh=${1:-}
    [ -n "$sh" ] || sh=$(current_shell)
    local f=$CW_SHELL_DIR/hook.$sh
    if [ ! -f "$f" ]; then
        local have="" h
        for h in "$CW_SHELL_DIR"/hook.*; do have+="${h##*/hook.} "; done
        die "no shell hook for '$sh' (have: $have)"
    fi
    printf '%s\n' "$f"
}

current_shell() {
    case ${SHELL##*/} in
        zsh) printf zsh ;;
        bash) printf bash ;;
        fish) printf fish ;;
        *) printf zsh ;;
    esac
}

rc_file_for() {   # $1 shell
    case $1 in
        zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
        bash) if [ -f "$HOME/.bashrc" ]; then printf '%s\n' "$HOME/.bashrc"; else printf '%s\n' "$HOME/.bash_profile"; fi ;;
        fish) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    esac
}

# The rc line points at a stable per-user path rather than wherever the tool
# happens to be installed, so the same line works on every machine and does not
# change when you move from a clone to Homebrew.
CW_HOOK_LINK_DIR=${CW_HOOK_LINK_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-workspace}

link_hooks() {
    local f
    mkdir -p "$CW_HOOK_LINK_DIR"
    for f in "$CW_SHELL_DIR"/hook.*; do
        [ -e "$f" ] || continue
        ln -sfn "$f" "$CW_HOOK_LINK_DIR/${f##*/}"
    done
}

rc_block() {   # $1 shell
    local hook=$CW_HOOK_LINK_DIR/hook.$1
    printf '%s\n' "$CW_MARK_BEGIN"
    if [ "$1" = fish ]; then
        printf 'test -f %s; and source %s\n' "$hook" "$hook"
    else
        printf '[ -f "%s" ] && . "%s"\n' "$hook" "$hook"
    fi
    printf '%s\n' "$CW_MARK_END"
}

rc_has_block() { grep -qF "$CW_MARK_BEGIN" "$1" 2>/dev/null; }

rc_strip_block() {   # $1 rc file
    [ -f "$1" ] || return 0
    awk -v b="$CW_MARK_BEGIN" -v e="$CW_MARK_END" '
        index($0, b) { skip = 1 } !skip { print } index($0, e) { skip = 0 }' "$1" > "$1.cw-tmp" &&
        mv "$1.cw-tmp" "$1"
}

claude_hooks_json() {   # $1 bin path -> the merged settings
    local src=$CW_CLAUDE_SETTINGS
    [ -f "$src" ] || src=/dev/null
    jq --arg bin "$1" '
        def mine: (.command // "") | test("claude-workspace hook");
        def clean($e): .hooks[$e] = ((.hooks[$e] // [])
            | map(.hooks = ((.hooks // []) | map(select(mine | not))))
            | map(select((.hooks // []) | length > 0)));
        def add($e; $arg): .hooks[$e] = ((.hooks[$e] // [])
            + [{hooks: [{type: "command", command: ($bin + " hook " + $arg), timeout: 5}]}]);
        (. // {})
        | clean("SessionStart") | clean("SessionEnd") | clean("UserPromptSubmit")
        | add("SessionStart"; "session-start")
        | add("SessionEnd"; "session-end")
        | add("UserPromptSubmit"; "prompt")
    ' "$src" 2>/dev/null || printf '{}'
}

claude_hooks_installed() {
    [ -f "$CW_CLAUDE_SETTINGS" ] || return 1
    jq -e '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | select((.command // "") | test("claude-workspace hook"))] | length >= 3' \
        "$CW_CLAUDE_SETTINGS" >/dev/null 2>&1
}

bin_target() { printf '%s/claude-workspace' "${CW_BINDIR:-$HOME/.local/bin}"; }

cmd_install() {
    local dry=0 norc=0 sh=""
    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run) dry=1; shift ;;
            # For dotfiles that source the hook themselves.
            --no-rc) norc=1; shift ;;
            --shell) sh=${2:-}; shift 2 ;;
            *) die "install: unknown option $1" ;;
        esac
    done
    [ -n "$sh" ] || sh=$(current_shell)
    local rc target
    rc=$(rc_file_for "$sh")
    target=$(bin_target)

    printf 'claude-workspace %s\n' "$CW_VERSION"
    printf '  source:          %s\n' "$CW_ROOT"
    printf '  command:         %s\n' "$target"
    printf '  shell hook:      %s  (into %s)\n' "$CW_SHELL_DIR/hook.$sh" "$rc"
    printf '  Claude Code:     %s\n' "$CW_CLAUDE_SETTINGS"
    printf '  state:           %s\n\n' "$CW_STATE_DIR"

    if [ "$dry" -eq 1 ]; then
        printf 'Would add to %s:\n' "$rc"
        rc_block "$sh" | sed 's/^/    /'
        printf '\nWould add these Claude Code hooks (SessionStart, SessionEnd, UserPromptSubmit):\n'
        printf '    %s hook session-start\n' "$target"
        printf '\nDry run; nothing changed.\n'
        return 0
    fi

    # 1. the command on PATH
    mkdir -p "$(dirname "$target")"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        log "$target exists and is not a symlink; leaving it alone"
    else
        ln -sfn "$CW_BIN_DIR/claude-workspace" "$target"
        printf 'linked  %s -> %s\n' "$target" "$CW_BIN_DIR/claude-workspace"
    fi
    case ":$PATH:" in
        *":$(dirname "$target"):"*) ;;
        *) log "$(dirname "$target") is not on your PATH; add it or the shell hook will not load" ;;
    esac

    # 2. the shell hook, reachable at a stable path
    link_hooks
    printf 'linked  %s/hook.* -> %s\n' "$CW_HOOK_LINK_DIR" "$CW_SHELL_DIR"
    if [ "$norc" -eq 1 ]; then
        printf 'skipped %s (--no-rc); source this yourself:\n' "$rc"
        rc_block "$sh" | sed -n '2p' | sed 's/^/    /'
    else
        if rc_has_block "$rc"; then
            rc_strip_block "$rc"
            printf 'updated %s\n' "$rc"
        else
            printf 'added   %s\n' "$rc"
        fi
        [ -f "$rc" ] || { mkdir -p "$(dirname "$rc")"; : > "$rc"; }
        printf '\n' >> "$rc"
        rc_block "$sh" >> "$rc"
    fi

    # 3. the Claude Code hooks that keep the snapshot fresh
    if [ -d "$(dirname "$CW_CLAUDE_SETTINGS")" ]; then
        local merged backup
        merged=$(claude_hooks_json "$target")
        if [ -n "$merged" ] && [ "$merged" != '{}' ]; then
            if [ -f "$CW_CLAUDE_SETTINGS" ]; then
                backup=$CW_CLAUDE_SETTINGS.cw-backup-$(date +%Y%m%d-%H%M%S)
                cp "$CW_CLAUDE_SETTINGS" "$backup"
                printf 'backed up %s\n' "$backup"
            fi
            printf '%s\n' "$merged" > "$CW_CLAUDE_SETTINGS"
            printf 'hooked  %s (SessionStart, SessionEnd, UserPromptSubmit)\n' "$CW_CLAUDE_SETTINGS"
        else
            log "could not merge into $CW_CLAUDE_SETTINGS; add the hooks by hand (see the README)"
        fi
    else
        log "Claude Code is not set up here; skipped its hooks"
    fi

    # 4. learn the panes that are open right now, and take a first snapshot
    load snapshot terminal providers
    if terminal_load 2>/dev/null && cwterm_present 2>/dev/null; then
        cmd_map
        "$CW_BIN_DIR/claude-workspace" save --force >/dev/null 2>&1 || true
        printf 'mapped the open panes and saved a first snapshot\n'
    else
        log "no supported terminal running; run 'claude-workspace map' once one is"
    fi

    printf '\nDone. Open a new tab to load the hook, then try: claude-workspace simulate\n'
}

cmd_uninstall() {
    local sh rc target
    sh=$(current_shell)
    rc=$(rc_file_for "$sh")
    target=$(bin_target)
    rc_strip_block "$rc" && printf 'cleaned %s\n' "$rc"
    if [ -f "$CW_CLAUDE_SETTINGS" ]; then
        local cleaned
        cleaned=$(jq '
            def mine: (.command // "") | test("claude-workspace hook");
            def clean($e): .hooks[$e] = ((.hooks[$e] // [])
                | map(.hooks = ((.hooks // []) | map(select(mine | not))))
                | map(select((.hooks // []) | length > 0)));
            clean("SessionStart") | clean("SessionEnd") | clean("UserPromptSubmit")
            | .hooks |= with_entries(select((.value | length) > 0))
        ' "$CW_CLAUDE_SETTINGS")
        printf '%s\n' "$cleaned" > "$CW_CLAUDE_SETTINGS"
        printf 'cleaned %s\n' "$CW_CLAUDE_SETTINGS"
    fi
    [ -L "$target" ] && rm "$target" && printf 'removed %s\n' "$target"
    if [ -d "$CW_HOOK_LINK_DIR" ]; then
        rm -f "$CW_HOOK_LINK_DIR"/hook.*
        rmdir "$CW_HOOK_LINK_DIR" 2>/dev/null
        printf 'removed %s\n' "$CW_HOOK_LINK_DIR"
    fi
    printf '\nSnapshots and logs are still in %s (delete that directory to remove them).\n' "$CW_STATE_DIR"
}

# --- doctor ----------------------------------------------------------------
CW_DOC_FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$*"; CW_DOC_FAIL=$((CW_DOC_FAIL + 1)); }

cmd_doctor() {
    printf 'claude-workspace %s  (%s)\n\n' "$CW_VERSION" "$CW_ROOT"

    printf 'dependencies\n'
    if command -v jq >/dev/null; then ok "jq $(jq --version | sed 's/jq-//')"; else bad "jq is missing: brew install jq"; fi
    if command -v osascript >/dev/null; then ok "osascript"; else warn "no osascript; GUI terminal adapters will not work"; fi
    printf '  info  bash %s\n' "${BASH_VERSION%%(*}"

    printf '\nterminal\n'
    if terminal_load 2>/dev/null; then
        ok "$cwterm_label $(cwterm_version 2>/dev/null) via the '$CW_TERM' adapter"
        if cwterm_present 2>/dev/null; then
            local panes
            panes=$(cwterm_dump 2>/dev/null | grep -c $'^S\t' || true)
            ok "$panes pane(s) visible to the adapter"
        else
            bad "$cwterm_label is not answering; is it running?"
        fi
        printf '  info  capabilities: %s\n' "$cwterm_caps"
        terminal_has bounds || printf '  info  window position and size are not restorable with this adapter\n'
    else
        bad "no supported terminal detected (${CW_TERMINALS})"
    fi

    printf '\nshell integration\n'
    local sh rc
    sh=$(current_shell); rc=$(rc_file_for "$sh")
    if rc_has_block "$rc"; then
        ok "hook installed in $(short "$rc")"
    elif [ -n "$(grep -rl "claude-workspace/hook\.$sh" "$HOME/.zshrc" "$HOME/.bashrc" "${ZDOTDIR:-$HOME}"/.zshrc "$HOME/.config/fish/config.fish" 2>/dev/null | head -1)" ]; then
        ok "hook sourced from your own shell config"
    else
        bad "hook missing from $(short "$rc"): run claude-workspace install"
    fi
    if [ -n "${CW_HOOK_LOADED:-}" ]; then
        ok "hook is loaded in this shell"
    else
        warn "hook is not loaded in this shell (open a new tab after installing)"
    fi
    if [ -n "${TTY:-}" ] || [ -t 0 ]; then
        local mytty
        mytty=$(ps -o tty= -p $$ | tr -d ' ')
        if [ -f "$CW_TTY_DIR/$mytty" ]; then
            ok "this pane is mapped ($mytty -> $(cat "$CW_TTY_DIR/$mytty" | cut -c1-8))"
        else
            warn "this pane ($mytty) is not mapped yet; run claude-workspace map"
        fi
    fi
    printf '  info  %s of the open panes are mapped\n' "$(tty_map | wc -l | tr -d ' ')"

    printf '\nagent providers\n'
    providers_load
    local id n=0
    for id in $CW_PROVIDER_IDS; do
        if provider_call "$id" available 2>/dev/null; then
            if provider_call "$id" live 2>/dev/null; then
                ok "$(provider_call "$id" label): installed, running sessions are tracked"
                n=$((n + 1))
            else
                printf '  info  %s: installed; sessions are restored by replaying the command\n' "$(provider_call "$id" label)"
            fi
        fi
    done
    [ "$n" -gt 0 ] || warn "no provider can track running sessions; panes will be restored by replaying commands"
    printf '  info  replay policy for ordinary commands: %s\n' "$CW_REPLAY_POLICY"

    printf '\nautomatic snapshots\n'
    if claude_hooks_installed; then
        ok "Claude Code hooks are in $(short "$CW_CLAUDE_SETTINGS")"
    elif [ -f "$CW_CLAUDE_SETTINGS" ]; then
        bad "Claude Code hooks are missing: run claude-workspace install"
    else
        warn "no $(short "$CW_CLAUDE_SETTINGS"); snapshots will only be taken when a new pane opens"
    fi
    if [ -f "$CW_LATEST" ]; then
        local age
        age=$(( ($(date +%s) - $(stat -f %m "$CW_LATEST")) / 60 ))
        if [ "$age" -lt 240 ]; then ok "latest snapshot is ${age}m old"; else warn "latest snapshot is ${age}m old"; fi
        jq -r '"  info  \(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions, \(.counts.placed) paired to a pane"' "$CW_LATEST"
        if [ "$(jq '.counts.unplaced' "$CW_LATEST")" -gt 0 ]; then
            warn "$(jq -r '.counts.unplaced' "$CW_LATEST") session(s) are not paired with a pane; run claude-workspace map"
        fi
    else
        bad "no snapshot yet: run claude-workspace save"
    fi
    if restore_pending 2>/dev/null; then
        warn "a restore is pending; run claude-workspace restore, or dismiss to drop it"
    fi

    printf '\n'
    if [ "$CW_DOC_FAIL" -eq 0 ]; then
        printf 'All good. `claude-workspace simulate` shows what a relaunch would do.\n'
    else
        printf '%s problem(s) above need fixing.\n' "$CW_DOC_FAIL"
        return 1
    fi
}
