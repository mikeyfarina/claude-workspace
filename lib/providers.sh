# shellcheck shell=bash
# cwterm_* and provider_* functions come from the adapter and provider files
# loaded at run time, which shellcheck cannot see from here.
# shellcheck disable=SC2154
# Session providers: the agent CLIs whose sessions can be picked back up.
#
# A provider lives in lib/providers/<id>.sh and defines:
#
#   provider_<id>_label        human name
#   provider_<id>_available()  0 when the CLI is installed
#   provider_<id>_live()       0 when it can enumerate RUNNING sessions
#   provider_<id>_list()       TSV: tty  sessionId  cwd  name  pid
#   provider_<id>_resume()     <sessionId> <cwd> -> the command to type
#   provider_<id>_resume_last() <cwd> -> best effort when there is no id
#
# A provider that cannot enumerate running sessions still earns its keep: the
# snapshot records the command each pane was running, and that gets replayed.

providers_load() {
    local f id
    CW_PROVIDER_IDS=""
    for f in "$CW_LIB"/providers/*.sh; do
        [ -e "$f" ] || continue
        id=${f##*/}; id=${id%.sh}
        if [ -n "$CW_PROVIDERS" ]; then
            case " $CW_PROVIDERS " in *" $id "*) ;; *) continue ;; esac
        fi
        # shellcheck disable=SC1090
        . "$f"
        CW_PROVIDER_IDS="$CW_PROVIDER_IDS $id"
    done
    CW_PROVIDER_IDS=${CW_PROVIDER_IDS# }
}

provider_call() { local id=$1 fn=$2; shift 2; "provider_${id}_${fn}" "$@"; }

# --- helpers for providers with no registry of their own --------------------
# Claude Code is the only agent CLI that publishes a live pid -> session map.
# The rest are found the only way left: a running process, its tty, and its
# working directory. That is enough to put the right agent back in the right
# pane, even when the exact conversation id cannot be recovered.
# TSV: tty  cwd  pid  startEpoch
provider_procs() {   # $1 extended regex matched against the full command line
    local pid tty cwd start
    while read -r pid tty; do
        [ -n "$pid" ] || continue
        [ "$tty" != "??" ] || continue
        cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sed -n '1p')
        [ -n "$cwd" ] || continue
        start=$(date -j -f '%a %b %d %H:%M:%S %Y' "$(ps -o lstart= -p "$pid" | sed 's/ *$//')" '+%s' 2>/dev/null || echo 0)
        printf '%s\t%s\t%s\t%s\n' "$tty" "$cwd" "$pid" "$start"
    done < <(ps -axo pid=,tty=,command= | awk -v re="$1" '$0 ~ re { print $1, $2 }')
}

# A session id for an agent that has none. Keyed by directory, because that is
# what "resume what was here" actually means for these tools.
provider_dir_id() { printf '%s:%s' "$1" "$(printf '%s' "$2" | shasum | cut -c1-12)"; }

provider_is_uuid() {
    printf '%s' "$1" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

# Every running session across every provider.
# TSV: provider  tty  sessionId  cwd  name  pid
providers_sessions() {
    local id
    [ -n "${CW_PROVIDER_IDS:-}" ] || providers_load
    for id in $CW_PROVIDER_IDS; do
        provider_call "$id" available 2>/dev/null || continue
        provider_call "$id" live 2>/dev/null || continue
        provider_call "$id" list 2>/dev/null | awk -v p="$id" -F'\t' 'NF >= 2 { print p "\t" $0 }'
    done
}

# The command that brings a session back.
provider_resume_command() {   # $1 provider, $2 sessionId, $3 cwd
    local id=$1
    if [ -n "$2" ] && declare -f "provider_${id}_resume" >/dev/null 2>&1; then
        provider_call "$id" resume "$2" "$3"
        return 0
    fi
    if declare -f "provider_${id}_resume_last" >/dev/null 2>&1; then
        provider_call "$id" resume_last "$3"
    fi
}

cmd_providers() {
    local id inst live
    providers_load
    for id in $CW_PROVIDER_IDS; do
        inst=no; live=no
        provider_call "$id" available 2>/dev/null && inst=yes
        provider_call "$id" live 2>/dev/null && live=yes
        printf '%-8s %-24s installed: %-4s tracks running sessions: %-4s  resume: %s\n' \
            "$id" "$(provider_call "$id" label)" "$inst" "$live" \
            "$(provider_call "$id" resume '<id>' "$HOME" 2>/dev/null || echo '-')"
    done
    printf '\nA pane running something this list does not cover is still restored:\n'
    printf 'the command it was running is recorded and replayed (see CW_REPLAY_POLICY).\n'
}
