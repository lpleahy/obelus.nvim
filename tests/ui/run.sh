#!/bin/sh
# Hermetic entry point for the UI snapshot harness (`make ui-snapshots`).
# Private XDG dirs + TMPDIR (one fresh mktemp dir, removed afterwards by exact
# path), no user config/plugins/shada/swap, fixed locale and timezone. Extra env
# is passed through: OBELUS_UI_UPDATE=1, OBELUS_UI_ONLY=<substr,...>,
# OBELUS_UI_OUT=<dir>, OBELUS_UI_DELAY_MS, OBELUS_UI_GUARD_MS (see run.lua).
#
# Process hygiene: the parent nvim runs in the background and is awaited, so a
# signal reaches this script's trap at once. Every child nvim the parent spawns
# appends its pid to $dir/pids; on ANY exit (success, failure, error, INT/TERM)
# the trap kills the parent and any listed child that is still alive (exact pids,
# verified to be an `nvim --embed`), then removes $dir. A child found still alive
# on an otherwise clean exit is reported and turns the run into a failure.
# OBELUS_UI_PIDLOG=<file> additionally copies the child pids there (self-test).
set -u
here=$(cd "$(dirname "$0")" && pwd)
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
dir=$(mktemp -d "${base%/}/obelus-ui.XXXXXX") || exit 2
parent=

cleanup() {
  rc=$?
  if [ -n "$parent" ] && kill -0 "$parent" 2>/dev/null; then
    kill -KILL "$parent" 2>/dev/null
  fi
  leaked=0
  if [ -f "$dir/pids" ]; then
    [ -n "${OBELUS_UI_PIDLOG:-}" ] && cat "$dir/pids" >>"$OBELUS_UI_PIDLOG"
    while read -r p; do
      if ps -p "$p" -o command= 2>/dev/null | grep -q -- '--embed'; then
        kill -KILL "$p" 2>/dev/null
        echo "obelus ui: reaped leftover child nvim pid $p" >&2
        leaked=1
      fi
    done <"$dir/pids"
  fi
  rm -rf "$dir"
  if [ "$rc" -eq 0 ] && [ "$leaked" -ne 0 ]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$dir/config" "$dir/data" "$dir/state" "$dir/cache" "$dir/run" "$dir/tmp"
: >"$dir/pids"
env -u NVIM -u NVIM_APPNAME -u VIMINIT -u MYVIMRC -u NVIM_LISTEN_ADDRESS -u OBELUS_TEST_RTP \
  XDG_CONFIG_HOME="$dir/config" \
  XDG_DATA_HOME="$dir/data" \
  XDG_STATE_HOME="$dir/state" \
  XDG_CACHE_HOME="$dir/cache" \
  XDG_RUNTIME_DIR="$dir/run" \
  XDG_CONFIG_DIRS="$dir/config" \
  XDG_DATA_DIRS="$dir/data" \
  TMPDIR="$dir/tmp" \
  NVIM_LOG_FILE="$dir/state/nvim.log" \
  OBELUS_UI_TMP="$dir/tmp" \
  OBELUS_UI_PIDFILE="$dir/pids" \
  TZ=UTC LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
  "${OBELUS_NVIM:-nvim}" --headless -n -i NONE -u NONE --noplugin -c "luafile $here/run.lua" &
parent=$!
wait "$parent"
rc=$?
parent=
exit "$rc"
