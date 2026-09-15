# How claude-workspace works

The problem is narrower than "restore my terminal", and the narrow part is the
whole difficulty.

Terminals already reopen tabs. Ghostty, iTerm2 and kitty all restore a window
with its tabs and working directories after a normal quit. What none of them
restore is the thing that was actually running in each pane. If seven of your
fifteen panes were Claude Code conversations, you get fifteen fresh shells and
a memory of which was which.

So the job is: given a pane, work out which agent conversation belongs in it,
and put that conversation back there.

## Why the obvious approaches do not work

**Match by working directory.** Fails immediately. Three panes open on the same
repository are indistinguishable, and that is the normal case, not the corner
case.

**Match by pane title.** Fails a moment later. Claude Code sets the pane title
to a summary of the conversation and prefixes it with a spinner glyph while it
works, so the title changes constantly. Users also pin their own tab titles,
which overrides it entirely.

**Ask the terminal which process is in the pane.** This is the right question,
and most terminals will not answer it. Ghostty's scripting dictionary exposes a
pane's id, title and working directory, but not its pid or tty. WezTerm's cli
reports neither. kitty does report a pid, and iTerm2 does report a tty, which
makes both of those easy; the general case is not.

## The pane probe

Every modern terminal learns a pane's working directory from OSC 7, an escape
sequence the shell's integration writes at each prompt. The terminal cannot
tell who wrote it. It just believes the pane that the bytes arrived on.

That is the lever. To find out which pane a shell is sitting in:

1. Create a unique empty directory, `~/.local/state/claude-workspace/nonce/<uuid>`.
2. Write one OSC 7 sequence naming it straight to `/dev/ttysNNN`.
3. Ask the terminal which pane now reports that directory.
4. Write the real directory back.

The pane's recorded directory is wrong for about 150 milliseconds and then
correct again. Nothing is drawn on screen, and the shell never sees it. What
comes back is an exact tty-to-pane mapping that survives renamed tabs,
duplicate directories and busy panes.

From there the chain closes. Claude Code writes a registry file per running
process at `~/.claude/sessions/<pid>.json` holding its session id and working
directory. The pid gives the tty through `ps`. The tty gives the pane through
the probe. The pane gives the position in the layout. So a snapshot can say,
exactly: *window 1, tab 5, pane 3 was session `c6df3966`*.

Terminals that expose a pid or tty of their own skip the probe entirely, and
the adapter says so by setting one flag. tmux is the extreme case: it reports
`#{pane_tty}` for every pane, so the mapping is a single command.

## The two restore paths

After a relaunch there are exactly two situations, and the tool decides between
them by counting how many of the snapshot's panes are still where it left them.

**The terminal restored the layout itself** (a normal quit, or a reboot with
macOS relaunching apps). The tabs and splits are back, each one a fresh shell.
Each pane then resumes its own session at its first prompt, with no window
being rebuilt and no command for the user to type.

**The terminal came back empty** (a crash). The first shell that notices rebuilds
the whole workspace: window, tabs, splits, pinned tab titles, and window
geometry when the screen arrangement has not changed since the snapshot. Each
new pane is created with its command in its environment, and the shell hook
runs it at the first prompt.

Both paths run off the same evaluation, so the preview and the real thing can
never disagree. `claude-workspace simulate` runs that evaluation against the
live terminal with "pretend it just restarted" set, and prints what each pane
would do without doing any of it.

## Not resuming the same session twice

A session that is already running must never be resumed again: two processes
appending to one transcript corrupts it. Two guards prevent that.

The first is simple: before anything is typed, the live session list is checked,
and a running session is skipped with its pid given as the reason.

The second matters more, because after a relaunch fifteen shells reach their
first prompt at roughly the same moment and each one independently asks "what
belongs here?". Each answer is claimed by creating a directory named after the
session id under a marker keyed to the terminal's start time. `mkdir` either
succeeds or fails, atomically, so exactly one pane wins a given session. When
every session in the pending snapshot is either running or claimed, the restore
is marked finished and ordinary snapshots resume.

## Panes that were not running an agent

The same snapshot records the foreground command of every pane: the top of the
tty's foreground process group whose parent is the pane's login shell, so
`claude` wins over the four node processes it spawned.

Replaying those is where a restore tool can do real damage. `npm run dev` is
welcome back. `rm -rf build && ./deploy.sh` is not, and a tool that reruns the
last thing in every pane will eventually do exactly that. So the default policy
types the command into the pane and stops, leaving the Enter key to a human.
`auto` runs commands matching an allowlist of the obviously-safe
(dev servers, watchers, `tail`, `ssh`) and prompts for everything else.

## Things that went wrong on the way

A short list, because each one cost real time and none of them is guessable.

**`tab` is a class name.** Inside `tell application "Ghostty"`, the word `tab`
resolves to the tab object, not the tab character, so a script building
tab-separated output silently produces `Wtab1tabtab-group-...`. The fix is
`character id 9` assigned outside the tell block.

**`select tab` is the whole command name.** The dictionary lists a command
called "select tab" taking a specifier, so `select tab 1 of w` does not parse;
it reads as the command `select tab` applied to the nonsense specifier `1 of w`.
It has to be `set tb to tab 1 of w` and then `select tab tb`.

**`IFS=$'\t' read` collapses empty fields.** Tab is an IFS whitespace character,
so a run of tabs counts as one delimiter and every field after an empty one
shifts left. A plan line meaning "no command to run, but this text to prefill"
arrived as "run this text". Since a shifted field here means typing the wrong
command into a live pane, every record the shell reads back now uses the ASCII
unit separator, which is not whitespace and does not collapse. Tabs are still
fine for records only `awk` and `jq` parse, because neither collapses them.

**`set -e` aborts on `[ cond ] && action`.** When the condition is false the
statement's exit status is 1, and a restore stopped silently halfway through
building a window. This program is full of that idiom, so it does not use
`set -e`; the calls whose failure matters are checked explicitly, and a
half-built snapshot is validated as JSON before it can replace a good one.

**Typing into a pane before its first prompt corrupts it.** Text sent while the
shell is still initialising gets swallowed or, worse, lands mid-quote and leaves
the shell reading continuation lines forever. Every pane is waited on until it
has registered itself or its title matches its own directory before anything is
typed into it.

**Prompts that eat input.** oh-my-zsh's "Would you like to update? [Y/n]" and
Powerlevel10k's instant-prompt warning both sit in front of the first prompt and
consume whatever arrives. The zsh integration is a ZLE `line-init` hook rather
than a `precmd` hook for exactly this reason: by then the line editor exists,
the instant prompt has finished, and setting `BUFFER` puts the command on the
command line as if it had been typed.

## What is and is not verified

Ghostty and tmux are exercised directly. The kitty, WezTerm and iTerm2 adapters
are written from each project's own documentation and have not been run against
the real thing; `claude-workspace terminals` labels them honestly, and fixing
that is the most useful thing a contributor could do.

Claude Code's pairing is exact. Codex CLI's is usually exact, recovered by
matching a pane's directory and start time against the rollout files under
`~/.codex/sessions`. Cursor CLI, Gemini CLI, Aider and opencode publish no live
session registry at all, so those panes come back with the agent's own
"continue from this directory" command rather than a specific conversation.
That limitation is theirs, and the tool states it rather than guessing an id.
