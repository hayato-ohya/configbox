#!/bin/zsh
# Dev helper: relaunch the app on a given tab and screenshot its window. Usage: scripts/shot.sh trackpad out.png
set -e
cd "$(dirname "$0")/.."
pkill -x ConfigBox 2>/dev/null || true; sleep 0.5
open build/ConfigBox.app --args --section "$1"; sleep 3
WID=$(swift scripts/window-id.swift 2>/dev/null)
screencapture -x -l "$WID" "$2"
