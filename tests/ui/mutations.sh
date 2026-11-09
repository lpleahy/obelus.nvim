#!/bin/sh
# Guard-mutation proof for the UI snapshot harness (see tests/ui/MUTATIONS.md).
# Copies the working tree to a private temp dir, applies ONE small visual
# mutation at a time to the copy's lua/, runs the harness there and expects it to
# FAIL. The real tree is never modified. Exit 0 = every mutation was caught.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../xdg_guard.sh"
obelus_xdg_guard tests/ui/mutations.sh || exit 3 # containment first (tests/private.sh)
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
# OBELUS_MUT_ONLY=name,name: run only these mutations (the preflight still runs)
want_mut() {
  [ -z "${OBELUS_MUT_ONLY:-}" ] && return 0
  case ",$OBELUS_MUT_ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

mutate() { # name file old new
  name=$1 file=$2 old=$3 new=$4
  want_mut "$name" || return 0
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
harness_mutate() { # name file old new cases [failure-prefix]
  name=$1 file=$2 old=$3 new=$4 cases=$5 fpat=${6:-parent-exit}
  want_mut "$name" || return 0
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
  nfail=$(printf '%s\n' "$out" | grep -c "^FAIL  $fpat")
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

# Containment: the nvim-side guard is removed, so the spec runner runs against
# the decoy home and writes into it; the shell guard is removed from run.sh
harness_mutate "xdg-guard-lua-removed" tests/xdg_guard.lua \
  'who = who or "obelus tests"' 'do return true end' xdg-guard xdg-guard
harness_mutate "xdg-guard-specs-sh-removed" tests/specs.sh \
  'obelus_xdg_guard tests/specs.sh || exit 3' ':' xdg-guard xdg-guard

# Behaviour-guard mutations (obelus.api): these guards draw nothing, so the
# behaviour specs judge them instead of the snapshots. Attribution is by NAME:
#   CAUGHT  every expected regression (test-name substrings, "|"-separated)
#           fails. Any OTHER failing test triggers a paired pristine control
#           (the unmodified tree, run again right away): if that control fails
#           too, the run is INVALID (an unrelated or flaky failure), otherwise
#           the extra failures are recorded as collateral of the mutation.
#   MISSED  the specs pass, or an expected regression did not fail.
# Every failing test name is printed.
run_specs() {
  (cd "$work/tree" && sh tests/specs.sh 2>&1)
}
fail_names() {
  printf '%s\n' "$1" | sed -n 's/^FAIL \[[^]]*\] //p'
}
spec_preflight=""
spec_mutate() { # name file old new expected
  name=$1 file=$2 old=$3 new=$4 expected=$5
  want_mut "$name" || return 0
  if [ -z "$spec_preflight" ]; then
    fresh_tree
    if ! out=$(run_specs); then
      echo "INVALID ENVIRONMENT: the unmodified specs do not pass; spec mutations cannot be judged."
      printf '%s\n' "$out" | grep '^FAIL' | head -5
      exit 2
    fi
    spec_preflight=done
  fi
  fresh_tree
  if ! nvim -l "$work/replace.lua" "$work/tree/$file" "$old" "$new"; then
    echo "INVALID $name  (mutation anchor not found)"
    invalid=$((invalid + 1))
    return
  fi
  out=$(run_specs)
  rc=$?
  names=$(fail_names "$out")
  if [ $rc -eq 0 ]; then
    missed=$((missed + 1))
    echo "MISSED  $name  (the specs pass)"
    return
  fi
  missing="" rest=$expected
  while [ -n "$rest" ]; do
    e=${rest%%|*}
    [ "$e" = "$rest" ] && rest= || rest=${rest#*|}
    printf '%s\n' "$names" | grep -qF -- "$e" || missing="$missing [$e]"
  done
  others=$(printf '%s\n' "$names" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    hit=0 rest=$expected
    while [ -n "$rest" ]; do
      e=${rest%%|*}
      [ "$e" = "$rest" ] && rest= || rest=${rest#*|}
      case $n in (*"$e"*) hit=1 ;; esac
    done
    [ $hit -eq 0 ] && printf '%s\n' "$n"
  done)
  if [ -n "$missing" ]; then
    missed=$((missed + 1))
    echo "MISSED  $name  (expected regression did not fail:$missing)"
    printf '%s\n' "$names" | sed 's/^/          failed: /'
    return
  fi
  note=""
  if [ -n "$others" ]; then
    fresh_tree
    if ! ctl=$(run_specs); then
      invalid=$((invalid + 1))
      echo "INVALID $name  (unrelated failures: the paired pristine control fails too)"
      fail_names "$ctl" | sed 's/^/          control failed: /'
      return
    fi
    note=" + $(printf '%s\n' "$others" | grep -c .) collateral (pristine control clean)"
  fi
  caught=$((caught + 1))
  echo "CAUGHT  $name  (named regression fails$note)"
  printf '%s\n' "$names" | sed 's/^/          failed: /'
}

# a backend thread falls through to obelus's own transports (the CLI)
spec_mutate "api-cli-fallthrough" lua/obelus/transport/init.lua \
  'if api and api._active() then' 'if false then' \
  'a turn streams through the backend transport'
# the CLI transport's own refusal of non-file/backend threads is removed
spec_mutate "api-cli-guard-removed" lua/obelus/transport/cli.lua \
  'if not store.all_agent_eligible(payload.comments, payload.opts and payload.opts.actions_comments) then' 'if false then' \
  'restart with a claimed-scheme record in the JSONL'
# the eligibility predicate stops consulting the claimed schemes
spec_mutate "api-eligibility-ignores-claims" lua/obelus/store.lua \
  'return not scheme or not require("obelus.claims").blocks(scheme)' 'return true' \
  'claim_schemes with no backend'
# unclassifiable claims fail OPEN instead of closed
spec_mutate "claims-corrupt-fails-open" lua/obelus/claims.lua \
  'return corrupt or set[scheme] == true' 'return set[scheme] == true' \
  'malformed claims fail closed'
# a claim is never persisted (it would not survive a restart)
spec_mutate "claims-not-persisted" lua/obelus/claims.lua \
  'local fd, _, code = uv.fs_open(path, "wx", 420)' 'local fd, _, code = nil, nil, "EEXIST"' \
  'a claim persists: after a real restart'
# a malformed claims entry (bad name, not a regular file) is ignored, not fail-closed
spec_mutate "claims-malformed-fails-open" lua/obelus/claims.lua \
  'corrupt, why = true, "unexpected entry "' 'corrupt, why = false, "unexpected entry "' \
  'malformed claims fail closed'
# a stat error other than ENOENT is taken as "no claims"
spec_mutate "claims-stat-error-fails-open" lua/obelus/claims.lua \
  'if code == "ENOENT" then' 'if true then' \
  'malformed claims fail closed'
# a competing creator's EEXIST is taken as a failure (R3-B4)
spec_mutate "claims-mkdir-eexist-fails" lua/obelus/claims.lua \
  'local again = uv.fs_stat(dir) -- someone else may have created it meanwhile' 'local again = nil' \
  "a competing creator's EEXIST"
# the parents of newly created claims directories are never synced (R4-N1)
spec_mutate "claims-parents-not-synced" lua/obelus/claims.lua \
  'saved = sync_dir(vim.fn.fnamemodify(d, ":h")) and saved' 'saved = saved' \
  'a fresh claim syncs the marker, the claims dir and the parent'
# an existing marker is reported durable without a successful sync (R3-N1)
spec_mutate "claims-sync-not-verified" lua/obelus/claims.lua \
  'local ok = sync(rfd)' 'local ok = true' \
  'a claim whose sync fails is not reported durable'
# approve with no UI opens a float instead of denying at once
spec_mutate "approve-headless-falls-through" lua/obelus/approve.lua \
  'if not M.available() then
    return finish(false, a)' 'if false then
    return finish(false, a)' \
  'approve: headless (no UI) denies at once'
# no unarmed phase: focusing arms at once, so typeahead approves
spec_mutate "approve-no-unarmed-phase" lua/obelus/approve.lua \
  'a.armed = false' 'a.armed = true' \
  'approve: typing and typeahead in the unarmed window are ignored'
# the drain is removed: input queued while unarmed survives into the armed prompt
spec_mutate "approve-no-drain" lua/obelus/approve.lua \
  'local ok, key = pcall(vim.fn.getchar, 0)' 'local ok, key = true, 0' \
  'approve: input queued while unarmed, with the loop blocked'
# the drain cap runs out and the prompt arms anyway with input still queued
spec_mutate "approve-cap-exhaustion-arms" lua/obelus/approve.lua \
  'finish(false, a) -- cap exhausted: dismissed
  return false' 'return true' \
  'approve: 15001 keys queued BETWEEN the drains'
# the same drain removal, judged by the real-UI snapshot (api_approve_queued_typeahead)
mutate "approve-no-drain-ui" lua/obelus/approve.lua \
  'local ok, key = pcall(vim.fn.getchar, 0)' 'local ok, key = true, 0'
# Enter goes back to the armed-only path: ignored while unarmed
spec_mutate "approve-enter-unarmed-ignored" lua/obelus/approve.lua \
  'for _, key in ipairs({ "<CR>", "q", "<Esc>", "<C-c>" }) do' 'for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do' \
  'approve: Enter while still unarmed denies at once'
# the same, judged by the real-UI snapshot (api_approve_enter_unarmed)
mutate "approve-enter-unarmed-ignored-ui" lua/obelus/approve.lua \
  'for _, key in ipairs({ "<CR>", "q", "<Esc>", "<C-c>" }) do' 'for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do'
# focus_hint accepts Unicode format controls (bidi overrides, isolates, …)
spec_mutate "approve-hint-allows-format-controls" lua/obelus/approve.lua \
  'or (cp >= 0x2028 and cp <= 0x202E)' 'or false' \
  'approve: focus_hint rejects bidi, format and C1 controls'
# a handle's focus acts on whichever prompt is open (not prompt-scoped)
spec_mutate "approve-handle-focus-not-scoped" lua/obelus/approve.lua \
  'return M._focus(a)' 'return M._focus(active)' \
  'approve handle: A open, B queued'
# every send gets a fresh turn_id, so a retry of a stored turn becomes a new message
spec_mutate "api-turn-id-not-reused" lua/obelus/api.lua \
  'if not (draft.turn_id and draft._api_sent_text == draft.text) then' 'if true then' \
  'turn_id: stored then the answer failed'
# an edited draft keeps its old turn id until the next send (R3-B1)
spec_mutate "api-edit-keeps-turn-id" lua/obelus/store.lua \
  'if tail.turn_id and tail.text ~= text and package.loaded["obelus.api"] then' 'if false then' \
  'turn_id: fail → edit → refresh → dispatch'
# a send's callback no longer checks that it owns its record and job
spec_mutate "api-generation-check-removed" lua/obelus/api.lua \
  'and require("obelus.store").get(st.id) == st.c
    and require("obelus.jobs").get(st.id) == st.spec' 'and true' \
  'a callback that no longer owns its record and job changes nothing'
# refresh trusts a list() result after list() re-entered and replaced the registration
spec_mutate "api-refresh-no-revalidation" lua/obelus/api.lua \
  'if backends[name] ~= b or not vim.api.nvim_buf_is_valid(bufnr) or abspath(bufnr) ~= file then' 'if false then' \
  're-entrant list(): a replacement registered inside the old list()'
# a create() result is adopted after its registration was replaced (R3-B2)
spec_mutate "api-create-result-relabelled" lua/obelus/api.lua \
  'if backends[name] ~= b or not vim.api.nvim_buf_is_valid(bufnr) or abspath(bufnr) ~= c.file then' 'if false then' \
  're-entrant create(): a replacement with a colliding id'
# a match() answer is trusted after match() removed or replaced its registration (R3-B2)
spec_mutate "api-match-stale-owner" lua/obelus/api.lua \
  'if not same then' 'if false then' \
  're-entrant match()'
# the stored reason is not used when send() returns its cancel function late
spec_mutate "api-late-cancel-loses-reason" lua/obelus/api.lua \
  'fire_cancel(st) -- cancelled/invalidated while send() ran: now, with its reason' 'if st.done then pcall(cancel) end' \
  'terminated INSIDE send()'
# every cancel is reported as "user": a reload/replace would make the backend revoke live work
spec_mutate "api-cancel-reason-always-user" lua/obelus/api.lua \
  'local reason = { reason = (kind == "cancel" and cancel_reason == "user") and "user" or "invalidate" }' 'local reason = { reason = "user" }' \
  'cancel reasons: an explicit user cancel'
# the explicit cancel no longer says it was the user's
spec_mutate "review-cancel-without-user-reason" lua/obelus/review.lua \
  'jobs.cancel(c.id, "user")' 'jobs.cancel(c.id)' \
  'cancel reasons: an explicit user cancel'
# replacing/unregistering a backend no longer cancels its sends
spec_mutate "api-replace-keeps-old-sends" lua/obelus/api.lua \
  'return st.b == old' 'return false' \
  'unregister then re-register'
# a backend's threads leak into obelus's JSONL
spec_mutate "api-thread-saved-to-jsonl" lua/obelus/store.lua \
  'goto continue -- obelus.api' 'local _ = nil -- obelus.api' \
  'never into the JSONL'

# Containment guards (R3-B3), judged by named self-test failures
harness_mutate "xdg-guard-sh-defaults-by-spelling" tests/xdg_guard.sh \
  'case "$1/" in "$_d"/*)' 'case "$1/" in "$_d"/NEVER*)' xdg-guard "xdg-guard: private.sh, alias root"
harness_mutate "xdg-guard-lua-defaults-by-spelling" tests/xdg_guard.lua \
  'if path == real or inside(path, real) then' 'if false then' xdg-guard "xdg-guard: direct nvim run.lua, alias root"
harness_mutate "xdg-guard-sh-relative-allowed" tests/xdg_guard.sh \
  'obelus_xdg_refuse "$1" "$2=$3 is relative (it would follow the working directory)"
    return 3' ':' xdg-guard "xdg-guard: private.sh, relative XDG values"
harness_mutate "launcher-unsafe-tmpdir-base" tests/private.sh \
  'if ! base=$(safe_base "${TMPDIR:-/tmp}"); then' 'base=${TMPDIR:-/tmp}; if false; then' xdg-guard \
  "xdg-guard: private.sh, inherited TMPDIR in a home's .local"
harness_mutate "xdg-guard-log-symlink-allowed" tests/xdg_guard.sh \
  'if [ -L "$NVIM_LOG_FILE" ]; then' 'if false; then' xdg-guard "xdg-guard: private.sh, log file is a symlink"

echo "mutations: $caught caught, $missed missed, $invalid invalid"
[ "$missed" -eq 0 ] && [ "$invalid" -eq 0 ]
