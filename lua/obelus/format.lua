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

---Markdown for a single comment. The file lands as a real "@path" mention, so
---the transport choke point's mention policy (input.mention.send) governs
---threads/batches exactly like typed mentions: "reference" appends the
---read-these-paths note, "inline" embeds the commented file's contents.
function M.comment_md(c, idx)
  local lines = {}
  local head =
    string.format("%s@%s `%s`", idx and (idx .. ". ") or "", M.relpath(c.file):gsub(" ", "\\ "), M.range_label(c))
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

---Full serialization of a thread: comment_md's header/code/feedback block PLUS
---every conversation turn AFTER the first (author-labelled You:/Agent:, terse) —
---the first turn is already shown via comment_md's "Feedback:" line, so it isn't
---repeated. Used by M.meta_context (every pending thread, in full) and by
---mention.prompt_suffix's "@thread:<id>" expansion (any thread, resolved or not —
---this is how a resolved thread's one-line summary gets pulled back in full).
function M.thread_full(c)
  local out = M.comment_md(c)
  local turns = store.turns(c)
  local lines = {}
  for i = 2, #turns do
    local t = turns[i]
    local label = t.author == "agent" and "Agent" or "You"
    lines[#lines + 1] = "**" .. label .. ":** " .. (t.text or "")
    lines[#lines + 1] = ""
  end
  if #lines > 0 then
    out = out .. table.concat(lines, "\n")
  end
  return out
end

---The project thread's briefing (obelus.project() / review.do_respond's `c.meta`
---branch): every OTHER thread in the project, PENDING/unresolved in full
---(M.thread_full — comment + conversation so far), RESOLVED collapsed to one
---summary line under a heading (pull one back in full with "@thread:<id>" — see
---mention.prompt_suffix). The meta record itself is never included.
function M.meta_context()
  local parts = { "# Project thread — review status briefing", "" }
  local pending_parts, resolved_lines = {}, {}
  for _, c in ipairs(store.all()) do
    if not c.meta then
      if c.status == "resolved" then
        local first = vim.split(c.comment or "", "\n")[1] or ""
        resolved_lines[#resolved_lines + 1] =
          string.format("- @thread:%s %s %s: %s", c.id, M.relpath(c.file), M.range_label(c), first)
      else
        pending_parts[#pending_parts + 1] = M.thread_full(c)
      end
    end
  end
  if #pending_parts > 0 then
    vim.list_extend(parts, pending_parts)
  else
    parts[#parts + 1] = "(no open threads)"
    parts[#parts + 1] = ""
  end
  if #resolved_lines > 0 then
    parts[#parts + 1] = "## Resolved (summaries — @thread:<id> to pull one back in full)"
    parts[#parts + 1] = ""
    vim.list_extend(parts, resolved_lines)
    parts[#parts + 1] = ""
  end
  return table.concat(parts, "\n")
end

return M
