-- Tiny dependency-free test framework + fixtures for the obelus specs.
-- Run via `make test` (see tests/run.lua). Assertions raise on failure; the runner
-- tallies pass/fail and sets the process exit code.

local H = { passed = 0, failed = 0, skipped = 0, failures = {}, skips = {}, suite = "?" }

function H.describe(name)
  H.suite = name
end

-- Runs after EVERY spec (pass or fail) so one failed assertion can't leak panel
-- windows/timers into the next spec: close the panel/preview, stop the progress
-- spinner timer, leave insert mode, and close any stray floating windows a spec
-- opened directly (bypassing panel.close/hide_preview).
local function teardown()
  pcall(function()
    require("obelus.panel").close()
  end)
  pcall(function()
    require("obelus.panel").hide_preview()
  end)
  pcall(function()
    -- _reset (not just _stop): a spec that died between progress.start() and
    -- finish() would leave its job "running" forever, inflating the count for
    -- every later spec in this same process
    require("obelus.progress")._reset()
  end)
  pcall(vim.cmd, "stopinsert")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

function H.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passed = H.passed + 1
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = string.format("[%s] %s\n      %s", H.suite, name, tostring(err))
  end
  teardown()
end

-- run `fn` only when `cond` is true, else count it as skipped (e.g. markview absent)
function H.it_when(cond, name, fn)
  if cond then
    H.it(name, fn)
  else
    H.skipped = H.skipped + 1
    H.skips[#H.skips + 1] = string.format("[%s] %s", H.suite, name)
  end
end

-- Pumps the main loop (so scheduled callbacks/timers — e.g. progress ticks, deferred
-- fills — actually run) until `cond()` returns true or `ms` elapses (default 1000ms),
-- polling every 10ms. Returns vim.wait's (ok, why) pair — see :h vim.wait().
function H.wait_for(cond, ms)
  return vim.wait(ms or 1000, cond, 10)
end

function H.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    error(
      (msg or "values differ") .. "\n      expected: " .. vim.inspect(want) .. "\n      got:      " .. vim.inspect(got),
      2
    )
  end
end

function H.ok(v, msg)
  if not v then
    error((msg or "expected truthy") .. ", got " .. vim.inspect(v), 2)
  end
end

function H.is_nil(v, msg)
  if v ~= nil then
    error((msg or "expected nil") .. ", got " .. vim.inspect(v), 2)
  end
end

function H.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((msg or ("expected to contain " .. vim.inspect(needle))) .. "\n      in: " .. vim.inspect(haystack), 2)
  end
end

-- Fresh obelus state with an isolated temp data root; safe to call per-test.
function H.fresh(opts)
  -- reset the wall-clock knobs a prior spec may have shrunk, so it can't leak into
  -- this one (specs shrink these instead of sleeping past real frames/throttles)
  require("obelus.panel")._timing.fill_throttle = 160
  require("obelus.panel")._timing.preview_settle = 180
  require("obelus.progress")._timing.tick = 100
  -- session UI toggles (renderer/mode/band_style/show_resolved/hints) now SURVIVE
  -- obelus.setup() by design (config surface refactor) — reset them here instead,
  -- so a prior spec's toggle_mode()/set_renderer()/etc. can't leak into this one.
  require("obelus.config").ui = { renderer = nil, mode = nil, band_style = nil, show_resolved = nil, hints = nil }
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local obelus = require("obelus")
  -- sandbox OFF by default in the harness: legacy spawn specs assert the raw
  -- CLI argv / rely on synchronous ENOENT for a missing binary — both change
  -- under the OS wrapper. Sandbox specs opt back in via permissions.enabled.
  obelus.setup(vim.tbl_deep_extend("force", {
    root = root,
    persist = { backend = "data", auto = false },
    transport = { cli = { permissions = { enabled = false } } },
  }, opts or {}))
  local store = require("obelus.store")
  store.reset_root()
  store.clear()
  return {
    obelus = obelus,
    store = store,
    config = require("obelus.config"),
    root = root,
  }
end

-- A comment record with sensible defaults; override any field.
function H.comment(over)
  return vim.tbl_deep_extend("force", {
    file = "/tmp/obelus-test/sample.lua",
    range = { sl = 1, el = 1 },
    kind = "line",
    selected_text = { "local x = 1" },
    comment = "please review this",
  }, over or {})
end

function H.report()
  io.write("\n")
  for _, f in ipairs(H.failures) do
    io.write("FAIL " .. f .. "\n")
  end
  for _, s in ipairs(H.skips) do
    io.write("SKIP " .. s .. "\n")
  end
  io.write(string.format("\nobelus tests: %d passed, %d failed, %d skipped\n", H.passed, H.failed, H.skipped))
  return H.failed == 0
end

return H
