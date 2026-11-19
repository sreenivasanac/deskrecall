#!/bin/zsh
# Runs one DeskRecall command-line mode through the installed app bundle (which holds the
# Accessibility permission) and prints its output. Gives up after 60 s, because `open -W`
# waits forever if the app is stuck on a dialog.
#   scripts/run-cli.sh --dump
out=$(mktemp -t deskrecall)
open -W -n -a DeskRecall --args "$@" --out "$out" &
pid=$!
for i in {1..60}; do sleep 1; kill -0 $pid 2>/dev/null || break; done
if kill $pid 2>/dev/null; then
  pkill -f -- "--out $out"      # the app itself: its arguments carry this run's output path
  echo "TIMEOUT: still running after 60 s"
fi
cat "$out"; rm -f "$out"
