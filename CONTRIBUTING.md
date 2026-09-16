# Contributing

The most useful contribution is a terminal adapter that has actually been run.
Ghostty and tmux are exercised directly; kitty, WezTerm and iTerm2 were written
from their documentation and are labelled as such by `paneful
terminals`. If you use one of those, running it and fixing what breaks is worth
more than any feature.

## Getting set up

```sh
git clone https://github.com/mikeyfarina/paneful
cd paneful
./bin/paneful install
./bin/paneful doctor
```

Work against a throwaway state directory so you cannot damage your real
snapshots:

```sh
export PANEFUL_STATE_DIR=/tmp/cw-dev
./bin/paneful map
./bin/paneful save --force
./bin/paneful simulate
```

`simulate` is the safest way to see what a change does: it runs the real
matching against your live terminal and executes nothing.

## Before opening a pull request

```sh
shellcheck -x bin/paneful lib/*.sh lib/terminals/*.sh lib/providers/*.sh shell/hook.bash
for f in bin/paneful lib/*.sh lib/terminals/*.sh lib/providers/*.sh; do bash -n "$f"; done
zsh -n shell/hook.zsh
brew style --formula Formula/paneful.rb   # if you touched the formula
```

CI runs the same three.

## Writing a terminal adapter

An adapter is one file in `lib/terminals/` defining the `term_*` contract
documented at the top of `lib/terminal.sh`. Read `ghostty.sh` first; it is the
complete case. The parts that matter:

- **`term_dump`** produces the layout as tab-separated `W`/`T`/`S` rows. Tabs
  are fine here because only `awk` and `jq` parse it.
- **`term_build`** reads a plan whose fields are separated by the ASCII unit
  separator, not tabs. `IFS=$'\t' read` collapses empty fields and would shift
  every column after one, which in this program means typing the wrong command
  into somebody's pane.
- **The `env` capability** means the terminal can hand a new pane an
  environment variable. Without it, `restore.sh` types the command in after
  the pane reaches its prompt instead, which works but is slower and visible.
- **`PANEFUL_NATIVE_TTY_MAP=1`** means the terminal reports each pane's tty or pid
  itself, so the OSC 7 probe is skipped. Set it whenever you can: it is faster
  and touches nothing.
- Set `term_verified` to say how far you got. "from documentation" is an
  honest and useful value.

## Writing a session provider

A provider is one file in `lib/providers/` following the contract at the top of
`lib/providers.sh`. If the agent publishes a live map from process to session
id, use it, the way `claude.sh` does. If it does not, use `provider_procs` to
find the running processes and their directories, and resume with the agent's
own "carry on from here" command. Do not invent a session id format; a pane
that comes back with the right agent in the right directory is a good outcome,
and a pane that comes back with somebody else's conversation is not.

## Style

Four-space indent, `[ ]` over `[[ ]]`, no `set -e` (see `bin/paneful`
for why). Comments explain why, not what. Target bash 3.2, which is what macOS
ships: no associative arrays.
