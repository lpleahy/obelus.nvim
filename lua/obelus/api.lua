-- obelus.api: the public extension API (see :h obelus-api-extension).
--
-- Two parts, both additive — with no backend registered and no prompt open,
-- obelus behaves exactly as it does without this module:
--   * register_backend{ name, match, store, transport }: obelus's comment,
--     thread and composer UI on buffers that are NOT ordinary files (e.g.
--     "luodda://guide/*"). Threads on a matched buffer live in the backend's
--     store (never in obelus's JSONL) and turns go through the backend's
--     transport. obelus's own transports never run on them (fail closed — see
--     store.agent_eligible, which also quarantines records on a scheme a
--     backend ever claimed: obelus.claims, persisted across restarts).
--   * approve{ summary, details?, on_result }: a keyboard-driven Approve/Deny
--     float where every non-approve exit (and no UI at all) is Deny.
--
-- Threads of a backend are MIRRORED into obelus's in-memory store as ordinary
-- records carrying `backend` (the backend name) and `backend_id`, so the existing
-- bands, thread view, spinner and composer render them unchanged. Turns the
-- backend reported are `committed` (immutable, never a draft); an unsent reply is
-- a separate local draft turn after them. One-line hooks in store.lua and
-- transport forward mutations here; each is a no-op unless this module is loaded
-- and a record carries `backend`.
--
-- Every registration and every send carries a generation token: replacing or
-- unregistering a backend (or reloading the store) cancels and invalidates its
-- work, and a callback only changes anything while it still owns both the record
-- and the job.
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
---@field turn_id? string a user turn's id (from obelus's request or create); needed to answer it later

---@class obelus.api.Thread
---@field id string|integer the backend's own stable id
---@field range obelus.api.Range
---@field kind? "line"|"char" (default: "char" when range.sc is set, else "line")
---@field turns? obelus.api.Turn[] the committed conversation, oldest first; turns[1] is the comment
---@field text? string the comment text, when `turns` is absent
---@field status? "open"|"resolved"
---@field ask? boolean an ask-mode question rather than a note

---@class obelus.api.NewThread
---@field range obelus.api.Range
---@field kind "line"|"char"
---@field text string the comment text
---@field turn_id string the comment's (first user turn's) id; store it with the turn
---@field selected_text string[] the buffer text the range covers
---@field ask? boolean

---@class obelus.api.Store
---@field list fun(bufnr: integer): obelus.api.Thread[]
---@field create fun(bufnr: integer, new: obelus.api.NewThread): obelus.api.Thread must return the stored thread (with id)
---@field update fun(id: string, fields: { text: string }) edit the comment text (turns[1])
---@field delete fun(id: string)
---@field resolve fun(id: string, resolved: boolean)

---@class obelus.api.TurnRequest
---@field id string the thread's backend id; the backend owns the history and replays it
---@field turn_id string the user turn's stable id: the SAME for every retry of that turn
---@field text string the user turn's text
--
-- Backends must be idempotent on turn_id. For a request:
--   * turn_id not stored yet: store the user turn under it, then answer it;
--   * turn_id stored, not answered: do not store it again — only answer it;
--   * turn_id stored and answered: do not store or answer again — emit "done"
--     with the stored answer.
-- So every retry is safe:
--   accepted then done      the reply is committed with the turn (normal case);
--   accepted, answer failed "error": the message stays a draft with the SAME
--                           turn_id; a retry only asks for the answer. After a
--                           refresh the stored turn replaces the draft (matched
--                           by turn_id, never by text) and a dispatch answers it;
--   cancel                  the draft keeps its turn_id; a retry is safe whether
--                           or not the backend had stored the turn;
--   lost acknowledgement    (send threw, no events, editor gone): a retry with
--                           the same turn_id is safe.
-- Editing a draft after it was sent gives it a NEW turn_id (a new message).

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
---@field schemes string[] the URI schemes this backend owns (lowercase, e.g. { "luodda" }); claimed and persisted

local backends = {} ---@type table<string, table> name -> registration (with .gen)
local order = {} ---@type string[] registration order; first match wins
local synced = {} ---@type table<integer, integer> bufnr -> generation it was listed under
local inflight = {} ---@type table<string, table> record id -> its send state
local gen_seq = 0
local augroup

