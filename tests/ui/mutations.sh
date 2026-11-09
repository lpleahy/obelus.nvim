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
invalid=0

fresh_tree() {
  rm -rf "$work/tree"
  mkdir "$work/tree"
  (cd "$repo" && tar cf - lua tests) | (cd "$work/tree" && tar xf -)
  rm -rf "$work/tree/tests/ui/actual"
}

# Preflight: the UNMODIFIED tree must pass cleanly in this environment (right
# nvim version, baselines present, transport healthy). Otherwise every mutation
# would "fail" for an unrelated reason — refuse to report anything.
fresh_tree
out=$(OBELUS_UI_TMPBASE="$work" sh "$work/tree/tests/ui/run.sh" 2>&1)
if [ $? -ne 0 ]; then
  echo "INVALID ENVIRONMENT: the unmodified tree does not pass; no mutation can be judged."
  printf '%s\n' "$out" | grep -E '^(FAIL|ERROR)' | head -5
  exit 2
fi
echo "preflight: unmodified tree passes ($(printf '%s\n' "$out" | tail -1))"

# A mutation is CAUGHT only when the harness ran to comparison and reported a
# baseline mismatch (FAIL ... differs from baseline) with no harness ERROR; a
# harness error under a mutation is INVALID (it proves nothing either way).
mutate() { # name file old new
  name=$1 file=$2 old=$3 new=$4
  fresh_tree
  if ! nvim -l "$work/replace.lua" "$work/tree/$file" "$old" "$new"; then
    echo "INVALID $name  (mutation anchor not found)"
    invalid=$((invalid + 1))
    return
  fi
  out=$(OBELUS_UI_TMPBASE="$work" sh "$work/tree/tests/ui/run.sh" 2>&1)
  rc=$?
  nfail=$(printf '%s\n' "$out" | grep -c '^FAIL .*differs from baseline')
  nerr=$(printf '%s\n' "$out" | grep -c '^ERROR')
  if [ $rc -eq 0 ]; then
    missed=$((missed + 1))
    echo "MISSED  $name"
  elif [ "$nerr" -gt 0 ] || [ "$nfail" -eq 0 ]; then
    invalid=$((invalid + 1))
    echo "INVALID $name  (harness error, not a comparison: $(printf '%s\n' "$out" | grep -E '^(ERROR|FAIL)' | head -1 | cut -c1-110))"
  else
    caught=$((caught + 1))
    first=$(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-110)
    echo "CAUGHT  $name  ($nfail snapshot(s) differ; first: $first)"
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

# from the independent review (setup/registration blind spots, float stacking)
mutate "setup-overwrites-default-Y" lua/obelus/init.lua \
  'function M.setup(opts)' 'function M.setup(opts)
  vim.keymap.set("n", "Y", "dd")'
mutate "setup-ungrouped-autocmd" lua/obelus/init.lua \
  'function M.setup(opts)' 'function M.setup(opts)
  vim.api.nvim_create_autocmd("BufEnter", { desc = "review probe", callback = function() end })'
mutate "setup-new-namespace" lua/obelus/init.lua \
  'function M.setup(opts)' 'function M.setup(opts)
  vim.api.nvim_create_namespace("obelus_api_review")'
mutate "chat-float-zindex" lua/obelus/config.lua \
  'CHAT = 50,' 'CHAT = 51,'
mutate "setup-overwrites-highlight" lua/obelus/init.lua \
  'function M.setup(opts)' 'function M.setup(opts)
  vim.api.nvim_set_hl(0, "Search", { link = "IncSearch" })'

# from the re-review: same-description callback swaps and a first-use overwrite
mutate "keymap-callback-swap-same-desc" lua/obelus/init.lua \
  'suffix = "?",
    modes = "n",
    rhs = function()
      M.toggle_hints()' 'suffix = "?",
    modes = "n",
    rhs = function()
      M.toggle_mode()'
mutate "command-callback-swap-same-desc" lua/obelus/init.lua \
  'cmd("ObelusEdit", function()
    M.edit()' 'cmd("ObelusEdit", function()
    M.delete()'
mutate "first-use-overwrites-default-Y" lua/obelus/init.lua \
  'function M.quick_reply(id)' 'function M.quick_reply(id)
  vim.keymap.set("n", "Y", "dd", { desc = "review lazy overwrite" })'

# Harness mutations: patch the copy's supervisor and run the self-test cases that
# guard it (tests/ui/selftest.sh, OBELUS_UI_SELFTEST_ONLY). CAUGHT = the unmodified
# copy passes those cases and the mutated copy fails one of them by name.
harness_mutate() { # name file old new cases
  name=$1 file=$2 old=$3 new=$4 cases=$5
  fresh_tree
  out=$(OBELUS_UI_TMPBASE="$work" OBELUS_UI_SELFTEST_ONLY="$cases" sh "$work/tree/tests/ui/selftest.sh" 2>&1)
  if [ $? -ne 0 ]; then
    invalid=$((invalid + 1))
    echo "INVALID $name  (unmodified self-test cases fail: $(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-110))"
    return
  fi
  if ! nvim -l "$work/replace.lua" "$work/tree/$file" "$old" "$new"; then
    echo "INVALID $name  (mutation anchor not found)"
    invalid=$((invalid + 1))
    return
  fi
  out=$(OBELUS_UI_TMPBASE="$work" OBELUS_UI_SELFTEST_ONLY="$cases" sh "$work/tree/tests/ui/selftest.sh" 2>&1)
  rc=$?
  nfail=$(printf '%s\n' "$out" | grep -c '^FAIL  parent-exit')
  if [ $rc -eq 0 ]; then
    missed=$((missed + 1))
    echo "MISSED  $name"
  elif [ "$nfail" -eq 0 ]; then
    invalid=$((invalid + 1))
    echo "INVALID $name  (failed for another reason: $(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-110))"
  else
    caught=$((caught + 1))
    echo "CAUGHT  $name  ($nfail self-test failure(s); first: $(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-90))"
  fi
}

# R4-B1: the supervisor releases the group without stopping its remaining members
harness_mutate "supervisor-skips-member-teardown" tests/ui/supervise.pl \
  '
teardown();
' '
' parent-exit,parent-exit-harness

echo "mutations: $caught caught, $missed missed, $invalid invalid"
[ "$missed" -eq 0 ] && [ "$invalid" -eq 0 ]
