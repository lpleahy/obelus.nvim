#!/bin/sh
# The ONE owned-scratch launcher for every test entry point (every Makefile test
# target goes through here):
#   sh tests/private.sh <command> [args...]
# It clears inherited Neovim / Lua environment, then:
#   - with OBELUS_TEST_ROOT unset: creates a fresh root with mktemp, points every
#     XDG home and dirs variable, XDG_RUNTIME_DIR, TMPDIR and NVIM_LOG_FILE into
#     it, runs the command and removes that exact root afterwards. If the caller
#     already set an XDG_* home without a root, it refuses instead of guessing;
#   - with OBELUS_TEST_ROOT set (a nested run, or a caller's own root): reuses it.
# Either way tests/xdg_guard.sh must pass before the command starts.
# OBELUS_TEST_RTP (optional renderer plugins, read-only runtime paths) passes through.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/xdg_guard.sh"

unset NVIM NVIM_APPNAME NVIM_LISTEN_ADDRESS VIMINIT EXINIT MYVIMRC VIM VIMRUNTIME LUA_PATH LUA_CPATH LUA_INIT \
  LUA_PATH_5_1 LUA_CPATH_5_1 LUA_INIT_5_1

created=
if [ -z "${OBELUS_TEST_ROOT:-}" ]; then
  for v in XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME; do
    eval "val=\${$v:-}"
    if [ -n "$val" ]; then
      obelus_xdg_refuse tests/private.sh "$v=$val is set but OBELUS_TEST_ROOT is not (unset it, or set OBELUS_TEST_ROOT to a private root that contains it)"
      exit 3
    fi
  done
  # the base for the new root: the inherited TMPDIR only if it is absolute,
  # exists and does not resolve into one of HOME's real defaults; otherwise a
  # known safe base (/tmp; OBELUS_TEST_SAFE_BASE overrides it for self-tests).
  # Decided BEFORE anything is allocated.
  obelus_xdg_defaults
  safe_base() {
    case $1 in /*) ;; *) return 1 ;; esac
    _b=$(obelus_xdg_real "$1") || return 1
    obelus_xdg_in_default "$_b" >/dev/null && return 1
    printf '%s' "$_b"
  }
  if ! base=$(safe_base "${TMPDIR:-/tmp}"); then
    if ! base=$(safe_base "${OBELUS_TEST_SAFE_BASE:-/tmp}"); then
      obelus_xdg_refuse tests/private.sh "no safe base for the private root (TMPDIR=${TMPDIR:-} is relative, missing or in a real default)"
      exit 3
    fi
  fi
  root=$(mktemp -d "${base%/}/obelus-test.XXXXXX") || exit 2
  created=$root
  trap 'rm -rf "$created"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir "$root/config" "$root/data" "$root/state" "$root/cache" "$root/run" "$root/tmp" || exit 2
  OBELUS_TEST_ROOT=$root
  XDG_CONFIG_HOME=$root/config
  XDG_DATA_HOME=$root/data
  XDG_STATE_HOME=$root/state
  XDG_CACHE_HOME=$root/cache
  XDG_CONFIG_DIRS=$root/config
  XDG_DATA_DIRS=$root/data
  XDG_RUNTIME_DIR=$root/run
  TMPDIR=$root/tmp
  NVIM_LOG_FILE=$root/state/nvim.log
  export OBELUS_TEST_ROOT XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_DIRS \
    XDG_DATA_DIRS XDG_RUNTIME_DIR TMPDIR NVIM_LOG_FILE
fi
obelus_xdg_guard tests/private.sh || exit 3
# Export CANONICAL absolute values (symlinks resolved), so nothing below can
# depend on spelling or on the working directory.
for v in OBELUS_TEST_ROOT XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR TMPDIR \
  OBELUS_UI_TMPBASE; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || continue
  val=$(obelus_xdg_real "$val") || exit 3
  eval "$v=\$val"
  export "${v?}"
done
for v in XDG_CONFIG_DIRS XDG_DATA_DIRS; do
  eval "rest=\${$v}"
  out=
  while [ -n "$rest" ]; do
    entry=${rest%%:*}
    [ "$entry" = "$rest" ] && rest= || rest=${rest#*:}
    entry=$(obelus_xdg_real "$entry") || exit 3
    out=${out:+$out:}$entry
  done
  eval "$v=\$out"
  export "${v?}"
done
logdir=$(obelus_xdg_real "$(dirname "$NVIM_LOG_FILE")") || exit 3
NVIM_LOG_FILE=$logdir/$(basename "$NVIM_LOG_FILE")
export NVIM_LOG_FILE
"$@"
exit $?
