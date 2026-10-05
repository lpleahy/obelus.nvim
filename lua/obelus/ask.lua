-- Ask mode: "what does this line do?" as a one-key, read-only, streamed question
-- — the reading-flow counterpart to a review comment. Owns the two pieces that
-- differ from a review thread: WHAT surrounds the asked lines in the prompt (the
-- enclosing function via treesitter, not ±3 raw lines) and HOW the prompt is
-- framed (a question to answer, not feedback to address). The dispatch itself
-- rides review.do_respond's streaming path with opts.read_only — see
-- |obelus-ask|.
local config = require("obelus.config")
local format = require("obelus.format")

local M = {}

-- Treesitter node types that count as "the enclosing scope" across grammars —
-- matched by substring so the list doesn't need a per-language table:
--   function_declaration / function_definition / function_item / arrow_function /
--   function_expression / func_literal (go) / method_definition / method_declaration /
--   closure_expression (rust) / lambda (python, kotlin) / constructor_declaration
local SCOPE_WORDS = { "func", "method", "closure", "lambda", "constructor" }
-- ...except nodes that merely MENTION one and sit INSIDE the real scope: a
-- call / invocation / reference, a type, a signature, a declarator (C's
-- `main(void)`), a body (java's constructor_body), an index (lua's
-- method_index_expression), a parameter list, a name, a modifier
local NOT_SCOPE_WORDS = {
  "call",
  "invocation",
  "reference",
  "index",
  "type",
  "signature",
  "declarator",
  "body",
  "parameter",
  "argument",
  "name",
  "modifier",
  "static",
}

local function is_scope_type(t)
  for _, w in ipairs(NOT_SCOPE_WORDS) do
    if t:find(w, 1, true) then
      return false
    end
  end
  for _, w in ipairs(SCOPE_WORDS) do
    if t:find(w, 1, true) then
      return true
    end
  end
  return false
end

