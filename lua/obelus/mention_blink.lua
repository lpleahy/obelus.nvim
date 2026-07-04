-- blink.cmp source for "@" file mentions. Registered lazily by mention.lua
-- (mention.attach -> resolve_engine -> register_blink) the first time
-- input.mention.completion resolves to blink for this session — never required
-- directly by user config. Interface matched against the INSTALLED blink.cmp
-- (v1.10.2, lua/blink/cmp/sources/lib/types.lua's blink.cmp.Source class; see
-- sources/path/init.lua and sources/buffer/init.lua for the idiom): new(opts,
-- source_config), get_trigger_characters(), enabled(), get_completions(ctx,
-- callback) -> cancel fn | nil.

local mention = require("obelus.mention")

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  return { "@" }
end

-- Scoped to our filetype (add_filetype_source already restricts which
-- filetypes' provider lists include "obelus" at all — this is a second,
-- defensive check for whatever buffer blink is CURRENTLY completing in) and to
-- completion actually being the active mention engine (a live :ObelusReload-
-- style config change can turn it off without a nvim restart).
function M:enabled()
  if vim.bo.filetype ~= mention.FILETYPE then
    return false
  end
  local m = require("obelus.config").options.input.mention
  return m ~= false and m.completion ~= false
end

-- ctx: blink.cmp.Context (see completion/trigger/context.lua) — ctx.cursor =
-- { row1, col0 } (same shape as nvim_win_get_cursor), ctx.line = the current
-- line's text.
function M:get_completions(ctx, callback)
  local row0, col0 = ctx.cursor[1] - 1, ctx.cursor[2]
  local at_col0 = mention._at_token(ctx.line, col0)
  if not at_col0 then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return function() end
  end

  local root = require("obelus.store").root()
  local cancelled = false
  -- ASYNC on purpose: answering a cold cache with zero items made the menu skip
  -- the session's very first "@" (nothing to show until the next keystroke
  -- re-queried). Parking blink's callback on the file list means that first "@"
  -- pops as soon as fd answers — blink sources are async by contract.
  mention._items_async(root, function(core)
    if cancelled then
      return
    end
    local items = {}
    for i, item in ipairs(core) do
      items[i] = {
        label = item.label,
        kind = item.kind,
        filterText = item.filterText,
        textEdit = {
          range = {
            start = { line = row0, character = at_col0 + 1 },
            ["end"] = { line = row0, character = col0 },
          },
          newText = mention._escape(item.label),
        },
      }
    end
    -- Path characters (., /, -) break blink's own keyword boundary, so its
    -- incremental re-filter of a stale item list can't be trusted as the prefix
    -- grows past one of them — force a full re-query on every keystroke instead
    -- (both flags true). Same trade CodeCompanion's mention source makes.
    callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = items })
  end)
  return function()
    cancelled = true
  end
end

return M
