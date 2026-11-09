#!/bin/sh
# Guard-mutation proof for the UI snapshot harness (see tests/ui/MUTATIONS.md).
# Copies the working tree to a private temp dir, applies ONE small visual
# mutation at a time to the copy's lua/, runs the harness there and expects it to
# FAIL. The real tree is never modified. Exit 0 = every mutation was caught.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
work=$(mktemp -d "${base%/}/obelus-mut.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# literal (non-pattern) single replacement; fails if `old` is absent
cat >"$work/replace.lua" <<'EOF'
local path, old, new = arg[1], arg[2], arg[3]
local f = assert(io.open(path, "rb"))
local s = f:read("*a")
f:close()
local i, j = s:find(old, 1, true)
if not i then
  io.stderr:write("mutation anchor not found in " .. path .. ": " .. old .. "\n")
  os.exit(3)
end
f = assert(io.open(path, "wb"))
f:write(s:sub(1, i - 1) .. new .. s:sub(j + 1))
f:close()
EOF

caught=0
missed=0
mutate() { # name file old new
  name=$1 file=$2 old=$3 new=$4
  rm -rf "$work/tree"
  mkdir "$work/tree"
  (cd "$repo" && tar cf - lua tests) | (cd "$work/tree" && tar xf -)
  rm -rf "$work/tree/tests/ui/actual"
  if ! nvim -l "$work/replace.lua" "$work/tree/$file" "$old" "$new"; then
    echo "SETUP-ERROR $name"
    missed=$((missed + 1))
    return
  fi
  out=$(OBELUS_UI_TMPBASE="$work" sh "$work/tree/tests/ui/run.sh" 2>&1)
  if [ $? -ne 0 ]; then
    caught=$((caught + 1))
    first=$(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-110)
    nfail=$(printf '%s\n' "$out" | grep -c '^FAIL')
    echo "CAUGHT  $name  ($nfail snapshot(s) differ; first: $first)"
  else
    missed=$((missed + 1))
    echo "MISSED  $name"
  fi
}

mutate "band-highlight-group" lua/obelus/render.lua \
  'opts.line_hl_group = "ObelusThreadBg"' 'opts.line_hl_group = "ObelusThreadBar"'
mutate "virt-text-column" lua/obelus/config.lua \
  'preview_prefix = "  ▌ "' 'preview_prefix = "   ▌ "'
mutate "spinner-frame" lua/obelus/progress.lua \
  '"⠋", "⠙", "⠹"' '"⠋", "⠚", "⠹"'
mutate "panel-width" lua/obelus/panel.lua \
  'math.floor(vim.o.columns * 0.42)' 'math.floor(vim.o.columns * 0.43)'
mutate "markdown-bold-conceal" lua/obelus/thread.lua \
  'bs and line:sub(bs + 2, be - 2)' 'bs and line:sub(bs, be)'
mutate "band-hint-string" lua/obelus/render.lua \
  'pfx .. "K up · " .. pfx .. "J down"' 'pfx .. "K up | " .. pfx .. "J down"'
mutate "composer-footer-label" lua/obelus/render.lua \
  'add("save", "<C-s>", "save")' 'add("save", "<C-s>", "store")'
mutate "bubble-tint-colour" lua/obelus/config.lua \
  'tint = 0.08,' 'tint = 0.09,'
mutate "spinner-priority-extmark-only" lua/obelus/progress.lua \
  'priority = 4500,' 'priority = 4400,'
mutate "keymap-desc" lua/obelus/init.lua \
  'desc = "obelus: toggle keybind hints",' 'desc = "obelus: toggle hints",'

echo "mutations: $caught caught, $missed missed"
[ "$missed" -eq 0 ]
