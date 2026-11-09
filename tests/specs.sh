#!/bin/sh
# The behaviour-spec entry point (`make specs`): refuse unless every XDG path is
# inside a private OBELUS_TEST_ROOT (tests/private.sh sets one up), THEN start
# nvim. The check must come first: Neovim itself writes at startup (its log in
# $XDG_STATE_HOME/nvim, its server socket under $XDG_RUNTIME_DIR or $TMPDIR)
# before any Lua runs, so launching `nvim -c "luafile tests/run.lua"` directly
# can only be guarded from inside, after those startup files (tests/xdg_guard.lua
# still refuses before obelus or the specs write anything).
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/xdg_guard.sh"
obelus_xdg_guard tests/specs.sh || exit 3
exec "${OBELUS_NVIM:-nvim}" --headless -n -u NONE -i NONE -c "luafile $here/run.lua"
