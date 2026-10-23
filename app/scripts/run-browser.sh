#!/bin/bash
# Builds Acorn Browser and opens it. Optionally runs one task file at launch.
#
#   scripts/run-browser.sh                       build and open the browser
#   scripts/run-browser.sh ../kit/tasks/wikipedia.md   build, open, and run that task
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AcornBrowser.app"

"$ROOT/scripts/build.sh"

if [ $# -eq 0 ]; then
  open "$APP"
else
  TASK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  open "$APP" --args --run-task "$TASK"
fi