-- A scope node's own name, when the grammar exposes one as a `name` field
-- (lua/python/js/go/rust/java… do; C's lives under `declarator`, left nil).
local function node_name(node, bufnr)
  local ok, names = pcall(node.field, node, "name")
  if ok and names and names[1] then
    local ok2, text = pcall(vim.treesitter.get_node_text, names[1], bufnr)
    if ok2 and type(text) == "string" and text ~= "" and not text:find("\n") then
      return text
    end
  end
  return nil
end

-- The smallest function-like treesitter ancestor spanning lines sl..el (1-based,
-- inclusive), as { sl, el, name? } — nil when there is no parser for the buffer,
-- the tree has no such ancestor, or the only one is the root (a range that spans
-- several top-level functions).
---@return { sl: integer, el: integer, name?: string }|nil
function M.enclosing(bufnr, sl, el)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  local ok_parse, trees = pcall(parser.parse, parser)
  if not ok_parse or not trees or not trees[1] then
    return nil
  end
  local root = trees[1]:root()
  local last = vim.api.nvim_buf_get_lines(bufnr, el - 1, el, false)[1] or ""
  local node = root:named_descendant_for_range(sl - 1, 0, el - 1, math.max(#last - 1, 0))
  while node and node ~= root do
    if is_scope_type(node:type()) then
      local nsl, _, nel, ecol = node:range() -- 0-based; an end at col 0 means "up to the previous row"
      if ecol == 0 and nel > nsl then
        nel = nel - 1
      end
      return { sl = nsl + 1, el = nel + 1, name = node_name(node, bufnr) }
    end
    node = node:parent()
  end
  return nil
end

-- Trim a context span to at most `max` lines, keeping the asked lines inside and
-- as centred as the span allows. Returns the (possibly unchanged) span plus a
-- `trimmed` flag.
local function clamp(span, asl, ael, max)
  local len = span.el - span.sl + 1
  if len <= max then
    return span, false
  end
  local asked = ael - asl + 1
  if asked >= max then
    return { sl = asl, el = ael, name = span.name }, true
  end
  local sl = math.max(span.sl, asl - math.floor((max - asked) / 2))
  local el = sl + max - 1
  if el > span.el then
    el = span.el
    sl = el - max + 1
  end
  return { sl = sl, el = el, name = span.name }, true
end

-- Capture the context block for an ask on lines sl..el of bufnr, per the ask.*
-- knobs: { kind = "function"|"lines", sl, el, name?, trimmed, lines = string[] }.
-- Captured at ask time (the buffer as it is now) and stored on the record, so a
-- follow-up that must re-found the session gets the same context.
function M.context(bufnr, sl, el)
  local mode = config.ask_opt("context")
  local max = config.ask_opt("max_lines")
  local span, kind
  if mode == "function" then
    span = M.enclosing(bufnr, sl, el)
    kind = span and "function" or nil
  end
  if not span then
    local n = type(mode) == "number" and mode or config.ask_opt("lines")
    local total = vim.api.nvim_buf_line_count(bufnr)
    span = { sl = math.max(1, sl - n), el = math.min(total, el + n) }
    kind = "lines"
  end
  local trimmed
  span, trimmed = clamp(span, sl, el, max)
  return {
    kind = kind,
    sl = span.sl,
    el = span.el,
    name = span.name,
    trimmed = trimmed,
    lines = vim.api.nvim_buf_get_lines(bufnr, span.sl - 1, span.el, false),
  }
end

local function lang_of(file)
  return file:match("%.([%w_]+)$") or ""
end

local function fence(lang, lines)
  -- a longer fence than any run of backticks inside the code, so a snippet that
  -- itself contains ``` can't close the block early
  local longest = 3
  for _, l in ipairs(lines) do
    for run in l:gmatch("`+") do
      longest = math.max(longest, #run + 1)
    end
  end
  local f = string.rep("`", longest)
  local out = { f .. lang }
  vim.list_extend(out, lines)
  out[#out + 1] = f
  return out
end

M.PREAMBLE = table.concat({
  "# Question about code",
  "",
  "Answer the question below about the quoted code. This is a reading / comprehension question,",
  "NOT a change request: do not modify any file. Be direct and concise; refer to line numbers",
  "where it helps. The quoted context is what surrounds the asked lines in the file; if the",
  "answer depends on code elsewhere in the project, read it.",
}, "\n")

-- The founding prompt for an ask thread: the question framing, the file as a real
-- `@path` mention (so the transport's mention policy still appends its
-- read-this-file note exactly like a review thread's), the enclosing context,
-- the asked lines, and the question. `question` is the text being sent now —
-- the trailing you-turn (set_pending_you) — and defaults to turn 1. When the
-- thread already holds a conversation (a RE-founding after a lost session),
-- turn 1 is the **Question:**, turns 2..n-1 follow as a transcript, and
-- `question` lands as the **Follow-up:** — nothing the agent once knew is
-- silently dropped.
function M.prompt(c, question)
  local turns = require("obelus.store").turns(c)
  question = question or (turns[1] and turns[1].text) or c.comment or ""
  local lang = lang_of(c.file)
  local parts = { M.PREAMBLE, "" }
  -- same header shape as format.comment_md: a boundary "@relpath" token IS the mention
  parts[#parts + 1] = string.format("### @%s `%s`", format.relpath(c.file):gsub(" ", "\\ "), format.range_label(c))
  parts[#parts + 1] = ""
  local ctx = c.ask_context
  if ctx and ctx.lines and #ctx.lines > 0 and not (ctx.sl == c.range.sl and ctx.el == c.range.el) then
    local label
    if ctx.kind == "function" then
      label = ctx.name and string.format("Enclosing `%s`", ctx.name) or "Enclosing function"
    else
      label = "Surrounding lines"
    end
    parts[#parts + 1] = string.format(
      "%s (`L%d-L%d`%s):",
      label,
      ctx.sl,
      ctx.el,
      ctx.trimmed and ", trimmed around the asked lines" or ""
    )
    vim.list_extend(parts, fence(lang, ctx.lines))
    parts[#parts + 1] = ""
  end
  parts[#parts + 1] = string.format("Asked lines (`%s`):", format.range_label(c))
  vim.list_extend(parts, fence(lang, c.selected_text or {}))
  parts[#parts + 1] = ""
  -- a trailing you-turn equal to `question` is the draft being sent now (it was
  -- written onto the turns before this ran) — everything before it is history
  local last = #turns
  if last > 0 and turns[last].author == "you" and turns[last].text == question then
    last = last - 1
  end
  if last >= 1 and turns[1].text ~= question then
    parts[#parts + 1] = "**Question:** " .. (turns[1].text or "")
    if last >= 2 then
      parts[#parts + 1] = ""
      parts[#parts + 1] = "Conversation so far (the session was lost — this is what was already said):"
      local agent = require("obelus.config").agent_label()
      for i = 2, last do
        local t = turns[i]
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format("**%s:** %s", t.author == "you" and "You" or agent, t.text or "")
      end
    end
    parts[#parts + 1] = ""
    parts[#parts + 1] = "**Follow-up:** " .. question
  else
    parts[#parts + 1] = "**Question:** " .. question
  end
  return table.concat(parts, "\n")
end

return M
