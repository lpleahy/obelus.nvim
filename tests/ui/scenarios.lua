-- UI snapshot scenarios. Each runs in a FRESH child nvim (tests/ui/run.lua), at
-- every size, from the same synthetic fixture: no agents, no network, no user
-- config. The fake transport (tests/fake.lua) drives streaming exactly like
-- transport/cli.lua does, synchronously.
--
-- A scenario only arranges state; capture happens afterwards in child.lua. Keep
-- every scenario deterministic: no wall-clock waits, only C.settle() (a counted
-- number of event-loop turns) for deferred work.
local C = _G.__ui

local S = { list = {} }

local function scenario(name, fn, opts)
  opts = opts or {}
  S.list[#S.list + 1] = { name = name, fn = fn, kind = opts.kind, sizes = opts.sizes }
end

-- the source file every scenario annotates (plain buffer: no filetype/syntax, so
-- the screen shows obelus's decorations, not a syntax theme)
local SOURCE = {
  "-- sample.lua: a small module the fixtures annotate",
  "local M = {}",
  "",
  "local function clamp(x, lo, hi)",
  "  if x < lo then",
  "    return lo",
  "  end",
  "  return math.min(x, hi)",
  "end",
  "",
  "function M.scale(values, factor)",
  "  local out = {}",
  "  for i, v in ipairs(values) do",
  "    out[i] = clamp(v * factor, 0, 100)",
  "  end",
  "  return out",
  "end",
  "",
  "function M.sum(values)",
  "  local total = 0",
  "  for _, v in ipairs(values) do",
  "    total = total + v",
  "  end",
  "  return total",
  "end",
  "",
  "return M",
}

local LONG_AGENT = table.concat({
  "Good catch. `clamp` is applied **after** the multiply, so a negative `factor` silently",
  "maps every value to `0` instead of raising. Two options:",
  "",
  "1. Validate `factor` up front and `error()` on a negative value.",
  "2. Clamp the *input* first, then scale — this keeps the contract but changes rounding.",
  "",
  "```lua",
  "function M.scale(values, factor)",
  '  assert(factor >= 0, "factor must be non-negative")',
  "  local out = {}",
  "  for i, v in ipairs(values) do",
  "    out[i] = clamp(v * factor, 0, 100)",
  "  end",
  "  return out",
  "end",
  "```",
  "",
  "| option | breaks callers | cost |",
  "| --- | --- | --- |",
  "| validate | yes, on bad input | O(1) |",
  "| clamp first | no | O(n) |",
  "",
  "> I'd go with option 1: it fails loudly, which matches `M.sum`'s behaviour.",
}, "\n")

-- Fresh obelus over the fixed project root (the child's cwd), builtin renderer,
-- fake transport installed, and every wall-clock knob pinned:
--   panel fill throttle / preview settle -> 0 (run on the next loop turn)
--   progress tick -> effectively never repeats: the timer's FIRST tick fires
--   immediately (frame 1 -> 2) and the next would be ~11 days later, so every
--   spinner glyph on screen is frame 2 ("⠙") — frozen, not sampled.
local function fresh(opts)
  local H = require("helpers")
  _G.T = H
  local root = vim.fn.getcwd()
  local base = {
    root = root,
    render = { renderer = "builtin" },
    transport = { dispatch = "fake" },
  }
  local ctx = H.fresh(vim.tbl_deep_extend("force", base, opts or {}))
  local F = require("fake")
  F.reset()
  F.install()
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.panel")._timing.preview_settle = 0
  require("obelus.progress")._timing.tick = 1e9
  ctx.F = F
  vim.fn.writefile(SOURCE, root .. "/sample.lua")
  vim.cmd("edit sample.lua")
  ctx.buf = vim.api.nvim_get_current_buf()
  ctx.file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  return ctx
end

local function add(ctx, over)
  local sl, el = over.sl or 11, over.el or over.sl or 11
  over.sl, over.el = nil, nil
  local sel = {}
  for l = sl, el do
    sel[#sel + 1] = SOURCE[l]
  end
  return ctx.store.add(vim.tbl_deep_extend("force", {
    file = ctx.file,
    range = { sl = sl, el = el },
    kind = "line",
    selected_text = sel,
    comment = "negative factors are clamped to 0 silently — intended?",
  }, over))
end

local function cursor(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col or 0 })
  require("obelus.render").on_cursor()
end

local function wait_chat(panel)
  vim.wait(10000, function()
    local g = panel.geom()
    return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
  end, 1)
end

-- ── inline annotations (bands disabled: signs + line tint + eol preview) ──────
scenario("annotations_linewise_charwise", function()
  local ctx = fresh({ render = { bands = { enabled = false } } })
  add(ctx, { sl = 11, el = 13 })
  add(ctx, {
    sl = 20,
    el = 20,
    kind = "char",
    range = { sl = 20, el = 20, sc = 9, ec = 13 },
    selected_text = { "total" },
    comment = "name this `sum`?\nsecond line of the note",
  })
  add(ctx, { sl = 4, ask = true, comment = "why not math.max(lo, math.min(x, hi))?" })
  require("obelus.render").render_all()
  cursor(1)
  C.settle()
end)

function S.run(name)
  for _, sc in ipairs(S.list) do
    if sc.name == name then
      sc.fn()
      return true
    end
  end
  error("unknown scenario " .. name)
end

return S
