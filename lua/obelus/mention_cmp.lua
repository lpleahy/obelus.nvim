-- nvim-cmp source for "@" file mentions. Registered lazily by mention.lua
-- (mention.attach -> resolve_engine -> register_cmp) the first time
-- input.mention.completion resolves to cmp for this session — never required
-- directly by user config. nvim-cmp isn't installed alongside this repo's dev
-- env, so this targets the STANDARD, long-stable nvim-cmp source contract
-- (hrsh7th/nvim-cmp `lua/cmp/source.lua`): new(), get_trigger_characters(),
-- get_keyword_pattern(), complete(params, callback). cmp accepts LSP-shaped
-- textEdit on completion items, same shape mention_blink.lua builds.

local mention = require("obelus.mention")

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  return { "@" }
end

-- Permissive: an "@" followed by any run of path characters, so cmp's own
-- keyword boundary doesn't cut the query short at "." or "/" (cmp compiles this
-- as a Vim regex via vim.regex).
function M:get_keyword_pattern()
  return [[\%(@\)\%([[:keyword:]./\\_-]\)*]]
end

-- params.context is cmp.Context (lua/cmp/context.lua): cursor_before_line is the
-- current line's text up to (not including) the cursor, so its length IS the
-- 0-based cursor column; cursor.line is the 0-based row.
function M:complete(params, callback)
  local ctx = params.context
  local line = ctx.cursor_before_line
  local col0 = #line
  local row0 = ctx.cursor.line

  local at_col0 = mention._at_token(line, col0)
  if not at_col0 then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local root = require("obelus.store").root()
  local items = {}
  for i, item in ipairs(mention._items(root)) do
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

  -- same rationale as the blink adapter: path chars break cmp's incremental
  -- filter, so force a re-query every keystroke rather than trust a stale list.
  callback({ items = items, isIncomplete = true })
end

return M
