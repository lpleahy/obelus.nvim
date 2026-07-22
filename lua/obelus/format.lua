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
---
---A trailing UNSENT draft reply (store.pending_you_text's definition: turn 2+ and
---the tail is "you") is a special case: `opts.include_drafts` (default true, so
---every existing caller — the global meta, mention.lua's pull-back — keeps
---showing it) true LABELS it distinctly ("You (draft, unsent):"); false SKIPS the
---turn entirely and leaves a one-line note instead, so it never leaks into a
---briefing where drafts must stay invisible (a tag meta's plain RESPOND mode —
---see review.do_respond). A brand-new, never-sent comment (turns == 1, the "you"
---turn IS c.comment) is never treated as a "draft" here — it's always shown via
---comment_md's own Feedback line, before this loop even starts.
---@param c table
---@param opts? { include_drafts?: boolean|"omit" } -- "omit" = skip the trailing draft with NO note (the caller sends it as the live message)
function M.thread_full(c, opts)
  opts = opts or {}
  local include_drafts = opts.include_drafts
  if include_drafts == nil then
    include_drafts = true
  end
  local out = M.comment_md(c)
  local turns = store.turns(c)
  local n = #turns
  local trailing_draft = n >= 2 and turns[n].author == "you"
  local lines = {}
  for i = 2, #turns do
    local t = turns[i]
    if trailing_draft and i == n and include_drafts == "omit" then
      -- silently skipped: the caller is about to send this very draft AS the
      -- message (do_respond's founding prompt) — serializing it here too sent
      -- the user's text TWICE, once mislabeled "draft, unsent"
      lines[#lines + 1] = nil
    elseif trailing_draft and i == n and not include_drafts then
      lines[#lines + 1] = "- (has an unsent draft, not shown)"
      lines[#lines + 1] = ""
    else
      local label = (trailing_draft and i == n) and "You (draft, unsent)"
        or (t.author == "agent" and require("obelus.config").agent_label() or "You")
      lines[#lines + 1] = "**" .. label .. ":** " .. (t.text or "")
      lines[#lines + 1] = ""
    end
  end
  if #lines > 0 then
    out = out .. table.concat(lines, "\n")
  end
  return out
end

---The project (or tag) thread's briefing (obelus.project()/obelus.tag_thread() —
---review.do_respond's `c.meta`/`c.meta_tag` branch): every OTHER thread in scope,
---PENDING/unresolved in full (M.thread_full — comment + conversation so far),
---RESOLVED collapsed to one summary line under a heading (pull one back in full
---with "@thread:<id>" — see mention.prompt_suffix). The meta record itself is
---never included.
---
---@param opts? { tag?: string, include_drafts?: boolean }
---  tag           — scope to threads carrying this tag only (nil = every thread
---                  in the project, the global project thread's briefing).
---  include_drafts — forwarded to M.thread_full for every pending thread (default
---                  true — the global thread's briefing always included drafts;
---                  it now additionally LABELS them, see thread_full). A tag
---                  meta's plain RESPOND engagement passes false: member drafts
---                  must not leak into a mode that deliberately excludes them.
function M.meta_context(opts)
  opts = opts or {}
  local tag = opts.tag
  local include_drafts = opts.include_drafts
  if include_drafts == nil then
    include_drafts = true
  end
  local title = tag and ("# #" .. tag .. " thread — batch status briefing")
    or "# Project thread — review status briefing"
  local parts = { title, "" }
  local pending_parts, resolved_lines = {}, {}
  for _, c in ipairs(store.all()) do
    if not c.meta and (tag == nil or c.tag == tag) then
      if c.status == "resolved" then
        local first = vim.split(c.comment or "", "\n")[1] or ""
        resolved_lines[#resolved_lines + 1] =
          string.format("- @thread:%s %s %s: %s", c.id, M.relpath(c.file), M.range_label(c), first)
      else
        pending_parts[#pending_parts + 1] = M.thread_full(c, { include_drafts = include_drafts })
      end
    end
  end
  if #pending_parts > 0 then
    vim.list_extend(parts, pending_parts)
  else
    parts[#parts + 1] = tag and ("(no open #" .. tag .. " threads)") or "(no open threads)"
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

---Membership deltas for a unified tag session's prompt (store.tag_membership_delta
---— see review.do_respond / obelus.batch): one "JOINED" block per newly-tagged
---member, giving its FULL identity (M.thread_full — `include_drafts` forwarded,
---same respond-vs-submit-all split as M.meta_context), and one "LEFT" line per
---member no longer tagged here (untagged, retagged elsewhere, or — when `l.c` is
---nil — deleted outright, identified by id since there's nothing left to look up).
---"" when there's nothing to report (nothing prepended to the prompt that send).
---@param tag string
---@param delta { joins: table[], leaves: { id: string, c: table? }[] }
---@param opts? { include_drafts?: boolean|"omit" } -- "omit" = skip the trailing draft with NO note (the caller sends it as the live message)
function M.tag_deltas(tag, delta, opts)
  opts = opts or {}
  local lines = {}
  for _, c in ipairs(delta.joins or {}) do
    lines[#lines + 1] = "JOINED the #" .. tag .. " conversation:"
    lines[#lines + 1] = M.thread_full(c, { include_drafts = opts.include_drafts })
  end
  for _, l in ipairs(delta.leaves or {}) do
    if l.c then
      lines[#lines + 1] = "LEFT the conversation (do not act on it): "
        .. M.relpath(l.c.file)
        .. " "
        .. M.range_label(l.c)
    else
      lines[#lines + 1] = "LEFT the conversation (do not act on it): " .. l.id .. " (deleted)"
    end
  end
  return table.concat(lines, "\n")
end

return M