local turn_seq = 0
---A fresh, unique client turn id.
function M._new_turn_id()
  turn_seq = turn_seq + 1
  return string.format("t-%d-%x-%x-%d", vim.uv.os_getpid(), vim.uv.hrtime(), math.random(0, 0x7fffffff), turn_seq)
end

local function next_gen()
  gen_seq = gen_seq + 1
  return gen_seq
end

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

-- The registration that owns `bufnr`: name, registration — or nil. A `match`
-- that throws counts as a match (fail closed). match() is EXTERNAL code: if it
-- replaced or removed its own registration (or the buffer), its answer is
-- stale and discarded; the third result is then true.
local function owner_of(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local stale = false
  for _, name in ipairs(vim.deepcopy(order)) do
    local b = backends[name]
    if b then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      local ok, hit = pcall(b.match, bufnr)
      local same = backends[name] == b
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_name(bufnr) == bufname
      if not same then
        stale = true -- the answer belongs to a registration (or buffer) that is gone
      elseif not ok or hit then
        return name, b
      end
    end
  end
  return nil, nil, stale
end

---The name of the backend that owns `bufnr`, or nil. A `match` that throws
---counts as a match (fail closed).
---@param bufnr? integer
---@return string|nil
function M.backend_for(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  return (owner_of(bufnr))
end

-- The live registration owning mirror `c` — nil once it was replaced/removed.
local function owner(c)
  local b = c and c.backend and backends[c.backend]
  if b and c._api_gen == b.gen and c.backend_id then
    return b
  end
end

local function mirror_id(name, bid)
  return "api:" .. name .. ":" .. bid
end

local function valid_range(r)
  return type(r) == "table" and type(r.sl) == "number" and type(r.el) == "number" and r.sl >= 1 and r.el >= r.sl
end

-- A backend thread as an obelus store record (nil if malformed). Every turn is
-- committed: the backend reported it, so it is history, never a draft.
local function to_record(b, bufnr, file, t)
  if type(t) ~= "table" or (type(t.id) ~= "string" and type(t.id) ~= "number") or not valid_range(t.range) then
    return nil
  end
  local turns = {}
  for _, turn in ipairs(type(t.turns) == "table" and t.turns or {}) do
    if type(turn) == "table" and (turn.author == "you" or turn.author == "agent") and type(turn.text) == "string" then
      turns[#turns + 1] = {
        author = turn.author,
        text = turn.text,
        committed = true,
        turn_id = type(turn.turn_id) == "string" and turn.turn_id ~= "" and turn.turn_id or nil,
      }
    end
  end
  if #turns == 0 and type(t.text) == "string" then
    turns[1] = { author = "you", text = t.text, committed = true }
  end
  if #turns == 0 or turns[1].author ~= "you" then
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
    id = mirror_id(b.name, tostring(t.id)),
    backend = b.name,
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
    _api_gen = b.gen,
  }
end

-- the local, unsent draft of a mirror: its trailing uncommitted "you" turn
local function draft_of(c)
  local tail = c.turns and c.turns[#c.turns]
  if tail and tail.author == "you" and not tail.committed then
    return tail
  end
end

-- ── sends ─────────────────────────────────────────────────────────────────────

-- Does this send still own its record AND its job (same registration, same
-- record table, same job registration)? Anything else is a stale callback.
local function owns(st)
  return not st.done
    and backends[st.b.name] == st.b
    and inflight[st.id] == st
    and require("obelus.store").get(st.id) == st.c
    and require("obelus.jobs").get(st.id) == st.spec
end

-- The ONE terminal transition of a send (idempotent): "done", "error",
-- "cancel" (the user cancelled; review.cancel tidies the record) or
-- "invalidate" (its registration or record went away).
local function settle(st, kind, text)
  if st.done then
    return
  end
  local own = owns(st)
  st.done = true
  local store, jobs, progress = require("obelus.store"), require("obelus.jobs"), require("obelus.progress")
  if inflight[st.id] == st then
    inflight[st.id] = nil
  end
  if jobs.get(st.id) == st.spec then
    jobs.clear(st.id)
  end
  -- the backend's cancel is EXTERNAL code (it may re-enter the API): it runs
  -- last, after every change below, so nothing here acts on a stale `own`
  local external_cancel = (kind == "cancel" or kind == "invalidate") and st.cancel or nil
  if not own then
    pcall(progress.finish, st.job, false, "")
    if external_cancel then
      pcall(external_cancel)
    end
    return -- stale: touch nothing that a newer registration/record owns
  end
  if kind == "done" then
    store.stream_finish(st.id, text, nil, true)
    if st.draft then
      st.draft.committed = true -- handed to and answered by the backend: now history
    end
    if st.turn then
      st.turn.committed = true
    end
    pcall(progress.finish, st.job, true, text)
    require("obelus.review").refresh()
  elseif kind == "error" then
    -- like the CLI's failure path: drop the partial preview so nothing the backend
    -- streamed stays in the thread as if it were a reply; the message is a draft again
    store.stream_discard(st.id)
    store.clear_dispatching(st.id)
    pcall(progress.finish, st.job, false, "")
    require("obelus.review").refresh()
    notify_failure(st.b.name, "could not answer — your message is back in the draft")
  elseif kind == "invalidate" then
    store.abort(st.id)
    pcall(progress.finish, st.job, false, "")
  end
  if external_cancel then
    pcall(external_cancel)
  end
end

-- cancel and invalidate every send matching `pred`
local function invalidate_sends(pred)
  local victims = {}
  for _, st in pairs(inflight) do
    if pred(st) then
      victims[#victims + 1] = st
    end
  end
  for _, st in ipairs(victims) do
    settle(st, "invalidate")
  end
end

-- Stream one turn through the backend's transport, with the same store/progress
-- choreography as transport/cli.lua's run_stream. The request carries only the
-- thread id and the new text: the backend owns the history and its replay.
local function run_turn(c, b)
  local store, jobs = require("obelus.store"), require("obelus.jobs")
  local draft = draft_of(c)
  local tail = c.turns and c.turns[#c.turns]
  local turn_id, text
  if draft then
    -- one stable id per submitted text: a retry of the same draft reuses it,
    -- an edited draft is a new message with a new id
    if not (draft.turn_id and draft._api_sent_text == draft.text) then
      draft.turn_id = M._new_turn_id()
    end
    draft._api_sent_text = draft.text
    turn_id, text = draft.turn_id, draft.text
  elseif tail and tail.author == "you" and tail.turn_id then
    turn_id, text = tail.turn_id, tail.text -- stored, unanswered: the backend only answers it
  elseif tail and tail.author == "you" then
    vim.notify(
      "obelus: the " .. b.name .. " backend gave this message no turn id — it cannot be retried safely",
      vim.log.levels.WARN
    )
    return false
  else
    vim.notify("obelus: nothing to send on this thread — reply first", vim.log.levels.WARN)
    return false
  end
  local id = c.id
  store.stream_start(id)
  local st = { b = b, c = c, id = id, draft = draft, turn = c._stream_turn, done = false, acc = "" }
  st.spec = {
    transport = "api:" .. b.name,
    cancel = function()
      settle(st, "cancel")
    end,
  }
  inflight[id] = st
  jobs.register(id, st.spec)
  st.job = require("obelus.progress").start({ label = b.label, comments = { c } })
  local function handle(ev)
    if type(ev) ~= "table" or not owns(st) then
      if not st.done and not owns(st) then
        settle(st, "invalidate") -- a late callback found its record/job replaced
      end
      return
    end
    if ev.type == "delta" then
      if type(ev.text) == "string" then
        st.acc = st.acc .. ev.text
        store.stream_update(id, st.acc)
      end
    elseif ev.type == "done" then
      local final = type(ev.text) == "string" and ev.text or st.acc
      settle(st, final:match("^%s*$") and "error" or "done", final)
    elseif ev.type == "error" then
      settle(st, "error")
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
  local ok, cancel = pcall(b.transport.send, { id = c.backend_id, turn_id = turn_id, text = text }, emit)
  if type(cancel) == "function" then
    st.cancel = cancel
    if st.done then
      pcall(cancel) -- already invalidated/cancelled while send() ran
    end
  end
  if not ok then
    settle(st, "error") -- a no-op when send() already finished (done, then threw)
  end
  return true
end

-- ── refresh / registration ────────────────────────────────────────────────────

---Re-read a backend buffer's threads from its store and repaint. Called
---automatically when a matched buffer is first shown (and after a store
---reload); call it yourself after the backend's data changed elsewhere.
---Threads with a reply in flight keep their state, and a local unsent draft
---survives.
---@param bufnr? integer
---@return boolean ok
function M.refresh(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local name, b = owner_of(bufnr)
  local file = name and abspath(bufnr)
  if not (name and file) then
    return false
  end
  local ok, list = pcall(b.store.list, bufnr)
  -- list() is external: if it replaced or removed this registration, or the
  -- buffer went away or was renamed, this result is stale (the newer
  -- registration refreshed itself)
  if backends[name] ~= b or not vim.api.nvim_buf_is_valid(bufnr) or abspath(bufnr) ~= file then
    return false
  end
  if not ok or type(list) ~= "table" then
    notify_failure(name, "could not list its threads")
    return false
  end
  synced[bufnr] = b.gen
  local store = require("obelus.store")
  local keep, live, drafts = {}, {}, {}
  for _, c in ipairs(store.comments) do
    local mine = c.backend == name and c.file == file
    if mine and owner(c) and inflight[c.id] and inflight[c.id].c == c then
      keep[#keep + 1] = c -- a reply in flight: keep its live record
      live[c.id] = true
    elseif mine then
      local d = owner(c) and draft_of(c)
      drafts[c.id] = d or nil
    else
      keep[#keep + 1] = c
    end
  end
  for _, t in ipairs(list) do
    local rec = to_record(b, bufnr, file, t)
    if rec and not live[rec.id] then
      local d = drafts[rec.id]
      local stored = false
      -- only the unchanged, submitted version of a draft can be the stored turn
      -- (matched by id, never by text); an edited draft stays a draft
      local submitted = d and d.turn_id and d._api_sent_text == d.text
      for _, t in ipairs(submitted and rec.turns or {}) do
        stored = stored or (t.author == "you" and t.turn_id == d.turn_id) -- reconciled by id, never by text
      end
      if d and not stored then
        rec.turns[#rec.turns + 1] =
          { author = "you", text = d.text, turn_id = d.turn_id, _api_sent_text = d._api_sent_text }
      end
      keep[#keep + 1] = rec
      live[rec.id] = true
    end
  end
  for i = #store.comments, 1, -1 do
    store.comments[i] = nil
  end
  for i, c in ipairs(keep) do
    store.comments[i] = c
  end
  pcall(require("obelus.render").render_all)
  return true
end

local function refresh_loaded(name, b)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if backends[name] ~= b then
      return -- replaced while refreshing (re-entered): the newer one refreshes itself
    end
    if vim.api.nvim_buf_is_loaded(buf) and M.backend_for(buf) == name then
      M.refresh(buf)
    end
  end
end

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("obelus_api", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function(ev)
      local name, b = owner_of(ev.buf)
      if name and synced[ev.buf] ~= b.gen then
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

-- End an OLD registration that the caller has already taken out of the
-- registry (replaced or removed): drop only that generation's mirrors and sync
-- marks, then cancel and invalidate its sends. The external cancels run last,
-- so a nested registration they make is never touched by this.
local function detach(name, old)
  local store = require("obelus.store")
  for i = #store.comments, 1, -1 do
    local c = store.comments[i]
    if c.backend == name and c._api_gen == old.gen then
      table.remove(store.comments, i)
    end
  end
  for buf, g in pairs(synced) do
    if g == old.gen then
      synced[buf] = nil
    end
  end
  invalidate_sends(function(st)
    return st.b == old
  end)
end

---Register a backend. Registering a name again REPLACES it: the old
---registration's sends are cancelled and its late callbacks ignored. Errors
---on a malformed spec.
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
  need(type(spec.schemes) == "table" and #spec.schemes > 0, "schemes must be a non-empty list")
  for _, s in ipairs(spec.schemes) do
    need(require("obelus.claims").valid(s), "invalid scheme " .. vim.inspect(s) .. " (lowercase, [a-z][a-z0-9+.-]*)")
  end
  require("obelus.claims").claim(spec.schemes)
  local old = backends[spec.name]
  local b = {
    name = spec.name,
    gen = next_gen(),
    match = spec.match,
    store = spec.store,
    transport = spec.transport,
    label = type(spec.label) == "string" and spec.label or spec.name,
  }
  if not old then
    order[#order + 1] = spec.name
  end
  backends[spec.name] = b -- the new one owns the name before any old code runs
  ensure_autocmds()
  if old then
    detach(spec.name, old) -- replacement: the old generation's work ends here
  end
  -- a cancel above may have registered this name AGAIN (re-entry): the latest
  -- registration wins and refreshes itself; this one stops here
  if backends[spec.name] == b then
    refresh_loaded(spec.name, b)
  end
  pcall(require("obelus.render").render_all)
  return true
end

---Remove a backend: cancel its sends, drop its mirrored threads from obelus's
---memory (its data stays in the backend).
---@param name string
function M.unregister_backend(name)
  local old = backends[name]
  if not old then
    return false
  end
  backends[name] = nil -- detached first: its external cancels may re-register the name
  for i = #order, 1, -1 do
    if order[i] == name then
      table.remove(order, i)
    end
  end
  detach(name, old)
  pcall(require("obelus.render").render_all)
  return true
end

---Claim URI schemes (lowercase, e.g. { "luodda" }) before a backend registers —
---call it from your plugin/ file. Records on those schemes never reach obelus's
---own agents again, across restarts (see :h obelus-quarantine). Errors on an
---invalid name; returns whether the claim was saved to disk.
---@param schemes string[]
---@return boolean saved
function M.claim_schemes(schemes)
  return require("obelus.claims").claim(schemes)
end

---Schemes claimed so far (on disk and in this session), sorted.
---@return string[]
function M.claimed_schemes()
  return require("obelus.claims").list()
end

---Names of the registered backends, in match order.
---@return string[]
function M.backends()
  return vim.deepcopy(order)
end

-- ── store hooks (called from obelus.store) ────────────────────────────────────

-- store.load, after the JSONL replaced the in-memory list: every mirror and its
-- record identity is gone, so end all sends and list visible backend buffers again.
function M._on_reload()
  if not M._active() then
    return
  end
  invalidate_sends(function()
    return true
  end)
  synced = {}
  for _, name in ipairs(vim.deepcopy(order)) do
    if backends[name] then
      refresh_loaded(name, backends[name])
    end
  end
end

-- store.add, before the record is inserted. Returns false to refuse: a new
-- comment on a backend buffer exists only once the backend stored it.
function M._adopt(c)
  if c.backend ~= nil or not M._active() then
    return true
  end
  local bufnr = buf_for_file(c.file)
  if not bufnr then
    return true
  end
  local name, b, stale = owner_of(bufnr)
  if stale and not name then
    -- a match() changed its registration while deciding: fail closed, retry
    notify_failure("matching", "changed while saving this comment — try again")
    return false
  end
  if not name then
    return true
  end
  -- a retry of a refused create with unchanged text carries that attempt's id
  -- (capture keeps it), so an idempotent backend can join the two attempts
  local first_turn_id = c._api_turn_id or M._new_turn_id()
  c._api_turn_id = first_turn_id -- the caller can offer it to the retry
  local ok, t = pcall(b.store.create, bufnr, {
    range = vim.deepcopy(c.range),
    kind = c.kind,
    text = c.comment,
    turn_id = first_turn_id,
    selected_text = vim.deepcopy(c.selected_text or {}),
    ask = c.ask,
  })
  if not (ok and type(t) == "table" and (type(t.id) == "string" or type(t.id) == "number")) then
    notify_failure(name, "could not save this comment")
    return false
  end
  -- create() is external: its result belongs to registration `b` only. If `b`
  -- was replaced or removed meanwhile (or the buffer changed), the result is
  -- stale: it is never relabelled for a newer registration and never used to
  -- remove that one's mirrors. Refuse; the current registration lists its own
  -- store, and the composer keeps this attempt's turn id for a retry.
  if backends[name] ~= b or not vim.api.nvim_buf_is_valid(bufnr) or abspath(bufnr) ~= c.file then
    notify_failure(name, "changed while saving this comment — try again")
    return false
  end
  local store = require("obelus.store")
  local id = mirror_id(name, tostring(t.id))
  for i = #store.comments, 1, -1 do -- a nested refresh of THIS registration may already list it
    local x = store.comments[i]
    if x.id == id and x._api_gen == b.gen and not inflight[id] then
      table.remove(store.comments, i)
    end
  end
  c.backend = name
  c.backend_id = tostring(t.id)
  c.id = mirror_id(name, c.backend_id)
  c.tag = nil -- backend threads never join a tag or a batch
  c.scratch = nil -- their lifetime is the backend's, not ask-mode scratch
  c.turns = { { author = "you", text = c.comment, committed = true, turn_id = first_turn_id } }
  c._api_status = c.status
  c._api_gen = b.gen
  return true
end

-- store.update, BEFORE the fields are applied. Returns false to refuse (the
-- backend failed or is gone): the mirror then stays as the backend has it.
function M._on_update(c, fields)
  local persisted = fields.comment ~= nil or fields.status ~= nil
  local b = owner(c)
  if not b then
    if persisted then
      notify_failure(c.backend, "is not available — nothing was changed")
    end
    return not persisted
  end
  -- update()/resolve() are external: afterwards this record must still be the
  -- live mirror of the same registration, or the change is not applied here
  local function still_mine()
    return owner(c) == b and require("obelus.store").get(c.id) == c
  end
  if type(fields.comment) == "string" and fields.comment ~= c.comment then
    if not pcall(b.store.update, c.backend_id, { text = fields.comment }) then
      notify_failure(b.name, "could not save the edit")
      return false
    end
    if not still_mine() then
      return false
    end
    if c.turns and c.turns[1] then
      c.turns[1].text = fields.comment -- the backend took the edit: history follows
    end
  end
  if fields.status ~= nil then
    local resolved = fields.status == "resolved"
    if resolved ~= (c._api_status == "resolved") then
      if not pcall(b.store.resolve, c.backend_id, resolved) then
        notify_failure(b.name, resolved and "could not resolve the thread" or "could not reopen the thread")
        return false
      end
      if not still_mine() then
        return false
      end
      c._api_status = fields.status -- acknowledged only now
    end
  end
  return true
end

-- store.remove, BEFORE the record is dropped. Returns false to refuse.
function M._on_remove(c)
  local b = owner(c)
  if not b then
    notify_failure(c.backend, "is not available — nothing was deleted")
    return false
  end
  if not pcall(b.store.delete, c.backend_id) then
    notify_failure(b.name, "could not delete the thread")
    return false
  end
  -- delete() is external; store.remove re-finds the record by identity after
  -- this returns, so a re-entrant refresh cannot make it drop another record
  invalidate_sends(function(st)
    return st.c == c
  end)
  return true
end

-- ── transport hook (called from obelus.transport) ─────────────────────────────

-- transport.submit, first thing: nil = no backend thread involved (obelus's own
-- eligibility gate follows); true = sent through the backend; false = refused.
function M._route_submit(opts)
  local comments = opts.comments or require("obelus.store").pending()
  local mine = false
  for _, list in ipairs({ comments, opts.actions_comments or {} }) do
    for _, c in ipairs(list) do
      mine = mine or (type(c) == "table" and c.backend ~= nil)
    end
  end
  if not mine then
    return nil
  end
  local c = comments[1]
  local b = #comments == 1 and not opts.actions_comments and not opts.batch and c.backend and owner(c)
  if not b then
    vim.notify("obelus: not sent — threads of an extension backend only go to that backend", vim.log.levels.ERROR)
    return false
  end
  return run_turn(c, b)
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
