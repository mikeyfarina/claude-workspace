#!/usr/bin/env bash
# Record the demo for the README.
#
# The interesting demo is the one thing that cannot be scripted safely: quit
# your terminal with work in it, open it again, and watch the panes resume
# themselves. So this script records the safe half (what the tool says it will
# do) and then tells you how to record the other half by hand.
# The backticks in the messages below are literal, for the reader.
# shellcheck disable=SC2016
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
out=${1:-docs/demo}
mkdir -p "$(dirname "$out")"

if command -v asciinema >/dev/null 2>&1; then
    printf 'Recording `paneful simulate` to %s.cast\n' "$out"
    asciinema rec "$out.cast" --overwrite --title "paneful" \
        --command "./bin/paneful status; echo; ./bin/paneful simulate"
    printf '\nUpload with: asciinema upload %s.cast\n' "$out.cast"
else
    printf 'asciinema is not installed (brew install asciinema); capturing plain text instead.\n'
    { ./bin/paneful status; echo; ./bin/paneful simulate; } > "$out.txt" 2>&1
    printf 'Wrote %s.txt\n' "$out.txt"
fi

cat <<'EOF'

To record the real thing:

  1. asciinema rec docs/relaunch.cast
  2. In that recording, run: paneful status
  3. Quit your terminal entirely (Cmd+Q) and open it again.
  4. In any pane once it is back: paneful log
     That shows, per pane, which session it resumed and why.

Step 3 cannot happen inside the recording, so the honest version is two clips:
the state before, and the log afterwards.
EOF
