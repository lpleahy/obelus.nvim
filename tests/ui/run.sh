#!/bin/sh
# Hermetic entry point for the UI snapshot harness (`make ui-snapshots`).
# Private XDG dirs + TMPDIR (one fresh mktemp dir, removed afterwards by exact
# path), no user config/plugins/shada/swap, fixed locale and timezone. Extra env
# is passed through: OBELUS_UI_UPDATE=1, OBELUS_UI_ONLY=<substr,...>,
# OBELUS_UI_OUT=<dir>, OBELUS_UI_DELAY_MS, OBELUS_UI_GUARD_MS (see run.lua).
#
# Process hygiene: no code path signals a pid NUMBER. This script execs into
# supervise.pl, which forks a guardian that leads a dedicated process group, forks
# the parent nvim into it, and is the only thing that ever signals the group —
# only while the guardian is still its own unreaped child (see supervise.pl). The
# parent's children (the embedded nvims) are in the same group; rpc.lua also reaps
# each one through the handle it holds. When the parent exits, or on INT/TERM, the
# supervisor TERMs, then KILLs, any member still in the group, then reaps the
# guardian and removes $dir. SIGKILL of the supervisor: run.lua notices it was
# orphaned, stops before the next capture and removes $dir itself (exact path,
# OBELUS_UI_DIR). Requires perl (POSIX, Time::HiRes): checked before mktemp.
# Self-test knobs (tests/ui/selftest.sh): OBELUS_UI_SUPERVISE_LOG,
# OBELUS_UI_PAUSE_AFTER_REAP.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# Containment first: refuse unless every XDG path is inside OBELUS_TEST_ROOT
# (make / tests/private.sh set that up). Nothing is written before this.
. "$here/../xdg_guard.sh"
obelus_xdg_guard tests/ui/run.sh || exit 3
# Perl (with its core POSIX and Time::HiRes modules) runs the supervisor. Check
# before anything is allocated, so a missing Perl leaves nothing behind.
if ! command -v perl >/dev/null 2>&1 || ! perl -MPOSIX -MTime::HiRes -e 1 >/dev/null 2>&1; then
  echo "tests/ui/run.sh: perl with the core POSIX and Time::HiRes modules is required (see tests/ui/README.md)" >&2
  exit 2
fi
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
dir=$(mktemp -d "${base%/}/obelus-ui.XXXXXX") || exit 2
trap 'rm -rf "$dir"' EXIT # only until the exec below hands $dir to the supervisor
mkdir -p "$dir/config" "$dir/data" "$dir/state" "$dir/cache" "$dir/run" "$dir/tmp" || exit 2

set -- --rmdir "$dir"
[ -n "${OBELUS_UI_SUPERVISE_LOG:-}" ] && set -- "$@" --log "$OBELUS_UI_SUPERVISE_LOG"
[ -n "${OBELUS_UI_PAUSE_AFTER_REAP:-}" ] && set -- "$@" --pause-after-reap "$OBELUS_UI_PAUSE_AFTER_REAP"
trap - EXIT
exec perl "$here/supervise.pl" "$@" -- \
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
  "${OBELUS_NVIM:-nvim}" --headless -n -i NONE -u NONE --noplugin -c "luafile $here/run.lua"
