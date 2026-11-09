#!/bin/sh
# Hermetic entry point for the UI snapshot harness (`make ui-snapshots`).
# Private XDG dirs + TMPDIR (one fresh mktemp dir, removed afterwards), no
# user config/plugins/shada/swap, fixed locale and timezone. Extra env is passed
# through: OBELUS_UI_UPDATE=1, OBELUS_UI_ONLY=<substr>, OBELUS_UI_OUT=<dir>.
set -u
here=$(cd "$(dirname "$0")" && pwd)
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
dir=$(mktemp -d "${base%/}/obelus-ui.XXXXXX") || exit 2
trap 'rm -rf "$dir"' EXIT
trap 'exit 130' INT TERM
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
  TZ=UTC LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
  "${OBELUS_NVIM:-nvim}" --headless -n -i NONE -u NONE --noplugin -c "luafile $here/run.lua"
exit $?
