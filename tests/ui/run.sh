#!/bin/sh
# Hermetic entry point for the UI snapshot harness (`make ui-snapshots`).
# Private XDG dirs + TMPDIR (one fresh mktemp dir, removed afterwards by exact
# path), no user config/plugins/shada/swap, fixed locale and timezone. Extra env
# is passed through: OBELUS_UI_UPDATE=1, OBELUS_UI_ONLY=<substr,...>,
# OBELUS_UI_OUT=<dir>, OBELUS_UI_DELAY_MS, OBELUS_UI_GUARD_MS (see run.lua).
#
# Process hygiene (ownership-safe — nothing is ever signalled by a recorded pid):
#   * rpc.lua reaps each child itself (quit -> SIGTERM -> SIGKILL, awaited) and
#     errors if it cannot; a normal exit therefore leaves no child to clean up.
#   * The parent nvim runs in the background and is awaited, so INT/TERM reach the
#     trap at once. The trap first SIGSTOPs the parent (still OUR unreaped child,
#     so its pid cannot have been reused); a stopped parent cannot reap, so its
#     children's pids stay pinned too. It then SIGKILLs exactly the processes
#     whose parent is that pid (pgrep -P), then the parent, then removes $dir.
#   * SIGKILL of this script runs no trap: run.lua notices it was reparented,
#     stops after the current scenario (its child is still reaped by rpc.lua) and
#     removes $dir itself (exact path, OBELUS_UI_DIR).
set -u
here=$(cd "$(dirname "$0")" && pwd)
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
dir=$(mktemp -d "${base%/}/obelus-ui.XXXXXX") || exit 2
parent=

cleanup() {
  rc=$?
  if [ -n "$parent" ]; then
    kill -STOP "$parent" 2>/dev/null
    for kid in $(pgrep -P "$parent" 2>/dev/null); do
      kill -KILL "$kid" 2>/dev/null
    done
    kill -KILL "$parent" 2>/dev/null
  fi
  rm -rf "$dir"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$dir/config" "$dir/data" "$dir/state" "$dir/cache" "$dir/run" "$dir/tmp"
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
  OBELUS_UI_DIR="$dir" \
  TZ=UTC LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
  "${OBELUS_NVIM:-nvim}" --headless -n -i NONE -u NONE --noplugin -c "luafile $here/run.lua" &
parent=$!
wait "$parent"
rc=$?
parent=
exit "$rc"
