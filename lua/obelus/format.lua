local store = require("obelus.store")

local M = {}

function M.relpath(file)
  local root = store.root()
  if file:sub(1, #root) == root then
    return file:sub(#root + 2)
  end
  return file
end

local function lang_of(file)
  return file:match("%.([%w_]+)$") or ""
end

function M.range_label(c)
  if c.range.sc and c.range.ec then
    return string.format("L%d:%d-L%d:%d", c.range.sl, c.range.sc, c.range.el, c.range.ec)
  end
  return string.format("L%d-L%d", c.range.sl, c.range.el)
end

---Markdown for a single comment.
function M.comment_md(c, idx)
  local lines = {}
  local head = string.format("%s%s `%s`", idx and (idx .. ". ") or "", M.relpath(c.file), M.range_label(c))
  table.insert(lines, "### " .. head)
  table.insert(lines, "")
  table.insert(lines, "```" .. lang_of(c.file))
  for _, l in ipairs(c.selected_text or {}) do
    table.insert(lines, l)
  end
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, "**Feedback:** " .. (c.comment or ""))
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

---Markdown for a batch of comments — the payload handed to an agent.
function M.to_markdown(comments, opts)
  opts = opts or {}
  local parts = {
    opts.title or "# Code review feedback",
    "",
    "Please address the following review comments. Each item gives a file path, a line/column "
      .. "range, the relevant code, and the requested change.",
    "",
  }
  for i, c in ipairs(comments) do
    table.insert(parts, M.comment_md(c, i))
  end
  return table.concat(parts, "\n")
end

return M
