-- panel: functional open/close of the chat surface + renderer selection.
T.describe("panel")

local function chat_buffer()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "obelus_reply" then
      local pw = vim.api.nvim_win_get_config(w).win
      pw = (type(pw) == "table") and (pw[false] or pw[1] or pw[true]) or pw
      if pw and vim.api.nvim_win_is_valid(pw) then
        return vim.api.nvim_win_get_buf(pw), w
      end
    end
  end
end

T.it("set_renderer writes the session override (config.ui), not config.options", function()
  T.fresh()
  local obelus = require("obelus")
  local config = require("obelus.config")
  obelus.set_renderer("builtin")
  T.eq(config.ui.renderer, "builtin")
  T.is_nil(config.options.render.renderer) -- config.options is untouched
  obelus.set_renderer("treesitter")
  T.eq(config.ui.renderer, "treesitter")
  T.is_nil(config.options.render.renderer)
  obelus.set_renderer("auto")
  T.eq(config.ui.renderer, "auto") -- an EXPLICIT auto override, distinct from nil ("never toggled")
  T.is_nil(config.options.render.renderer)
end)

T.it("set_renderer survives a re-run of setup() (e.g. a plugin manager reload)", function()
  local ctx = T.fresh()
  local obelus = require("obelus")
  local config = require("obelus.config")
  obelus.set_renderer("treesitter")
  T.eq(config.ui.renderer, "treesitter")
  -- re-setup rebuilds config.options from deepcopied defaults; the session override
  -- must NOT be reverted by it
  obelus.setup({ root = ctx.root, persist = { backend = "data", auto = false } })
  T.eq(config.ui.renderer, "treesitter")
end)

T.it("toggle_mode / toggle_band_style / toggle_resolved survive a re-run of setup()", function()
  local ctx = T.fresh()
  local obelus = require("obelus")
  local render = require("obelus.render")
  local config = require("obelus.config")

  T.eq(config.mode(), "inline")
  obelus.toggle_mode()
  T.eq(config.mode(), "sidebar")

  local style_before = render.band_style()
  render.toggle_band_style()
  local style_after = render.band_style()
  T.ok(style_after ~= style_before, "band style flipped")

  local resolved_before = render.resolved_shown()
  render.toggle_resolved()
  local resolved_after = render.resolved_shown()
  T.eq(resolved_after, not resolved_before)

  obelus.setup({ root = ctx.root, persist = { backend = "data", auto = false } })

  T.eq(config.mode(), "sidebar")
  T.eq(render.band_style(), style_after)
  T.eq(render.resolved_shown(), resolved_after)
end)

T.it("toggle_hints survives a re-run of setup()", function()
  local ctx = T.fresh()
  local obelus = require("obelus")
  local render = require("obelus.render")

  local hints_before = render.hints_shown()
  obelus.toggle_hints()
  local hints_after = render.hints_shown()
  T.eq(hints_after, not hints_before)

  obelus.setup({ root = ctx.root, persist = { backend = "data", auto = false } })

  T.eq(render.hints_shown(), hints_after)
end)

T.it("open_thread (builtin) opens the chat with a docked reply box", function()
  local ctx = T.fresh({ render = { renderer = "builtin" } })
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "acknowledged, nothing to change")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true) -- rooted popup
  vim.cmd("redraw")
  local chat_buf, input_win = chat_buffer()
  T.ok(input_win, "reply input window exists")
  T.ok(chat_buf, "chat buffer exists")
  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  T.contains(text, "acknowledged, nothing to change")
  panel.refresh() -- must not error on a settled thread
  panel.close()
end)
