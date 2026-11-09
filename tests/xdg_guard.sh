# Sourced by every test entry point (tests/private.sh, tests/specs.sh,
# tests/ui/run.sh, tests/ui/selftest.sh, tests/ui/mutations.sh). Defines
# obelus_xdg_guard <who>: returns 0 only when every path a test run can write or
# read config through points inside ONE private root, OBELUS_TEST_ROOT;
# otherwise prints why and returns 3. It runs before anything is written.
#   inside the root (each must be set and exist):
#     XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
#     XDG_RUNTIME_DIR TMPDIR, every entry of XDG_CONFIG_DIRS / XDG_DATA_DIRS,
#     the directory of NVIM_LOG_FILE, and OBELUS_UI_TMPBASE when set;
#   the root is absolute, a directory, not /, and neither HOME nor an ancestor
#   of HOME; no value is a real default under HOME.
# Neovim derives stdpath() from these (HOME only when they are unset, which this
# rejects); obelus derives its store and claims paths from stdpath(). The nvim
# side re-checks the same rules plus stdpath() itself (tests/xdg_guard.lua).

obelus_xdg_refuse() { # who, reason
  echo "$1: refusing to run: $2. Tests write only inside a private root:" \
    "run them via make (it creates one) or tests/private.sh <command>." >&2
  return 3
}

# obelus_xdg_inside <who> <var> <value>: value is an existing dir inside the root
obelus_xdg_inside() {
  if [ -n "${HOME:-}" ]; then
    for _real in "$HOME/.local/share" "$HOME/.local/state" "$HOME/.config" "$HOME/.cache" "$HOME/.local"; do
      case "$3" in "$_real" | "$_real"/*)
        obelus_xdg_refuse "$1" "$2=$3 is a real default ($_real)"
        return 3
        ;;
      esac
    done
  fi
  if ! _rval=$(cd "$3" 2>/dev/null && pwd -P); then
    obelus_xdg_refuse "$1" "$2=$3 is not an existing directory"
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
  if [ -n "${HOME:-}" ] && _rhome=$(cd "$HOME" 2>/dev/null && pwd -P); then
    case "$_rhome/" in "$_rroot"/*)
      obelus_xdg_refuse "$_who" "OBELUS_TEST_ROOT=$_root contains HOME ($HOME)"
      return 3
      ;;
    esac
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
  obelus_xdg_inside "$_who" "NVIM_LOG_FILE's directory" "$(dirname "$NVIM_LOG_FILE")" || return 3
  if [ -n "${OBELUS_UI_TMPBASE:-}" ]; then
    obelus_xdg_inside "$_who" OBELUS_UI_TMPBASE "$OBELUS_UI_TMPBASE" || return 3
  fi
  return 0
}
