# Sourced by every test entry point (tests/private.sh, tests/specs.sh,
# tests/ui/run.sh, tests/ui/selftest.sh, tests/ui/mutations.sh). Defines
# obelus_xdg_guard <who>: returns 0 only when every path a test run can write or
# read config through points inside ONE private root, OBELUS_TEST_ROOT;
# otherwise prints why and returns 3. It runs before anything is written.
#   inside the root (each must be set and exist):
#     XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
#     XDG_RUNTIME_DIR TMPDIR, every entry of XDG_CONFIG_DIRS / XDG_DATA_DIRS,
#     the directory of NVIM_LOG_FILE, and OBELUS_UI_TMPBASE when set — each
#     ABSOLUTE (a relative value would follow a later change of directory);
#   the root is absolute, a directory, not /, and neither HOME nor an ancestor
#   of HOME; nothing resolves into a real default under HOME (.local, .config,
#   .cache) however it is spelled: the defaults, the root and every value are
#   compared by their canonical (symlink-free) paths;
#   NVIM_LOG_FILE is not a symlink (dangling or not) and, if it exists, a
#   regular file — checked before Neovim starts.
# Neovim derives stdpath() from these (HOME only when they are unset, which this
# rejects); obelus derives its store and claims paths from stdpath(). The nvim
# side re-checks the same rules plus stdpath() itself (tests/xdg_guard.lua).

obelus_xdg_refuse() { # who, reason
  echo "$1: refusing to run: $2. Tests write only inside a private root:" \
    "run them via make (it creates one) or tests/private.sh <command>." >&2
  return 3
}

# canonical path of an existing directory (symlinks resolved), or empty
obelus_xdg_real() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# obelus_xdg_in_default <canonical path>: prints the real default it falls in
obelus_xdg_in_default() {
  for _d in "$_def1" "$_def2" "$_def3"; do
    [ -n "$_d" ] || continue
    case "$1/" in "$_d"/*)
      echo "$_d"
      return 0
      ;;
    esac
  done
  return 1
}

# obelus_xdg_defaults: set _def1.._def3 to HOME's real defaults (.local,
# .config, .cache), canonical; a default that does not exist yet keeps its
# spelling under the canonical HOME. Sets _rhome (empty without a HOME).
obelus_xdg_defaults() {
  _def1= _def2= _def3= _rhome=
  if [ -n "${HOME:-}" ] && _rhome=$(obelus_xdg_real "$HOME"); then
    _def1=$(obelus_xdg_real "$HOME/.local") || _def1=$_rhome/.local
    _def2=$(obelus_xdg_real "$HOME/.config") || _def2=$_rhome/.config
    _def3=$(obelus_xdg_real "$HOME/.cache") || _def3=$_rhome/.cache
  else
    _rhome=
  fi
}

# obelus_xdg_inside <who> <var> <value>: value is an ABSOLUTE existing dir
# inside the root and not inside a real default — judged on canonical paths.
# A relative value is refused outright: it would follow the working directory.
obelus_xdg_inside() {
  case "$3" in /*) ;; *)
    obelus_xdg_refuse "$1" "$2=$3 is relative (it would follow the working directory)"
    return 3
    ;;
  esac
  if ! _rval=$(obelus_xdg_real "$3"); then
    obelus_xdg_refuse "$1" "$2=$3 is not an existing directory"
    return 3
  fi
  if _hit=$(obelus_xdg_in_default "$_rval"); then
    obelus_xdg_refuse "$1" "$2=$3 resolves into a real default ($_hit)"
    return 3
  fi
  case "$_rval/" in "$_rroot"/?*) ;; *)
    obelus_xdg_refuse "$1" "$2=$3 is outside OBELUS_TEST_ROOT=$_root"
    return 3
    ;;
  esac
  return 0
}

obelus_xdg_guard() {
  _who=$1
  _root=${OBELUS_TEST_ROOT:-}
  if [ -z "$_root" ]; then
    obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT is not set"
    return 3
  fi
  case $_root in /*) ;; *)
    obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT=$_root is not absolute"
    return 3
    ;;
  esac
  if ! _rroot=$(cd "$_root" 2>/dev/null && pwd -P); then
    obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT=$_root is not a directory"
    return 3
  fi
  if [ "$_rroot" = / ]; then
    obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT is /"
    return 3
  fi
  obelus_xdg_defaults
  if [ -n "$_rhome" ]; then
    case "$_rhome/" in "$_rroot"/*)
      obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT=$_root contains HOME ($HOME)"
      return 3
      ;;
    esac
  fi
  if _hit=$(obelus_xdg_in_default "$_rroot"); then
    obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT=$_root resolves into a real default ($_hit)"
    return 3
  fi
  for _v in XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR TMPDIR; do
    eval "_val=\${$_v:-}"
    if [ -z "$_val" ]; then
      obelus_xdg_refuse "$_who" "$_v is not set"
      return 3
    fi
    obelus_xdg_inside "$_who" "$_v" "$_val" || return 3
  done
  for _v in XDG_CONFIG_DIRS XDG_DATA_DIRS; do
    eval "_val=\${$_v:-}"
    if [ -z "$_val" ]; then
      obelus_xdg_refuse "$_who" "$_v is not set (an unset one defaults to system dirs)"
      return 3
    fi
    _rest=$_val
    while [ -n "$_rest" ]; do
      _entry=${_rest%%:*}
      [ "$_entry" = "$_rest" ] && _rest= || _rest=${_rest#*:}
      obelus_xdg_inside "$_who" "$_v entry" "$_entry" || return 3
    done
  done
  if [ -z "${NVIM_LOG_FILE:-}" ]; then
    obelus_xdg_refuse "$_who" "NVIM_LOG_FILE is not set"
    return 3
  fi
  case $NVIM_LOG_FILE in /*) ;; *)
    obelus_xdg_refuse "$_who" "NVIM_LOG_FILE=$NVIM_LOG_FILE is relative (it would follow the working directory)"
    return 3
    ;;
  esac
  if [ -L "$NVIM_LOG_FILE" ]; then
    obelus_xdg_refuse "$_who" "NVIM_LOG_FILE=$NVIM_LOG_FILE is a symlink"
    return 3
  fi
  if [ -e "$NVIM_LOG_FILE" ] && [ ! -f "$NVIM_LOG_FILE" ]; then
    obelus_xdg_refuse "$_who" "NVIM_LOG_FILE=$NVIM_LOG_FILE is not a regular file"
    return 3
  fi
  obelus_xdg_inside "$_who" "NVIM_LOG_FILE's directory" "$(dirname "$NVIM_LOG_FILE")" || return 3
  if [ -n "${OBELUS_UI_TMPBASE:-}" ]; then
    obelus_xdg_inside "$_who" OBELUS_UI_TMPBASE "$OBELUS_UI_TMPBASE" || return 3
  fi
  return 0
}
