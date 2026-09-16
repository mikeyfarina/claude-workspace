# shellcheck shell=bash
# term_* and PANEFUL_PROVIDER_IDS come from the adapter and providers loaded at
# run time, which shellcheck cannot see from this file.
# shellcheck disable=SC2154,SC2016
# install / uninstall / doctor: wiring the tool into a shell and into Claude
# Code, and telling the user exactly which part is broken when it is.

PANEFUL_MARK_BEGIN='# >>> paneful >>>'
PANEFUL_MARK_END='# <<< paneful <<<'
PANEFUL_CLAUDE_SETTINGS=${PANEFUL_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}

cmd_shell_init() {   # $1 shell name
    local sh=${1:-}
    [ -n "$sh" ] || sh=$(current_shell)
    local f=$PANEFUL_SHELL_DIR/hook.$sh
    if [ ! -f "$f" ]; then
        local have="" h
        for h in "$PANEFUL_SHELL_DIR"/hook.*; do have+="${h##*/hook.} "; done
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
PANEFUL_HOOK_LINK_DIR=${PANEFUL_HOOK_LINK_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paneful}

link_hooks() {
    local f
    mkdir -p "$PANEFUL_HOOK_LINK_DIR"
    for f in "$PANEFUL_SHELL_DIR"/hook.*; do
        [ -e "$f" ] || continue
        ln -sfn "$f" "$PANEFUL_HOOK_LINK_DIR/${f##*/}"
    done
}

rc_block() {   # $1 shell
    local hook=$PANEFUL_HOOK_LINK_DIR/hook.$1
    printf '%s\n' "$PANEFUL_MARK_BEGIN"
    if [ "$1" = fish ]; then
        printf 'test -f %s; and source %s\n' "$hook" "$hook"
    else
        printf '[ -f "%s" ] && . "%s"\n' "$hook" "$hook"
    fi
    printf '%s\n' "$PANEFUL_MARK_END"
}

rc_has_block() { grep -qF "$PANEFUL_MARK_BEGIN" "$1" 2>/dev/null; }

rc_strip_block() {   # $1 rc file
    [ -f "$1" ] || return 0
    awk -v b="$PANEFUL_MARK_BEGIN" -v e="$PANEFUL_MARK_END" '
        index($0, b) { skip = 1 } !skip { print } index($0, e) { skip = 0 }' "$1" > "$1.cw-tmp" &&
        mv "$1.cw-tmp" "$1"
}

claude_hooks_json() {   # $1 bin path -> the merged settings
    local src=$PANEFUL_CLAUDE_SETTINGS
    [ -f "$src" ] || src=/dev/null
    jq --arg bin "$1" '
        def mine: (.command // "") | test("paneful hook");
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
    [ -f "$PANEFUL_CLAUDE_SETTINGS" ] || return 1
    jq -e '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | select((.command // "") | test("paneful hook"))] | length >= 3' \
        "$PANEFUL_CLAUDE_SETTINGS" >/dev/null 2>&1
}

bin_target() { printf '%s/paneful' "${PANEFUL_BINDIR:-$HOME/.local/bin}"; }

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

    printf 'paneful %s\n' "$PANEFUL_VERSION"
    printf '  source:          %s\n' "$PANEFUL_ROOT"
    printf '  command:         %s\n' "$target"
    printf '  shell hook:      %s  (into %s)\n' "$PANEFUL_SHELL_DIR/hook.$sh" "$rc"
    printf '  Claude Code:     %s\n' "$PANEFUL_CLAUDE_SETTINGS"
    printf '  state:           %s\n\n' "$PANEFUL_STATE_DIR"

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
        ln -sfn "$PANEFUL_BIN_DIR/paneful" "$target"
        printf 'linked  %s -> %s\n' "$target" "$PANEFUL_BIN_DIR/paneful"
    fi
    case ":$PATH:" in
        *":$(dirname "$target"):"*) ;;
        *) log "$(dirname "$target") is not on your PATH; add it or the shell hook will not load" ;;
    esac

    # 2. the shell hook, reachable at a stable path
    link_hooks
    printf 'linked  %s/hook.* -> %s\n' "$PANEFUL_HOOK_LINK_DIR" "$PANEFUL_SHELL_DIR"
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
    if [ -d "$(dirname "$PANEFUL_CLAUDE_SETTINGS")" ]; then
        local merged backup
        merged=$(claude_hooks_json "$target")
        if [ -n "$merged" ] && [ "$merged" != '{}' ]; then
            if [ -f "$PANEFUL_CLAUDE_SETTINGS" ]; then
                backup=$PANEFUL_CLAUDE_SETTINGS.cw-backup-$(date +%Y%m%d-%H%M%S)
                cp "$PANEFUL_CLAUDE_SETTINGS" "$backup"
                printf 'backed up %s\n' "$backup"
            fi
            printf '%s\n' "$merged" > "$PANEFUL_CLAUDE_SETTINGS"
            printf 'hooked  %s (SessionStart, SessionEnd, UserPromptSubmit)\n' "$PANEFUL_CLAUDE_SETTINGS"
        else
            log "could not merge into $PANEFUL_CLAUDE_SETTINGS; add the hooks by hand (see the README)"
        fi
    else
        log "Claude Code is not set up here; skipped its hooks"
    fi

    # 4. learn the panes that are open right now, and take a first snapshot
    load snapshot terminal providers
    if terminal_load 2>/dev/null && term_present 2>/dev/null; then
        cmd_map
        "$PANEFUL_BIN_DIR/paneful" save --force >/dev/null 2>&1 || true
        printf 'mapped the open panes and saved a first snapshot\n'
    else
        log "no supported terminal running; run 'paneful map' once one is"
    fi

    printf '\nDone. Open a new tab to load the hook, then try: paneful simulate\n'
}

