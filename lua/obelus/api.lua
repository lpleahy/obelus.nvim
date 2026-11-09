-- obelus.api: the public extension API (see :h obelus-api).
--
-- Two parts, both additive — with no backend registered and no prompt open,
-- obelus behaves exactly as it does without this module:
--   * register_backend{ name, match, store, transport }: obelus's comment,
--     thread and composer UI on buffers that are NOT ordinary files (e.g.
--     "luodda://guide/*"). Threads on a matched buffer live in the backend's
--     store (never in obelus's JSONL) and turns go through the backend's
--     transport. obelus's own CLI transport never runs on them (fail closed).
--   * approve{ summary, details?, on_result }: a keyboard-driven Approve/Deny
--     float where every non-approve exit (and no UI at all) is Deny.
--
-- Threads of a backend are MIRRORED into obelus's in-memory store as ordinary
-- records carrying `backend` (the backend name) and `backend_id`, so the existing
-- bands, thread view, spinner and composer render them unchanged. A handful of
-- one-line hooks in store.lua / transport forward mutations here; each hook is a
-- no-op unless this module is loaded and a record carries `backend`.
local M = {}

M.version = "0.1.0"

---@class obelus.api.Range
---@field sl integer first line (1-based)
---@field el integer last line (1-based, inclusive)
---@field sc? integer first column (1-based) for a charwise range
---@field ec? integer last column (1-based, inclusive) for a charwise range

---@class obelus.api.Turn
---@field author "you"|"agent"
---@field text string

---@class obelus.api.Thread
---@field id string|integer the backend's own stable id
---@field range obelus.api.Range
---@field kind? "line"|"char" (default: "char" when range.sc is set, else "line")
---@field turns? obelus.api.Turn[] the conversation, oldest first; turns[1] is the comment
---@field text? string the comment text, when `turns` is absent
---@field status? "open"|"resolved"
---@field ask? boolean an ask-mode question rather than a note

---@class obelus.api.NewThread
---@field range obelus.api.Range
---@field kind "line"|"char"
---@field text string the comment text
---@field selected_text string[] the buffer text the range covers
---@field ask? boolean

---@class obelus.api.Store
---@field list fun(bufnr: integer): obelus.api.Thread[]
---@field create fun(bufnr: integer, new: obelus.api.NewThread): obelus.api.Thread must return the stored thread (with id)
---@field update fun(id: string, fields: { text: string }) edit the comment text
---@field delete fun(id: string)
---@field resolve fun(id: string, resolved: boolean)

---@class obelus.api.TurnRequest
---@field id string the thread's backend id
---@field bufnr integer|nil the buffer showing the thread, if loaded
---@field text string the user's new message
---@field thread obelus.api.Thread the thread as obelus holds it, before this turn

---@alias obelus.api.Event
---| { type: "start" }
---| { type: "delta", text: string }  appended to the reply
---| { type: "done", text?: string }  the final reply (default: the deltas so far)
---| { type: "error" }                any message is ignored; obelus shows a fixed one

---@class obelus.api.Transport
---@field send fun(req: obelus.api.TurnRequest, emit: fun(ev: obelus.api.Event)): (fun()|nil) may return a cancel function

---@class obelus.api.Backend
---@field name string unique, [%w_-]+
---@field match fun(bufnr: integer): boolean
---@field store obelus.api.Store
---@field transport obelus.api.Transport
---@field label? string shown on the spinner (default: name)

---@type table<string, obelus.api.Backend>
local backends = {}
local order = {} ---@type string[] registration order; first match wins
local synced = {} ---@type table<integer, boolean> buffers listed since they were shown
local augroup

local function notify_failure(name, what)
  -- FIXED text: the backend's own error never reaches the screen, so nothing it
  -- says can be mistaken for a reply
  vim.notify(string.format("obelus: the %s backend %s", name, what), vim.log.levels.ERROR)
end

local function abspath(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":p") or nil
end

local function buf_for_file(file)
  if not file then
    return nil
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and abspath(b) == file then
      return b
    end
  end
end

---True when at least one backend is registered.
function M._active()
  return #order > 0
end

---The name of the backend that owns `bufnr`, or nil. A `match` that throws
---counts as a match (fail closed: obelus's CLI must not run on that buffer).
---@param bufnr? integer
---@return string|nil
function M.backend_for(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  for _, name in ipairs(order) do
    local ok, hit = pcall(backends[name].match, bufnr)
    if not ok or hit then
      return name
    end
  end
end

-- Is `c` owned by a backend — mirrored from one, or on a buffer one matches?
local function owned(c)
  if type(c) ~= "table" then
    return false
  end
  if c.backend ~= nil then
    return true
  end
  local b = M._active() and buf_for_file(c.file)
  return b and M.backend_for(b) ~= nil or false
end

local function mirror_id(name, bid)
  return "api:" .. name .. ":" .. bid
end

local function valid_range(r)
  return type(r) == "table" and type(r.sl) == "number" and type(r.el) == "number" and r.sl >= 1 and r.el >= r.sl
end

-- A backend thread as an obelus store record (nil if malformed).
local function to_record(name, bufnr, file, t)
  if type(t) ~= "table" or (type(t.id) ~= "string" and type(t.id) ~= "number") or not valid_range(t.range) then
    return nil
  end
  local turns = {}
  for _, turn in ipairs(type(t.turns) == "table" and t.turns or {}) do
    if type(turn) == "table" and (turn.author == "you" or turn.author == "agent") and type(turn.text) == "string" then
      turns[#turns + 1] = { author = turn.author, text = turn.text }
    end
  end
  if #turns == 0 and type(t.text) == "string" then
    turns[1] = { author = "you", text = t.text }
  end
  if #turns == 0 then
    return nil
  end
  local r = t.range
  local kind = (t.kind == "char" or t.kind == "line") and t.kind or (r.sc and "char" or "line")
  local status = t.status == "resolved" and "resolved" or "open"
  local agent_last
  for _, turn in ipairs(turns) do
    if turn.author == "agent" then
      agent_last = turn.text
    end
  end
  return {
    id = mirror_id(name, tostring(t.id)),
    backend = name,
    backend_id = tostring(t.id),
    file = file,
    range = { sl = r.sl, el = r.el, sc = kind == "char" and r.sc or nil, ec = kind == "char" and r.ec or nil },
    kind = kind,
    selected_text = vim.api.nvim_buf_get_lines(bufnr, r.sl - 1, r.el, false),
    comment = turns[1].text,
    turns = turns,
    last_result = agent_last,
    status = status,
    ask = t.ask == true or nil,
    created_at = os.time(),
    _api_status = status,
  }
end

-- What obelus holds for a thread, in the backend's shape (handed to send()).
local function to_thread(c)
  local turns = {}
  for _, t in ipairs(require("obelus.store").turns(c)) do
    turns[#turns + 1] = { author = t.author, text = t.text }
  end
  return {
    id = c.backend_id,
    range = vim.deepcopy(c.range),
    kind = c.kind,
    turns = turns,
    status = c.status == "resolved" and "resolved" or "open",
    ask = c.ask,
  }
end

---Re-read a backend buffer's threads from its store and repaint. Called
---automatically when a matched buffer is first shown; call it yourself after
---the backend's data changed elsewhere. Threads with a reply in flight keep
---their in-memory state.
---@param bufnr? integer
---@return boolean ok
function M.refresh(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local name = M.backend_for(bufnr)
  local file = abspath(bufnr)
  if not (name and file) then
    return false
  end
  local b = backends[name]
  local ok, list = pcall(b.store.list, bufnr)
  if not ok or type(list) ~= "table" then
    notify_failure(name, "could not list its threads")
    return false
  end
  synced[bufnr] = true
  local store = require("obelus.store")
  local keep, live = {}, {}
  for _, c in ipairs(store.comments) do
    local stale = c.backend == name and c.file == file and not c.dispatching and not c.backend_error
    if not stale then
      keep[#keep + 1] = c
      if c.backend == name then
        live[c.id] = true
      end
    end
  end
  for _, t in ipairs(list) do
    local rec = to_record(name, bufnr, file, t)
    if rec and not live[rec.id] then
      keep[#keep + 1] = rec
      live[rec.id] = true
    end
  end
  -- in place: other modules hold no reference to the list itself, but keep the
  -- identity anyway so a caller iterating store.comments sees one consistent table
  for i = #store.comments, 1, -1 do
    store.comments[i] = nil
  end
  for i, c in ipairs(keep) do
    store.comments[i] = c
  end
  pcall(require("obelus.render").render_all)
  return true
end

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("obelus_api", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function(ev)
      if not synced[ev.buf] and M.backend_for(ev.buf) then
        M.refresh(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(ev)
      synced[ev.buf] = nil
    end,
  })
end

---Register (or replace) a backend. Errors on a malformed spec.
---@param spec obelus.api.Backend
function M.register_backend(spec)
  local function need(cond, what)
    if not cond then
      error("obelus.api.register_backend: " .. what, 3)
    end
  end
  need(type(spec) == "table", "spec must be a table")
  need(type(spec.name) == "string" and spec.name:match("^[%w_-]+$") ~= nil, "name must match [%w_-]+")
  need(type(spec.match) == "function", "match must be a function")
  need(type(spec.store) == "table", "store must be a table")
  for _, fn in ipairs({ "list", "create", "update", "delete", "resolve" }) do
    need(type(spec.store[fn]) == "function", "store." .. fn .. " must be a function")
  end
  need(type(spec.transport) == "table" and type(spec.transport.send) == "function", "transport.send must be a function")
  if not backends[spec.name] then
    order[#order + 1] = spec.name
  end
  backends[spec.name] = {
    name = spec.name,
    match = spec.match,
    store = spec.store,
    transport = spec.transport,
    label = type(spec.label) == "string" and spec.label or spec.name,
  }
  ensure_autocmds()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and M.backend_for(b) == spec.name then
      M.refresh(b)
    end
  end
  return true
end

---Remove a backend and drop its mirrored threads from obelus's memory (its
---data stays in the backend).
---@param name string
function M.unregister_backend(name)
  if not backends[name] then
    return false
  end
  backends[name] = nil
  for i = #order, 1, -1 do
    if order[i] == name then
      table.remove(order, i)
    end
  end
  local store = require("obelus.store")
  for i = #store.comments, 1, -1 do
    if store.comments[i].backend == name then
      table.remove(store.comments, i)
    end
  end
  synced = {}
  pcall(require("obelus.render").render_all)
  return true
end

---Names of the registered backends, in match order.
---@return string[]
function M.backends()
  return vim.deepcopy(order)
end

-- ── store hooks (called from obelus.store) ────────────────────────────────────

-- store.add, before the record is inserted: a new comment on a backend buffer is
-- created in the backend. On failure it stays in memory only (never the JSONL,
-- never the CLI) and a fixed message says so.
function M._adopt(c)
  if c.backend ~= nil or not M._active() then
    return
  end
  local bufnr = buf_for_file(c.file)
  local name = bufnr and M.backend_for(bufnr)
  if not name then
    return
  end
  c.backend = name
  c.tag = nil -- backend threads never join a tag or a batch
  c.scratch = nil -- their lifetime is the backend's, not ask-mode scratch
  local ok, t = pcall(backends[name].store.create, bufnr, {
    range = vim.deepcopy(c.range),
    kind = c.kind,
    text = c.comment,
    selected_text = vim.deepcopy(c.selected_text or {}),
    ask = c.ask,
  })
  if ok and type(t) == "table" and (type(t.id) == "string" or type(t.id) == "number") then
    c.backend_id = tostring(t.id)
    c.id = mirror_id(name, c.backend_id)
    c._api_status = c.status
  else
    c.backend_error = true
    notify_failure(name, "could not save this comment — it is kept only until you close nvim")
  end
end

local function synced_backend(c)
  local b = backends[c.backend]
  if b and not c.backend_error and c.backend_id then
    return b
  end
end

-- store.update: forward a comment edit and a resolved/open flip
function M._on_update(c, fields)
  local b = synced_backend(c)
  if not b then
    return
  end
  if type(fields.comment) == "string" then
    local ok = pcall(b.store.update, c.backend_id, { text = fields.comment })
    if not ok then
      notify_failure(b.name, "could not save the edit")
    end
  end
  if fields.status ~= nil then
    local resolved = fields.status == "resolved"
    if resolved ~= (c._api_status == "resolved") then
      c._api_status = fields.status
      local ok = pcall(b.store.resolve, c.backend_id, resolved)
      if not ok then
        notify_failure(b.name, resolved and "could not resolve the thread" or "could not reopen the thread")
      end
    end
  end
end

-- store.remove
function M._on_remove(c)
  local b = synced_backend(c)
  if b and not pcall(b.store.delete, c.backend_id) then
    notify_failure(b.name, "could not delete the thread")
  end
end

-- ── transport hooks (called from obelus.transport) ────────────────────────────

-- Stream one turn through the backend's transport, with the same store/progress
-- choreography as transport/cli.lua's run_stream.
local function run_turn(c, b)
  local store = require("obelus.store")
  local jobs = require("obelus.jobs")
  local progress = require("obelus.progress")
  local id = c.id
  local req =
    { id = c.backend_id, bufnr = buf_for_file(c.file), text = store.pending_you_text(c) or "", thread = to_thread(c) }
  store.stream_start(id)
  local st = { done = false, acc = "" }
  jobs.register(id, {
    transport = "api:" .. b.name,
    cancel = function()
      if not st.done then
        st.done = true
        jobs.clear(id)
        if st.cancel then
          pcall(st.cancel)
        end
      end
    end,
  })
  st.job = progress.start({ label = b.label, comments = { c } })
  local function fail()
    st.done = true
    jobs.clear(id)
    -- like the CLI's failure path: drop the partial preview so nothing the backend
    -- streamed stays in the thread as if it were a reply; the message is a draft again
    store.stream_discard(id)
    store.clear_dispatching(id)
    pcall(progress.finish, st.job, false, "")
    require("obelus.review").refresh()
    notify_failure(b.name, "could not answer — your message is back in the draft")
  end
  local function handle(ev)
    if st.done or type(ev) ~= "table" then
      return
    end
    if ev.type == "delta" then
      if type(ev.text) == "string" then
        st.acc = st.acc .. ev.text
        store.stream_update(id, st.acc)
      end
    elseif ev.type == "done" then
      local text = type(ev.text) == "string" and ev.text or st.acc
      if text:match("^%s*$") then
        return fail()
      end
      st.done = true
      jobs.clear(id)
      store.stream_finish(id, text, nil, true)
      pcall(progress.finish, st.job, true, text)
      require("obelus.review").refresh()
    elseif ev.type == "error" then
      fail()
    end
  end
  local function emit(ev)
    if vim.in_fast_event() then
      vim.schedule(function()
        handle(ev)
      end)
    else
      handle(ev)
    end
  end
  local ok, cancel = pcall(b.transport.send, req, emit)
  if not ok then
    fail()
  elseif type(cancel) == "function" then
    st.cancel = cancel
  end
end

-- transport.submit, first thing: nil = not ours (obelus continues as usual);
-- true = sent through the backend; false = refused (fail closed).
function M._route_submit(opts)
  local comments = opts.comments or require("obelus.store").pending()
  local any = false
  for _, list in ipairs({ comments, opts.actions_comments or {} }) do
    for _, c in ipairs(list) do
      any = any or owned(c)
    end
  end
  if not any then
    return nil
  end
  local c = comments[1]
  local b = #comments == 1 and not opts.actions_comments and not opts.batch and c.backend and synced_backend(c)
  if not b then
    vim.notify("obelus: not sent — threads of an extension backend only go to that backend", vim.log.levels.ERROR)
    return false
  end
  run_turn(c, b)
  return true
end

-- transport/cli.lua, before anything runs: the CLI agent (which can edit files)
-- must never see a backend thread, however the payload got there.
function M._guard_cli(payload)
  for _, list in ipairs({ payload.comments or {}, (payload.opts or {}).actions_comments or {} }) do
    for _, c in ipairs(list) do
      if owned(c) then
        error("obelus: refusing to run the CLI agent on an extension backend's thread", 0)
      end
    end
  end
end

-- ── approve ───────────────────────────────────────────────────────────────────

---Show a keyboard-driven Approve/Deny prompt. See :h obelus-api-approve.
---@param opts obelus.ApproveOpts
---@return { cancel: fun() }
function M.approve(opts)
  return require("obelus.approve").approve(opts)
end

---Focus the pending approval prompt (what :ObelusApprove does).
---@return boolean focused
function M.approve_focus()
  return require("obelus.approve").focus()
end

return M
