local config = require("obelus.config")
local store = require("obelus.store")
local format = require("obelus.format")
local mention = require("obelus.mention")

local M = {}

---@type table<string, fun(payload: table)>
M.transports = {}

---Register a transport. `fn` receives { comments, markdown, opts }.
function M.register(name, fn)
  M.transports[name] = fn
end

function M.names()
  return vim.tbl_keys(M.transports)
end

---Submit a batch of comments through a transport.
---@param name? string transport name (defaults to config.transport.default)
---@param opts? table { comments?: table[] }
---@return boolean ok false on any early-error path (unknown transport, nothing
---  pending, or the backend threw synchronously); callers (batch.lua) gate
---  round/snapshot commits on this.
function M.submit(name, opts)
  opts = opts or {}
  -- obelus.api: an extension backend's thread goes to that backend's transport,
  -- never to a transport below (fail closed). No-op unless a backend is registered.
  local api = package.loaded["obelus.api"]
  if api and api._active() then
    local routed = api._route_submit(opts)
    if routed ~= nil then
      return routed
    end
  end
  -- a non-file (or backend) thread never reaches a transport below: fail closed
  if not store.all_agent_eligible(opts.comments or store.pending(), opts.actions_comments) then
    vim.notify(
      "obelus: not sent — threads on non-file buffers are never sent to obelus's agents",
      vim.log.levels.ERROR
    )
    return false
  end
  name = name or config.options.transport.default
  local fn = M.transports[name]
  if not fn then
    vim.notify("obelus: unknown transport '" .. tostring(name) .. "'", vim.log.levels.ERROR)
    return false
  end

  local comments = opts.comments or store.pending()
  if #comments == 0 then
    vim.notify("obelus: no pending comments to submit", vim.log.levels.WARN)
    return false
  end

  -- opts.prompt overrides the batch markdown (used for resumed follow-ups).
  local markdown = opts.prompt or format.to_markdown(comments)
  -- ONE choke point for every outgoing prompt (chat replies via opts.prompt, batch/
  -- oneshot submits via format.to_markdown, resumed rounds via batch.lua's own
  -- opts.prompt) — the @mention policy (input.mention.send: reference note vs
  -- inlined file contents) is applied exactly once here, transport-agnostic (cli,
  -- file, sidekick, quickfix, or a test's fake transport all see the same
  -- markdown), rather than duplicated at each transport's own prompt-suffix site
  -- (e.g. cli.lua's [Formatting] suffix, appended AFTER this).
  -- opts.mention_text scopes the mention policy to the USER-AUTHORED portion of
  -- the prompt: the meta briefing embeds "@thread:<id>" one-line summaries for
  -- resolved threads BY DESIGN, and scanning the whole markdown would full-expand
  -- every one of them right back (a >20x prompt blowup that defeats the summary).
  -- short image mentions ("@x.png", the display form) expand to their real
  -- ".ai/img/" paths for the agent — BEFORE the suffix policy scans them
  markdown = mention.expand_image_mentions(markdown)
  local suffix = mention.prompt_suffix(opts.mention_text or markdown, { include_drafts = opts.mention_include_drafts })
  if suffix then
    markdown = markdown .. suffix
  end
  local payload = { comments = comments, markdown = markdown, opts = opts }
  local ok, err = pcall(fn, payload)
  if not ok then
    vim.notify("obelus: transport '" .. name .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  -- Status changes are owned by the transport (e.g. cli sets resolved on
  -- completion); submit only handles the optional clear-on-submit. NEVER clear a
  -- batch submit — the batch needs its members to persist so it can keep talking to
  -- the same agent across rounds (and the dispatch is still async in flight here).
  if config.options.transport.clear_on_submit and not opts.batch then
    for _, c in ipairs(comments) do
      store.remove(c.id)
    end
  end
  require("obelus.review").refresh()
  return true
end

-- Built-in transports register themselves against this registry.
require("obelus.transport.sidekick")(M)
require("obelus.transport.cli")(M)
require("obelus.transport.file")(M)
require("obelus.transport.quickfix")(M)

return M
