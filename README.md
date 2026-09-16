# paneful

Put your terminal back exactly as you left it, coding agents and all.

You quit your terminal, or it crashes, or the machine reboots. The tabs come
back, maybe. The seven Claude Code sessions that were running in them do not.
`paneful` snapshots the window, tab and split layout together with the
agent session living in each pane, and puts all of it back. There is nothing to
type: each pane resumes its own session at its first prompt.

```
$ paneful simulate
Snapshot latest from 2026-09-15 19:21 [Ghostty 1.3.1]: 7 tabs, 15 panes, 13 sessions.

A. Ghostty restored the layout itself (a quit or a reboot). Each pane at its first prompt:
  tab 1 pane 1 A53C1671  ~/development/baseball-near-you -> would run: claude --resume 70fb26da-…  (league-map)
  tab 1 pane 2 F81EDBF8  ~/development/baseball-near-you -> would run: claude --resume b981d6db-…  (calculators)
  tab 2 pane 1 88B7F6F6  ~/development/website-2         -> would run: claude --resume 9b1dd656-…  (workflows)
  tab 3 pane 2 9B245DB3  ~/development/website-2         -> nothing: plain shell in the snapshot
  …
```

## Why it is not just "restore my tabs"

Terminals already reopen tabs and working directories. The hard part is knowing
*which* agent conversation belongs in *which* pane, and that is not something a
terminal tracks. Two Claude sessions in the same directory are indistinguishable
by directory, and pane titles change as the agent works.

So the pairing is done by tty. Claude Code writes a registry file per running
process naming its pid and session id; the pid names the tty; and the tty is
matched to a pane by writing a single OSC 7 escape sequence to `/dev/ttysNNN`
with a unique throwaway path and asking the terminal which pane just reported
it. The real directory is written back a fraction of a second later. That gives
an exact pane-to-session map that survives renamed tabs, identical directories
and busy panes.

## Install

```sh
brew install --HEAD mikeyfarina/tap/paneful
paneful install
paneful doctor
```

`--HEAD` is required until the first tagged release. Or clone it and run
`./bin/paneful install` from the checkout.

`install` links the command onto your `PATH`, adds one line to your shell rc,
registers three Claude Code hooks so snapshots stay fresh on their own, learns
the panes you already have open, and takes a first snapshot. `uninstall`
reverses all of it.

## Everyday use

There is no everyday use. That is the point. Snapshots are taken automatically
whenever a session starts, ends, or receives a prompt, and whenever you open a
new pane. When your terminal comes back, the panes resume themselves.

The commands are there for when you want to look:

| Command | What it does |
| --- | --- |
| `paneful simulate` | What every pane would do after a relaunch. Changes nothing. |
| `paneful doctor` | Checks every moving part and says how to fix what is broken. |
| `paneful status` | What the latest snapshot holds. |
| `paneful log` | What the automatic and manual restores actually did, and why. |
| `paneful diff` | How the live terminal differs from a snapshot. |
| `paneful restore` | Fill in anything a relaunch missed. |
| `paneful save --name before-refactor` | Keep a named snapshot to come back to. |

Every restore explains itself per pane: the exact command it types, or the
reason it typed nothing, including the pid of the session that is already
running.

## Panes that were not running an agent

A pane running `npm run dev` or `tail -f` is recorded too. What happens to it
on restore is up to `PANEFUL_REPLAY_POLICY`:

| Policy | Behaviour |
| --- | --- |
| `prompt` (default) | The command is typed into the pane but not run. Press Enter. |
| `auto` | Run it if it matches `PANEFUL_REPLAY_ALLOW`, otherwise type it and wait. |
| `all` | Run whatever it was. |
| `off` | Ignore it; the pane comes back as a plain shell. |

The default is deliberate. Replaying `rm -rf build && ./deploy.sh` because it
happened to be the last thing in a pane is not a feature.

## What is supported

**Terminals.** Ghostty 1.3 is the reference implementation and what this was
built against; tmux 3.7 is verified too, and needs no OSC 7 probe because tmux
reports each pane's tty itself. The kitty, WezTerm and iTerm2 adapters were
written from each project's documentation and have not been run against the
real thing. `paneful terminals` says which is which rather than
leaving you to find out.

**Agents.** Claude Code is exact: the session id is recovered and resumed.
Codex CLI is usually exact, by matching the pane's directory and start time
against the rollout files under `~/.codex/sessions`. Cursor CLI, Gemini CLI,
Aider and opencode have no live session registry to read, so those panes come
back with the agent's own "carry on from this directory" command
(`gemini --resume`, `aider --restore-chat-history`, `opencode --continue`).
`paneful providers` lists what your machine has.

## Configuration

`~/.config/paneful/config`, sourced as shell:

```sh
PANEFUL_REPLAY_POLICY=auto        # off | prompt | auto | all
PANEFUL_RESTORE_BOUNDS=1          # put the window back where it was
PANEFUL_HISTORY_KEEP=40           # rolling automatic snapshots to keep
PANEFUL_TERMINAL=ghostty          # force an adapter instead of detecting one
```

State lives in `~/.local/state/paneful`: snapshots, a rolling history,
the pane map and the activity log. Nothing leaves your machine, and nothing runs
in the background: every trigger is one short process that exits.

## Requirements

macOS, `bash` 3.2 or newer, `jq`. Window position and size need Accessibility
permission for your terminal; everything else works without it.

## How it works

[docs/how-it-works.md](docs/how-it-works.md) covers the pane-to-session pairing,
the two restore paths, and the things that went wrong on the way there.

## License

MIT
