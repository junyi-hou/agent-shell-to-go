#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "$1" ]; then
  case "$1" in
    /*) FILES="$1" ;;
    *)  FILES="$SCRIPT_DIR/$1" ;;
  esac
else
  FILES="$(echo "$SCRIPT_DIR"/agent-shell-to-go-test-*.el)"
fi

emacs -batch \
  -L ~/.emacs.d/elpaca/builds/shell-maker \
  -L ~/.emacs.d/elpaca/builds/acp \
  -L ~/.emacs.d/elpaca/builds/agent-shell \
  -L ~/.emacs.d/elpaca/builds/websocket \
  -L "$PROJECT_ROOT" \
  -L "$SCRIPT_DIR" \
  $(printf -- '-l %s ' $FILES) \
  -f ert-run-tests-batch-and-exit
