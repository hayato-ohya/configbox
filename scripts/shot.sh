#!/bin/zsh
# Dev helper: relaunch the app on a given tab and screenshot its window. Usage: scripts/shot.sh trackpad out.png
set -e
cd "$(dirname "$0")/.."
pkill -x ConfigBox 2>/dev/null || true; sleep 0.5
open build/ConfigBox.app --args --section "$1"; sleep 3
WID=$(swift "/private/tmp/claude-501/-Users-hayato-git-configbox/9087d112-bcc7-4d78-ad88-5db0c42aff9f/scratchpad/wid.swift" 2>/dev/null)
screencapture -x -l "${WID%%$'\n'*}" "$2"
