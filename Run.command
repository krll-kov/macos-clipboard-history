#!/bin/sh
# Double-click to build the app and start it
# Any running copy is stopped first, so what runs is the build just made
set -e
cd "$(dirname "$0")"

APP="$PWD/build/Clipboard History.app"

./build.sh

if pgrep -x ClipHistory > /dev/null 2>&1; then
  echo "stopping the running copy"
  pkill -x ClipHistory || true
  # Time to release the status item and the hot key before the new copy asks
  # for them
  i=0
  while pgrep -x ClipHistory > /dev/null 2>&1 && [ $i -lt 15 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  pkill -9 -x ClipHistory > /dev/null 2>&1 || true
fi

open "$APP"
echo "running: the icon is in the menu bar"