cmd_uninstall() {
    local sh rc target
    sh=$(current_shell)
    rc=$(rc_file_for "$sh")
    target=$(bin_target)
    rc_strip_block "$rc" && printf 'cleaned %s\n' "$rc"
    if [ -f "$PANEFUL_CLAUDE_SETTINGS" ]; then
        local cleaned
        cleaned=$(jq '
            def mine: (.command // "") | test("paneful hook");
            def clean($e): .hooks[$e] = ((.hooks[$e] // [])
                | map(.hooks = ((.hooks // []) | map(select(mine | not))))
                | map(select((.hooks // []) | length > 0)));
            clean("SessionStart") | clean("SessionEnd") | clean("UserPromptSubmit")
            | .hooks |= with_entries(select((.value | length) > 0))
        ' "$PANEFUL_CLAUDE_SETTINGS")
        printf '%s\n' "$cleaned" > "$PANEFUL_CLAUDE_SETTINGS"
        printf 'cleaned %s\n' "$PANEFUL_CLAUDE_SETTINGS"
    fi
    [ -L "$target" ] && rm "$target" && printf 'removed %s\n' "$target"
    if [ -d "$PANEFUL_HOOK_LINK_DIR" ]; then
        rm -f "$PANEFUL_HOOK_LINK_DIR"/hook.*
        rmdir "$PANEFUL_HOOK_LINK_DIR" 2>/dev/null
        printf 'removed %s\n' "$PANEFUL_HOOK_LINK_DIR"
    fi
    printf '\nSnapshots and logs are still in %s (delete that directory to remove them).\n' "$PANEFUL_STATE_DIR"
}

# --- doctor ----------------------------------------------------------------
PANEFUL_DOC_FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$*"; PANEFUL_DOC_FAIL=$((PANEFUL_DOC_FAIL + 1)); }

cmd_doctor() {
    printf 'paneful %s  (%s)\n\n' "$PANEFUL_VERSION" "$PANEFUL_ROOT"

    printf 'dependencies\n'
    if command -v jq >/dev/null; then ok "jq $(jq --version | sed 's/jq-//')"; else bad "jq is missing: brew install jq"; fi
    if command -v osascript >/dev/null; then ok "osascript"; else warn "no osascript; GUI terminal adapters will not work"; fi
    printf '  info  bash %s\n' "${BASH_VERSION%%(*}"

    printf '\nterminal\n'
    if terminal_load 2>/dev/null; then
        ok "$term_label $(term_version 2>/dev/null) via the '$PANEFUL_TERM' adapter"
        if term_present 2>/dev/null; then
            local panes
            panes=$(term_dump 2>/dev/null | grep -c $'^S\t' || true)
            ok "$panes pane(s) visible to the adapter"
        else
            bad "$term_label is not answering; is it running?"
        fi
        printf '  info  capabilities: %s\n' "$term_caps"
        terminal_has bounds || printf '  info  window position and size are not restorable with this adapter\n'
    else
        bad "no supported terminal detected (${PANEFUL_TERMINALS})"
    fi

    printf '\nshell integration\n'
    local sh rc loaded
    sh=$(current_shell); rc=$(rc_file_for "$sh")
    # The only answer that matters is whether a freshly started shell ends up
    # with the hook loaded, however it got there: the rc block this tool writes,
    # a dotfiles repo that sources it, or anything else.
    loaded=$("$SHELL" -ic 'printf %s "${PANEFUL_HOOK_LOADED:-}"' 2>/dev/null | tr -d '[:space:]')
    if [ -n "$loaded" ]; then
        ok "a new $sh shell loads the hook"
    elif rc_has_block "$rc"; then
        warn "the hook is in $(short "$rc") but a new shell did not load it"
    else
        bad "a new $sh shell does not load the hook: run paneful install"
    fi
    [ -n "${PANEFUL_HOOK_LOADED:-}" ] || printf '  info  this shell predates the hook; that is normal until you open a new tab\n'
    if [ -n "${TTY:-}" ] || [ -t 0 ]; then
        local mytty
        mytty=$(ps -o tty= -p $$ | tr -d ' ')
        if [ -f "$PANEFUL_TTY_DIR/$mytty" ]; then
            ok "this pane is mapped ($mytty -> $(cat "$PANEFUL_TTY_DIR/$mytty" | cut -c1-8))"
        else
            warn "this pane ($mytty) is not mapped yet; run paneful map"
        fi
    fi
    prune_tty_map
    printf '  info  %s of the open panes are mapped\n' "$(tty_map | wc -l | tr -d ' ')"

    printf '\nagent providers\n'
    providers_load
    local id n=0
    for id in $PANEFUL_PROVIDER_IDS; do
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
    printf '  info  replay policy for ordinary commands: %s\n' "$PANEFUL_REPLAY_POLICY"

    printf '\nautomatic snapshots\n'
    if claude_hooks_installed; then
        ok "Claude Code hooks are in $(short "$PANEFUL_CLAUDE_SETTINGS")"
    elif [ -f "$PANEFUL_CLAUDE_SETTINGS" ]; then
        bad "Claude Code hooks are missing: run paneful install"
    else
        warn "no $(short "$PANEFUL_CLAUDE_SETTINGS"); snapshots will only be taken when a new pane opens"
    fi
    if [ -f "$PANEFUL_LATEST" ]; then
        local age
        age=$(( ($(date +%s) - $(stat -f %m "$PANEFUL_LATEST")) / 60 ))
        if [ "$age" -lt 240 ]; then ok "latest snapshot is ${age}m old"; else warn "latest snapshot is ${age}m old"; fi
        jq -r '"  info  \(.counts.tabs) tabs, \(.counts.terminals) panes, \(.counts.sessions) sessions, \(.counts.placed) paired to a pane"' "$PANEFUL_LATEST"
        if [ "$(jq '.counts.unplaced' "$PANEFUL_LATEST")" -gt 0 ]; then
            warn "$(jq -r '.counts.unplaced' "$PANEFUL_LATEST") session(s) are not paired with a pane; run paneful map"
        fi
    else
        bad "no snapshot yet: run paneful save"
    fi
    if restore_pending 2>/dev/null; then
        warn "a restore is pending; run paneful restore, or dismiss to drop it"
    fi

    printf '\n'
    if [ "$PANEFUL_DOC_FAIL" -eq 0 ]; then
        printf 'All good. `paneful simulate` shows what a relaunch would do.\n'
    else
        printf '%s problem(s) above need fixing.\n' "$PANEFUL_DOC_FAIL"
        return 1
    fi
}
