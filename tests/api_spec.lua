-- obelus.api: extension backends for non-file buffers, and the approve prompt.
-- Uses an invented in-memory backend ("memo://…" buffers); no CLI, no network.
T.describe("api")

local api = require("obelus.api")
local approve = require("obelus.approve")
local claims = require("obelus.claims")

-- every spec claims into its own temp file: never the user's state dir
local function fresh_claims(dir)
  dir = dir or vim.fn.tempname()
  claims._dir = dir .. "/nvim/obelus/claims" -- = stdpath("state")/obelus/claims with XDG_STATE_HOME=dir
  claims._reset()
  return dir
end

-- An in-memory backend. B.threads is its "database"; B.calls logs every store
-- call; B.sends every transport.send (with the emit callback to drive it).
-- B.fail[op] = true makes that store op throw (a raw sentinel message).
local function memo_backend()
  local B = { threads = {}, calls = {}, sends = {}, seq = 0, fail = {}, cancels = 0, reasons = {} }
  local function find(id)
    for i, t in ipairs(B.threads) do
      if tostring(t.id) == id then
        return t, i
      end
    end
  end
  local function guard(op)
    if B.fail[op] then
      error("RAW-STORE-ERROR " .. op)
    end
  end
  B.spec = {
    name = "memo",
    label = "memo",
    schemes = { "memo" },
    match = function(bufnr)
      return vim.api.nvim_buf_get_name(bufnr):match("^memo://") ~= nil
    end,
    store = {
      list = function(bufnr)
        B.calls[#B.calls + 1] = { "list", bufnr }
        return vim.deepcopy(B.threads)
      end,
      create = function(bufnr, new)
        B.calls[#B.calls + 1] = { "create", bufnr, new.text }
        guard("create")
        B.seq = B.seq + 1
        local t = {
          id = "n" .. B.seq,
          range = new.range,
          kind = new.kind,
          turns = { { author = "you", text = new.text, turn_id = new.turn_id } },
          status = "open",
        }
        B.threads[#B.threads + 1] = t
        return vim.deepcopy(t)
      end,
      update = function(id, fields)
        B.calls[#B.calls + 1] = { "update", id, fields.text }
        guard("update")
        find(id).turns[1].text = fields.text
      end,
      delete = function(id)
        B.calls[#B.calls + 1] = { "delete", id }
        guard("delete")
        local _, i = find(id)
        table.remove(B.threads, i)
      end,
      resolve = function(id, resolved)
        B.calls[#B.calls + 1] = { "resolve", id, resolved }
        guard("resolve")
        find(id).status = resolved and "resolved" or "open"
      end,
    },
    transport = {
      send = function(req, emit)
        B.sends[#B.sends + 1] = { req = req, emit = emit }
        return function(info)
          B.cancels = B.cancels + 1
          B.reasons[#B.reasons + 1] = type(info) == "table" and info.reason or "<none>"
        end
      end,
    },
  }
  return B
end

local function calls_of(B, op)
  return vim.tbl_filter(function(c)
    return c[1] == op
  end, B.calls)
end

-- Spy on every transport obelus could run. Returns the spy log and a restore fn.
local function spy_transports()
  local reg = require("obelus.transport").transports
  local saved, log = {}, {}
  for name, fn in pairs(reg) do
    saved[name] = fn
    reg[name] = function(payload)
      log[#log + 1] = { name = name, payload = payload }
    end
  end
  return log, function()
    for name, fn in pairs(saved) do
      reg[name] = fn
    end
  end
end

local function capture_notify()
  local msgs, orig = {}, vim.notify
  vim.notify = function(m, lvl)
    msgs[#msgs + 1] = { msg = tostring(m), level = lvl }
  end
  return msgs, function()
    vim.notify = orig
  end
end

local function clear_backends()
  for _, name in ipairs(api.backends()) do
    api.unregister_backend(name)
  end
end

-- a "memo://guide/<n>" buffer shown in the current window
local function memo_buffer(name)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name or ("memo://guide/" .. buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Guide", "Recursion calls itself.", "Base case first." })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- fresh obelus + the memo backend + a memo buffer shown in the window
local function setup(seed)
  local ctx = T.fresh()
  clear_backends()
  fresh_claims()
  local B = memo_backend()
  B.threads = seed or {}
  api.register_backend(B.spec)
  ctx.buf = memo_buffer()
  ctx.B = B
  ctx.file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":p")
  return ctx
end

local function teardown(ctx)
  clear_backends()
  if ctx and ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
    vim.cmd("enew")
    pcall(vim.api.nvim_buf_delete, ctx.buf, { force = true })
  end
end

-- run `fn(ctx)` with a backend set up, always tearing down
local function with_backend(seed, fn)
  local ctx = setup(seed)
  local ok, err = pcall(fn, ctx)
  teardown(ctx)
  if not ok then
    error(err, 0)
  end
end

local function new_comment(ctx, line, text)
  require("obelus.capture")._capture(ctx.buf, ctx.file, "line", line, nil, line, nil, { text = text })
  for _, c in ipairs(ctx.store.all()) do
    if c.comment == text then
      return c
    end
  end
end

local function texts(c)
  return vim.tbl_map(function(t)
    return t.author .. ":" .. t.text .. (t.committed and "" or "*")
  end, require("obelus.store").turns(c))
end

local SEED = {
  {
    id = 7,
    range = { sl = 2, el = 2 },
    turns = {
      { author = "you", text = "why recursion?" },
      { author = "agent", text = "It shrinks the problem." },
    },
  },
}

-- ── registration ───────────────────────────────────────────────────────────────

T.it("api.version is semver 0.2.x and register_backend validates its spec", function()
  T.eq(api.version, "0.2.0")
  local B = memo_backend()
  T.ok(not pcall(api.register_backend, { name = "x" }), "missing match/store/transport")
  local bad = vim.deepcopy(B.spec)
  bad.store.resolve = nil
  T.ok(not pcall(api.register_backend, bad), "store.resolve required")
  bad = vim.deepcopy(B.spec)
  bad.name = "has space"
  T.ok(not pcall(api.register_backend, bad), "name charset")
  for _, schemes in ipairs({ vim.NIL, {}, { "Memo" }, { "" }, { "me mo" } }) do
    bad = vim.deepcopy(B.spec)
    bad.schemes = schemes ~= vim.NIL and schemes or nil
    T.ok(not pcall(api.register_backend, bad), "schemes " .. vim.inspect(schemes) .. " rejected")
  end
  T.eq(api.backends(), {})
end)

T.it("register/match: a backend owns its buffers only; a throwing match fails closed", function()
  with_backend(nil, function(ctx)
    T.eq(api.backend_for(ctx.buf), "memo")
    local plain = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(plain, ctx.root .. "/plain.lua")
    T.is_nil(api.backend_for(plain), "a file buffer is not matched")
    api.register_backend({
      name = "broken",
      schemes = { "broken" },
      match = function()
        error("boom")
      end,
      store = ctx.B.spec.store,
      transport = ctx.B.spec.transport,
    })
    T.eq(api.backend_for(plain), "broken", "a throwing match counts as a match")
    api.unregister_backend("broken")
    T.is_nil(api.backend_for(plain))
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)

-- ── store: list / create / edit / resolve / delete ─────────────────────────────

T.it("list: a backend's threads are mirrored as committed history, never into the JSONL", function()
  local seed = vim.deepcopy(SEED)
  seed[2] = { id = "bad" } -- malformed (no range): skipped
  with_backend(seed, function(ctx)
    local mine = ctx.store.by_file(ctx.file)
    T.eq(#mine, 1)
    local c = mine[1]
    T.eq({ c.id, c.backend, c.backend_id }, { "api:memo:7", "memo", "7" })
    T.eq(c.selected_text, { "Recursion calls itself." })
    T.eq(texts(c), { "you:why recursion?", "agent:It shrinks the problem." })
    T.ok(#vim.api.nvim_buf_get_extmarks(ctx.buf, -1, 0, -1, {}) > 0, "the band/sign is placed")
    T.eq(#ctx.store.pending(), 0)
    T.ok(not require("obelus.format").meta_context():find("why recursion", 1, true), "not in the CLI briefing")
    ctx.store.add(T.comment({ file = ctx.root .. "/a.lua", comment = "plain one" }))
    ctx.store.save()
    local saved = table.concat(vim.fn.readfile(ctx.store.store_path()), "\n")
    T.contains(saved, "plain one")
    T.ok(not saved:find("why recursion", 1, true), "backend thread not persisted locally")
  end)
end)

T.it("create / first-comment edit / resolve / reopen / delete go through the backend store", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 3, "check the base case")
    T.eq({ c.id, c.backend_id }, { "api:memo:n1", "n1" })
    T.eq(ctx.B.threads[1].turns[1].text, "check the base case")
    T.eq(ctx.B.threads[1].range.sl, 3)
    T.eq(texts(c), { "you:check the base case" }, "the stored comment is committed, not a draft")
    T.is_nil(ctx.store.pending_you_text(c))
    local review = require("obelus.review")
    review.resolve(c.id)
    review.resolve(c.id) -- already resolved: no second backend call
    T.eq(calls_of(ctx.B, "resolve"), { { "resolve", "n1", true } })
    review.reopen(c.id)
    T.eq(ctx.B.threads[1].status, "open")
    -- editing the first comment is a backend edit; history follows; refresh agrees
    T.ok(ctx.store.update(c.id, { comment = "check both base cases" }))
    T.eq(calls_of(ctx.B, "update"), { { "update", "n1", "check both base cases" } })
    T.eq(texts(ctx.store.get(c.id)), { "you:check both base cases" })
    api.refresh(ctx.buf)
    T.eq(texts(ctx.store.get(c.id)), { "you:check both base cases" })
    local msgs, restore = capture_notify()
    review.delete(c.id)
    restore()
    T.eq(#ctx.B.threads, 0)
    T.is_nil(ctx.store.get(c.id))
    T.contains(vim.inspect(msgs), "comment deleted")
  end)
end)

T.it("a failed create is refused (nothing kept, fixed message) and a retry succeeds", function()
  with_backend(nil, function(ctx)
    ctx.B.fail.create = true
    local msgs, restore = capture_notify()
    local c = new_comment(ctx, 2, "unsaved note")
    restore()
    T.is_nil(c, "no mirror without a backend record")
    T.eq(#msgs, 1)
    T.eq(msgs[1].msg, "obelus: the memo backend could not save this comment")
    ctx.store.save()
    T.ok(not table.concat(vim.fn.readfile(ctx.store.store_path()), "\n"):find("unsaved note", 1, true))
    ctx.B.fail.create = nil
    c = new_comment(ctx, 2, "unsaved note")
    T.ok(c and c.backend_id == "n1", "retry stored it")
  end)
end)

T.it("failed update / resolve / delete leave the mirror as the backend has it; retries work", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local review = require("obelus.review")
    local msgs, restore = capture_notify()
    ctx.B.fail.resolve, ctx.B.fail.update, ctx.B.fail.delete = true, true, true
    review.resolve(id)
    review.resolve(id)
    T.eq(#calls_of(ctx.B, "resolve"), 2, "each attempt reaches the backend")
    T.eq(ctx.store.get(id).status, "open")
    T.is_nil(ctx.store.update(id, { comment = "edited" }), "the caller learns the edit failed")
    T.eq(ctx.store.get(id).comment, "why recursion?")
    review.delete(id)
    T.ok(ctx.store.get(id), "still there")
    restore()
    local all = vim.inspect(msgs)
    T.ok(not all:find("comment deleted", 1, true) and not all:find("comment updated", 1, true), "no false success")
    T.ok(not all:find("RAW", 1, true), "no raw backend text")
    ctx.B.fail = {}
    review.resolve(id)
    T.eq(ctx.B.threads[1].status, "resolved")
    T.ok(ctx.store.update(id, { comment = "edited" }))
    api.refresh(ctx.buf)
    T.eq({ ctx.store.get(id).comment, ctx.store.get(id).status }, { "edited", "resolved" })
    review.delete(id)
    T.is_nil(ctx.store.get(id))
    T.eq(#ctx.B.threads, 0)
  end)
end)

-- ── committed history vs local drafts (B3) ──────────────────────────────────────

T.it("a sent user tail is history: a new reply is a separate draft, sent as id + text only", function()
  local seed = vim.deepcopy(SEED)
  seed[1].turns[3] = { author = "you", text = "already sent server turn" }
  with_backend(seed, function(ctx)
    local id = "api:memo:7"
    T.is_nil(ctx.store.pending_you_text(ctx.store.get(id)), "a sent turn is not a draft")
    require("obelus.review").chat_save(id, "new draft")
    T.eq(texts(ctx.store.get(id)), {
      "you:why recursion?",
      "agent:It shrinks the problem.",
      "you:already sent server turn",
      "you:new draft*",
    })
    T.eq(ctx.B.threads[1].turns[3].text, "already sent server turn", "backend untouched")
    require("obelus").chat_send(id, "new draft", "send")
    local req = ctx.B.sends[1].req
    T.eq({ req.id, req.text }, { "7", "new draft" }, "the id and the new text")
    T.ok(type(req.turn_id) == "string" and req.turn_id ~= "", "and a turn id")
    T.eq(vim.tbl_count(req), 3, "nothing else (no client history)")
    ctx.B.sends[1].emit({ type = "done", text = "answer" })
    T.eq(texts(ctx.store.get(id))[4], "you:new draft", "sent and answered: now committed")
    -- dispatching a thread whose tail is a sent, unanswered turn asks for an answer
    local t = vim.deepcopy(seed[1])
    t.id = 8
    t.turns = { { author = "you", text = "unanswered", turn_id = "srv-8-1" } }
    table.insert(ctx.B.threads, t)
    api.refresh(ctx.buf)
    require("obelus").dispatch("api:memo:8")
    T.eq(ctx.B.sends[2].req, { id = "8", turn_id = "srv-8-1", text = "unanswered" }, "answer the stored turn by its id")
    -- a stored turn without an id cannot be retried safely: refused
    local u = vim.deepcopy(seed[1])
    u.id = 9
    u.turns = { { author = "you", text = "no id" } }
    table.insert(ctx.B.threads, u)
    api.refresh(ctx.buf)
    local msgs, restore = capture_notify()
    require("obelus").dispatch("api:memo:9")
    restore()
    T.eq(#ctx.B.sends, 2, "not sent")
    T.contains(vim.inspect(msgs), "no turn id")
  end)
end)

T.it("clearing a draft drops only the draft; a draft survives refresh", function()
  local seed = vim.deepcopy(SEED)
  seed[1].turns[3] = { author = "you", text = "sent" }
  with_backend(seed, function(ctx)
    local id = "api:memo:7"
    local review = require("obelus.review")
    review.chat_save(id, "my draft")
    api.refresh(ctx.buf)
    T.eq(texts(ctx.store.get(id))[4], "you:my draft*", "draft kept across refresh")
    T.eq(ctx.store.pending_you_text(ctx.store.get(id)), "my draft")
    review.chat_save(id, "")
    T.eq(#ctx.store.turns(ctx.store.get(id)), 3, "only the draft went")
    review.chat_save(id, "")
    T.eq(texts(ctx.store.get(id))[3], "you:sent", "a sent turn is never cleared")
    -- a fresh comment's reply box starts empty: saving a draft never rewrites turn 1
    local c = new_comment(ctx, 3, "first")
    review.chat_save(c.id, "reply draft")
    T.eq(texts(ctx.store.get(c.id)), { "you:first", "you:reply draft*" })
    T.eq(#calls_of(ctx.B, "update"), 0)
  end)
end)

-- ── transport ─────────────────────────────────────────────────────────────────

T.it("a turn streams through the backend transport (start/delta/done); the CLI never runs", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 2, "what is a base case?")
    local log, restore = spy_transports()
    local ok, err = pcall(function()
      require("obelus").chat_send(c.id, "and why first?", "send")
      T.eq(#ctx.B.sends, 1)
      local s = ctx.B.sends[1]
      T.eq({ s.req.id, s.req.text }, { "n1", "and why first?" })
      T.ok(require("obelus.jobs").live(ctx.store.get(c.id)), "live while streaming")
      s.emit({ type = "start" })
      s.emit({ type = "delta", text = "It stops " })
      s.emit({ type = "delta", text = "the recursion." })
      T.eq(texts(ctx.store.get(c.id))[3], "agent:It stops the recursion.*")
      s.emit({ type = "done" })
      local cc = ctx.store.get(c.id)
      T.is_nil(cc.dispatching)
      T.ok(not require("obelus.jobs").is_running(c.id))
      T.eq(texts(cc), { "you:what is a base case?", "you:and why first?", "agent:It stops the recursion." })
      s.emit({ type = "delta", text = "late" }) -- after done: ignored
      s.emit({ type = "error" })
      T.eq(texts(ctx.store.get(c.id))[3], "agent:It stops the recursion.")
    end)
    restore()
    if not ok then
      error(err, 0)
    end
    T.eq(log, {}, "no obelus transport (cli/file/…) was invoked")
  end)
end)

T.it("a backend error: fixed message, no partial reply, the message is a draft again", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 2, "q")
    local msgs, restore = capture_notify()
    require("obelus").chat_send(c.id, "follow-up", "send")
    local s = ctx.B.sends[1]
    s.emit({ type = "delta", text = "RAW-PARTIAL" })
    s.emit({ type = "error", message = "RAW-BACKEND-ERROR" })
    s.emit({ type = "done", text = "too late" })
    restore()
    local cc = ctx.store.get(c.id)
    T.is_nil(cc.dispatching)
    T.eq(ctx.store.pending_you_text(cc), "follow-up")
    T.eq(texts(cc), { "you:q", "you:follow-up*" })
    local all = vim.inspect(msgs)
    T.ok(not all:find("RAW", 1, true), "raw backend text never shown")
    T.contains(all, "obelus: the memo backend could not answer — your message is back in the draft")
    -- a send() that throws is the same failure
    ctx.B.spec.transport.send = function()
      error("RAW-THROW")
    end
    api.register_backend(ctx.B.spec)
    msgs, restore = capture_notify()
    require("obelus").chat_send(c.id, "again", "send")
    restore()
    T.ok(not vim.inspect(msgs):find("RAW", 1, true))
    T.is_nil(ctx.store.get(c.id).dispatching)
  end)
end)

T.it("one terminal transition: done then a throw keeps the reply; repeated terminals are ignored", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 2, "q")
    ctx.B.spec.transport.send = function(_, emit)
      emit({ type = "done", text = "committed answer" })
      emit({ type = "done", text = "second done" })
      emit({ type = "error" })
      error("RAW-AFTER-DONE")
    end
    api.register_backend(ctx.B.spec)
    local msgs, restore = capture_notify()
    require("obelus").chat_send(c.id, "ask", "send")
    restore()
    local cc = ctx.store.get(c.id)
    T.eq(texts(cc), { "you:q", "you:ask", "agent:committed answer" })
    T.eq(cc.last_result, "committed answer")
    T.ok(not vim.inspect(msgs):find("back in the draft", 1, true), "no failure after success")
  end)
end)

-- ── turn identity (R2-B4) ─────────────────────────────────────────────────────

-- the memo backend, made idempotent on turn_id as the contract requires;
-- B.mode decides what happens after the turn is stored: "done" | "fail" (an
-- answer failure) | "throw" (a lost acknowledgement) | "hang" (until cancel)
local function idempotent(ctx)
  local B = ctx.B
  B.mode = "done"
  B.spec.transport.send = function(req, emit)
    B.sends[#B.sends + 1] = { req = req, emit = emit }
    local t
    for _, x in ipairs(B.threads) do
      if tostring(x.id) == req.id then
        t = x
      end
    end
    local at
    for i, turn in ipairs(t.turns) do
      if turn.author == "you" and turn.turn_id == req.turn_id then
        at = i
      end
    end
    if not at then
      t.turns[#t.turns + 1] = { author = "you", text = req.text, turn_id = req.turn_id }
      at = #t.turns
    end
    local answer = t.turns[at + 1]
    if answer and answer.author == "agent" then
      return emit({ type = "done", text = answer.text }) -- already answered: replay, never redo
    end
    if B.mode == "fail" then
      return emit({ type = "error" })
    elseif B.mode == "throw" then
      error("RAW-LOST-ACK")
    elseif B.mode == "hang" then
      return function()
        B.cancels = B.cancels + 1
      end
    end
    table.insert(t.turns, at + 1, { author = "agent", text = "A: " .. req.text })
    emit({ type = "done", text = "A: " .. req.text })
  end
  api.register_backend(B.spec)
end

local function server_you(B, text)
  local n = 0
  for _, turn in ipairs(B.threads[1].turns) do
    if turn.author == "you" and turn.text == text then
      n = n + 1
    end
  end
  return n
end

T.it("turn_id: accepted then done — the reply is committed with the turn's id", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    require("obelus").chat_send("api:memo:7", "next?", "send")
    local req = ctx.B.sends[1].req
    local c = ctx.store.get("api:memo:7")
    T.eq(texts(c), { "you:why recursion?", "agent:It shrinks the problem.", "you:next?", "agent:A: next?" })
    T.eq(ctx.store.turns(c)[3].turn_id, req.turn_id)
    T.eq(server_you(ctx.B, "next?"), 1)
  end)
end)

T.it("turn_id: stored then the answer failed — a retry (with or without refresh) only asks for the answer", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "fail"
    local msgs, restore = capture_notify()
    require("obelus").chat_send("api:memo:7", "stored before failure", "send")
    restore()
    local first = ctx.B.sends[1].req.turn_id
    T.eq(server_you(ctx.B, "stored before failure"), 1, "the server stored it")
    T.eq(texts(ctx.store.get("api:memo:7"))[3], "you:stored before failure*", "a draft locally, same id")
    -- retry straight away: same id, no duplicate
    require("obelus").dispatch("api:memo:7")
    T.eq(ctx.B.sends[2].req.turn_id, first)
    T.eq(server_you(ctx.B, "stored before failure"), 1)
    -- the review's flow: refresh, then retry
    api.refresh(ctx.buf)
    local c = ctx.store.get("api:memo:7")
    T.eq(texts(c), {
      "you:why recursion?",
      "agent:It shrinks the problem.",
      "you:stored before failure",
    }, "the stored turn replaced the draft (matched by id)")
    ctx.B.mode = "done"
    require("obelus").dispatch("api:memo:7")
    T.eq(ctx.B.sends[3].req, { id = "7", turn_id = first, text = "stored before failure" })
    T.eq(server_you(ctx.B, "stored before failure"), 1, "never stored twice")
    T.eq(texts(ctx.store.get("api:memo:7"))[4], "agent:A: stored before failure")
    T.ok(not vim.inspect(msgs):find("RAW", 1, true))
  end)
end)

T.it("turn_id: cancel, then a retry with the same id", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "hang"
    require("obelus").chat_send("api:memo:7", "slow one", "send")
    require("obelus").cancel("api:memo:7")
    T.eq(ctx.B.cancels, 1)
    ctx.B.mode = "done"
    require("obelus").dispatch("api:memo:7")
    T.eq(ctx.B.sends[2].req.turn_id, ctx.B.sends[1].req.turn_id)
    T.eq(server_you(ctx.B, "slow one"), 1)
    T.eq(texts(ctx.store.get("api:memo:7"))[4], "agent:A: slow one")
  end)
end)

T.it("turn_id: a lost acknowledgement (send threw after storing) — the retry is safe", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "throw"
    local msgs, restore = capture_notify()
    require("obelus").chat_send("api:memo:7", "did it arrive?", "send")
    restore()
    T.ok(not vim.inspect(msgs):find("RAW", 1, true))
    ctx.B.mode = "done"
    require("obelus").dispatch("api:memo:7")
    T.eq(ctx.B.sends[2].req.turn_id, ctx.B.sends[1].req.turn_id)
    T.eq(server_you(ctx.B, "did it arrive?"), 1)
    T.eq(texts(ctx.store.get("api:memo:7"))[4], "agent:A: did it arrive?")
  end)
end)

T.it("turn_id: an edited draft or an intentional repeat is a NEW message (never matched by text)", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "fail"
    require("obelus").chat_send("api:memo:7", "first wording", "send")
    require("obelus").chat_send("api:memo:7", "better wording", "send")
    T.ok(ctx.B.sends[2].req.turn_id ~= ctx.B.sends[1].req.turn_id, "edited: new id")
    ctx.B.mode = "done"
    require("obelus").chat_send("api:memo:7", "again", "send")
    require("obelus").chat_send("api:memo:7", "again", "send")
    T.ok(ctx.B.sends[4].req.turn_id ~= ctx.B.sends[3].req.turn_id, "a repeat after an answer: new id")
    T.eq(server_you(ctx.B, "again"), 2, "both kept, as the user meant")
  end)
end)

T.it("turn_id: fail → edit → refresh → dispatch sends the EDITED wording under a new id", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "fail"
    local msgs, restore = capture_notify()
    require("obelus").chat_send("api:memo:7", "original failed message", "send")
    local first = ctx.B.sends[1].req.turn_id
    require("obelus.review").chat_save("api:memo:7", "new unsent wording")
    local turns = ctx.store.turns(ctx.store.get("api:memo:7"))
    local edited_id = turns[#turns].turn_id
    T.ok(edited_id and edited_id ~= first, "the edit got a new id at edit time")
    api.refresh(ctx.buf)
    local c = ctx.store.get("api:memo:7")
    T.eq(ctx.store.pending_you_text(c), "new unsent wording", "the edit survives the refresh")
    T.eq(texts(c)[3], "you:original failed message", "the stored version is history")
    ctx.B.mode = "done"
    require("obelus").dispatch("api:memo:7")
    restore()
    T.eq(ctx.B.sends[2].req.text, "new unsent wording")
    T.ok(ctx.B.sends[2].req.turn_id ~= first, "a new id for the new wording")
    T.eq(server_you(ctx.B, "original failed message"), 1)
    T.eq(server_you(ctx.B, "new unsent wording"), 1)
  end)
end)

T.it("turn_id: cancel → edit → refresh keeps the edit as a distinct draft", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "hang"
    require("obelus").chat_send("api:memo:7", "slow original", "send")
    require("obelus").cancel("api:memo:7")
    require("obelus.review").chat_save("api:memo:7", "edited after cancel")
    api.refresh(ctx.buf)
    local c = ctx.store.get("api:memo:7")
    T.eq(ctx.store.pending_you_text(c), "edited after cancel")
    T.eq(texts(c)[3], "you:slow original", "the stored original stays history")
  end)
end)

T.it("turn_id: lost ack → edit → refresh keeps the edit; an UNCHANGED draft is still reconciled", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    idempotent(ctx)
    ctx.B.mode = "throw"
    local msgs, restore = capture_notify()
    require("obelus").chat_send("api:memo:7", "maybe stored", "send")
    require("obelus.review").chat_save("api:memo:7", "maybe stored, edited")
    api.refresh(ctx.buf)
    T.eq(ctx.store.pending_you_text(ctx.store.get("api:memo:7")), "maybe stored, edited")
    -- control: an unchanged draft whose version the server stored IS reconciled
    require("obelus").chat_send("api:memo:7", "maybe stored, edited", "send")
    api.refresh(ctx.buf)
    restore()
    T.is_nil(ctx.store.pending_you_text(ctx.store.get("api:memo:7")), "stored: no draft left")
  end)
end)

T.it("turn_id: create stored → lost ack → an unchanged retry joins it; an edited retry is new", function()
  with_backend(nil, function(ctx)
    -- an idempotent create(): one thread per first-turn id; this one loses its
    -- acknowledgement (stores, then throws) on the first attempt
    local create = ctx.B.spec.store.create
    local lose_ack = true
    ctx.B.spec.store.create = function(bufnr, new)
      for _, t in ipairs(ctx.B.threads) do
        if t.turns[1].turn_id == new.turn_id then
          return vim.deepcopy(t)
        end
      end
      local t = create(bufnr, new)
      if lose_ack then
        lose_ack = false
        error("RAW-LOST-ACK")
      end
      return t
    end
    api.register_backend(ctx.B.spec)
    local render = require("obelus.render")
    local real_compose, composes = render.compose, {}
    render.compose = function(o)
      composes[#composes + 1] = o
    end
    local msgs, restore = capture_notify()
    local ok, err = pcall(function()
      require("obelus.capture")._capture(ctx.buf, ctx.file, "line", 2, nil, 2, nil, {})
      composes[1].on_submit("a first note", "send")
      T.eq(#composes, 2, "refused: the composer reopened")
      T.eq(composes[2].default, "a first note")
      composes[2].on_submit("a first note", "send") -- unchanged retry
      T.eq(#ctx.B.threads, 1, "the server has ONE thread")
      T.eq(#ctx.store.by_file(ctx.file), 1, "and obelus shows it once")
      -- an edited retry is a new message
      lose_ack = true
      require("obelus.capture")._capture(ctx.buf, ctx.file, "line", 3, nil, 3, nil, {})
      composes[3].on_submit("second", "send")
      composes[4].on_submit("second, reworded", "send")
      T.eq(#ctx.B.threads, 3, "the edited retry is its own thread")
      T.ok(ctx.B.threads[2].turns[1].turn_id ~= ctx.B.threads[3].turns[1].turn_id)
    end)
    render.compose = real_compose
    restore()
    if not ok then
      error(err, 0)
    end
    T.ok(not vim.inspect(msgs):find("RAW", 1, true))
  end)
end)

-- ── generations (B4) and reload (N1) ────────────────────────────────────────────

local function start_send(ctx, id, text)
  local n = #ctx.B.sends
  require("obelus").chat_send(id, text, "send")
  T.eq(#ctx.B.sends, n + 1, "send started")
  return ctx.B.sends[n + 1]
end

T.it('cancel reasons: an explicit user cancel is "user"; every internal path is "invalidate"', function()
  T.eq(api.capabilities.transport_cancel_reason, true)
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local function last_reason(label, fn)
      local n = #ctx.B.reasons
      start_send(ctx, id, label)
      fn()
      T.eq(#ctx.B.reasons, n + 1, label .. ": the backend's cancel ran once")
      return ctx.B.reasons[n + 1]
    end
    T.eq(
      last_reason("user cancel", function()
        require("obelus").cancel(id)
      end),
      "user"
    )
    T.eq(
      last_reason("store reload", function()
        ctx.store.load()
      end),
      "invalidate"
    )
    T.eq(
      last_reason(":ObelusLoad", function()
        vim.cmd("ObelusLoad")
      end),
      "invalidate"
    )
    local config = require("obelus.config")
    local real_root = config.options.root
    local other = vim.fn.tempname()
    vim.fn.mkdir(other, "p")
    T.eq(
      last_reason("DirChanged to another root", function()
        config.options.root = function()
          return other
        end
        vim.api.nvim_exec_autocmds("DirChanged", {})
      end),
      "invalidate"
    )
    config.options.root = real_root
    ctx.store.maybe_reload()
    T.eq(
      last_reason("replace", function()
        api.register_backend(ctx.B.spec)
      end),
      "invalidate"
    )
    T.eq(
      last_reason("delete", function()
        local msgs, restore = capture_notify()
        require("obelus.review").delete(id)
        restore()
        ctx.B.threads = vim.deepcopy(SEED)
        api.refresh(ctx.buf)
      end),
      "invalidate"
    )
    T.eq(
      last_reason("unregister", function()
        api.unregister_backend("memo")
      end),
      "invalidate"
    )
  end)
end)

T.it("terminated INSIDE send(): the cancel runs once with its reason; done/error never cancel", function()
  local function case(label, during)
    local reasons, calls = {}, 0
    local result
    with_backend(vim.deepcopy(SEED), function(ctx)
      ctx.B.spec.transport.send = function(req, emit)
        during(ctx, emit) -- terminates the send before it returns its cancel function
        return function(info)
          calls = calls + 1
          reasons[#reasons + 1] = type(info) == "table" and info.reason or "<none>"
        end
      end
      api.register_backend(ctx.B.spec)
      local msgs, restore = capture_notify()
      require("obelus").chat_send("api:memo:7", label, "send")
      restore()
      result = { calls = calls, reasons = reasons }
    end)
    return result
  end
  T.eq(
    case("user cancel inside send", function()
      require("obelus").cancel("api:memo:7")
    end),
    { calls = 1, reasons = { "user" } }
  )
  T.eq(
    case("unregister inside send", function()
      api.unregister_backend("memo")
    end),
    { calls = 1, reasons = { "invalidate" } }
  )
  T.eq(
    case("done inside send", function(_, emit)
      emit({ type = "done", text = "already answered" })
    end),
    { calls = 0, reasons = {} }
  )
  T.eq(
    case("error inside send", function(_, emit)
      emit({ type = "error" })
    end),
    { calls = 0, reasons = {} }
  )
end)

T.it("cancel, then a late done: ignored, and the backend is told", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local s = start_send(ctx, id, "more?")
    require("obelus").cancel(id)
    T.eq(ctx.B.cancels, 1)
    s.emit({ type = "done", text = "LATE" })
    local c = ctx.store.get(id)
    T.is_nil(c.dispatching)
    T.ok(not vim.tbl_contains(texts(c), "agent:LATE"))
  end)
end)

T.it("unregister then re-register: the old send's late events never touch the new run", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local old = start_send(ctx, id, "old request")
    api.unregister_backend("memo")
    T.eq(ctx.B.cancels, 1, "old send cancelled")
    T.is_nil(ctx.store.get(id))
    api.register_backend(ctx.B.spec)
    local new = start_send(ctx, id, "new request")
    old.emit({ type = "delta", text = "OLD" })
    old.emit({ type = "done", text = "OLD_REPLY_IN_NEW_RUN" })
    local c = ctx.store.get(id)
    T.ok(c.dispatching and require("obelus.jobs").is_running(id), "new run still live")
    new.emit({ type = "done", text = "new reply" })
    c = ctx.store.get(id)
    T.eq(texts(c)[#texts(c)], "agent:new reply")
    T.ok(not vim.inspect(texts(c)):find("OLD", 1, true))
  end)
end)

T.it("direct replacement while a send is in flight cancels and invalidates it", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local old = start_send(ctx, id, "old request")
    api.register_backend(ctx.B.spec) -- same name: replacement
    T.eq(ctx.B.cancels, 1)
    local c = ctx.store.get(id)
    T.ok(c and not c.dispatching and not require("obelus.jobs").is_running(id), "fresh, idle mirror")
    local new = start_send(ctx, id, "new request")
    old.emit({ type = "done", text = "OLD" })
    T.ok(require("obelus.jobs").is_running(id), "old done did not clear the new job")
    new.emit({ type = "done", text = "new reply" })
    T.eq(texts(ctx.store.get(id))[#texts(ctx.store.get(id))], "agent:new reply")
  end)
end)

T.it("a callback that no longer owns its record and job changes nothing", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local s = start_send(ctx, id, "q")
    local other = { transport = "other" }
    require("obelus.jobs").register(id, other) -- something else now owns this job slot
    s.emit({ type = "done", text = "STALE" })
    T.eq(require("obelus.jobs").get(id), other, "not cleared")
    T.ok(not vim.tbl_contains(texts(ctx.store.get(id)), "agent:STALE"), "no reply landed")
    require("obelus.jobs").clear(id)
  end)
end)

-- ── re-entrancy (R2-B5): backend callbacks that call back into the API ─────────

T.it("re-entrant list(): a replacement registered inside the old list() is not overwritten", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local old_list = ctx.B.spec.store.list
    local NEW = memo_backend()
    NEW.threads = vim.deepcopy(SEED)
    NEW.threads[1].turns[1].text = "NEW GENERATION"
    -- the live (old) registration refreshes; its list() registers a replacement
    -- of the same name, then returns its OLD list to the outer refresh
    ctx.B.spec.store.list = function(bufnr)
      api.register_backend(NEW.spec)
      return old_list(bufnr)
    end
    api.refresh(ctx.buf)
    local c = ctx.store.get("api:memo:7")
    T.eq(c.comment, "NEW GENERATION", "the newer registration's records stand")
    T.eq(#ctx.store.by_file(ctx.file), 1, "one copy")
    require("obelus").chat_send(c.id, "still yours?", "send")
    T.eq(#NEW.sends, 1, "a send goes to the live (newest) registration")
    NEW.sends[1].emit({ type = "done", text = "yes" })
    T.eq(texts(ctx.store.get(c.id))[#texts(ctx.store.get(c.id))], "agent:yes")
  end)
end)

T.it("re-entrant cancel(): unregister whose cancel registers anew and sends keeps the new work", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local NEW = memo_backend()
    NEW.threads = vim.deepcopy(SEED)
    local old_send = ctx.B.spec.transport.send
    ctx.B.spec.transport.send = function(req, emit)
      old_send(req, emit)
      return function()
        ctx.B.cancels = ctx.B.cancels + 1
        api.register_backend(NEW.spec) -- re-enters from inside the old send's cancel
        require("obelus").chat_send(id, "nested replacement request", "send")
      end
    end
    api.register_backend(ctx.B.spec)
    local old = start_send(ctx, id, "old request")
    api.unregister_backend("memo")
    T.eq(ctx.B.cancels, 1, "the old send was cancelled")
    T.eq(api.backends(), { "memo" }, "the nested registration (the latest) stands")
    local c = ctx.store.get(id)
    T.ok(c and c.dispatching, "its record exists and is sending")
    T.ok(require("obelus.jobs").is_running(id), "its job is live")
    T.eq(#NEW.sends, 1)
    T.eq(NEW.sends[1].req.text, "nested replacement request")
    old.emit({ type = "done", text = "OLD" }) -- the old send's late event: ignored
    T.ok(require("obelus.jobs").is_running(id), "still live")
    NEW.sends[1].emit({ type = "done", text = "new answer" })
    T.eq(texts(ctx.store.get(id))[#texts(ctx.store.get(id))], "agent:new answer")
    T.ok(not require("obelus.jobs").is_running(id))
  end)
end)

T.it("re-entrant create(): a replacement with a colliding id keeps ITS record; the old result is dropped", function()
  with_backend(nil, function(ctx)
    local NEW = memo_backend()
    NEW.threads = {
      {
        id = "n1",
        range = { sl = 2, el = 2 },
        turns = { { author = "you", text = "NEW OWNER RECORD", turn_id = "srv" } },
      },
    }
    local create = ctx.B.spec.store.create
    ctx.B.spec.store.create = function(bufnr, new)
      local t = create(bufnr, new) -- the OLD store keeps "OLD OWNER CREATION" as n1
      api.register_backend(NEW.spec) -- re-enters: a replacement whose own n1 differs
      return t
    end
    api.register_backend(ctx.B.spec)
    local msgs, restore = capture_notify()
    local c = new_comment(ctx, 2, "OLD OWNER CREATION")
    restore()
    T.is_nil(c, "the stale create result was not adopted")
    T.contains(vim.inspect(msgs), "changed while saving this comment")
    local mirror = ctx.store.get("api:memo:n1")
    T.eq(mirror.comment, "NEW OWNER RECORD", "the replacement's own record stands")
    T.eq(#ctx.store.by_file(ctx.file), 1)
    require("obelus").chat_send(mirror.id, "to the new owner", "send")
    T.eq(#NEW.sends, 1)
    T.eq({ NEW.sends[1].req.id, NEW.sends[1].req.text }, { "n1", "to the new owner" })
    T.eq(#ctx.B.sends, 0, "nothing went to the old registration")
  end)
end)

T.it("re-entrant match(): one that removes or replaces itself never yields a stale owner", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    -- removes itself and still says "mine", during a direct refresh
    local remove_self = false
    ctx.B.spec.match = function(bufnr)
      if remove_self then
        api.unregister_backend("memo")
        return true
      end
      return vim.api.nvim_buf_get_name(bufnr):match("^memo://") ~= nil
    end
    api.register_backend(ctx.B.spec)
    remove_self = true
    local ok, res = pcall(api.refresh, ctx.buf)
    T.ok(ok, "no error: " .. tostring(res))
    T.eq(res, false, "no owner")
    T.eq(api.backends(), {})
    T.is_nil(api.backend_for(ctx.buf))
    -- replaces itself: the replacement's answer is the only one that counts
    local NEW = memo_backend()
    NEW.threads = vim.deepcopy(SEED)
    NEW.threads[1].turns[1].text = "FROM THE REPLACEMENT"
    local B2 = memo_backend()
    B2.threads = vim.deepcopy(SEED)
    local replaced = false
    B2.spec.match = function(bufnr)
      if not replaced then
        replaced = true
        api.register_backend(NEW.spec)
      end
      return vim.api.nvim_buf_get_name(bufnr):match("^memo://") ~= nil
    end
    api.register_backend(B2.spec)
    T.eq(ctx.store.get("api:memo:7").comment, "FROM THE REPLACEMENT")
    require("obelus").chat_send("api:memo:7", "hello", "send")
    T.eq({ #NEW.sends, #B2.sends }, { 1, 0 })
    -- while saving a new comment: a match() that replaces its registration
    -- must not get the comment created in the OLD registration's store
    local C3 = memo_backend()
    local NEW2 = memo_backend()
    local armed = false
    C3.spec.match = function(bufnr)
      if armed then
        armed = false
        api.register_backend(NEW2.spec)
      end
      return vim.api.nvim_buf_get_name(bufnr):match("^memo://") ~= nil
    end
    api.register_backend(C3.spec)
    armed = true
    local msgs, restore = capture_notify()
    local c = new_comment(ctx, 3, "while matching")
    restore()
    T.is_nil(c, "refused (try again)")
    T.eq(#calls_of(C3, "create"), 0, "the stale registration's store was never asked to create it")
    T.contains(vim.inspect(msgs), "changed while saving this comment")
  end)
end)

T.it("re-entrant delete()/resolve(): a refresh inside them never drops or edits the wrong record", function()
  local seed = vim.deepcopy(SEED)
  seed[2] = { id = 8, range = { sl = 3, el = 3 }, turns = { { author = "you", text = "keep me", turn_id = "k" } } }
  with_backend(seed, function(ctx)
    local del, res = ctx.B.spec.store.delete, ctx.B.spec.store.resolve
    ctx.B.spec.store.delete = function(id)
      del(id)
      api.refresh(ctx.buf) -- e.g. a synchronous RPC wait that pumps the loop
    end
    ctx.B.spec.store.resolve = function(id, r)
      res(id, r)
      api.refresh(ctx.buf)
    end
    api.register_backend(ctx.B.spec)
    require("obelus.review").resolve("api:memo:8")
    T.eq(ctx.store.get("api:memo:8").status, "resolved", "the refreshed mirror shows the backend's truth")
    local msgs, restore = capture_notify()
    require("obelus.review").delete("api:memo:7")
    restore()
    T.is_nil(ctx.store.get("api:memo:7"))
    T.ok(ctx.store.get("api:memo:8"), "the other thread is still there")
    T.eq(#ctx.store.by_file(ctx.file), 1)
  end)
end)

T.it("a store reload rebuilds the mirrors and ends in-flight sends", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    local id = "api:memo:7"
    local s = start_send(ctx, id, "q")
    ctx.store.save()
    ctx.store.load()
    T.eq(#ctx.store.by_file(ctx.file), 1, "mirror rebuilt")
    T.eq(ctx.B.cancels, 1)
    s.emit({ type = "done", text = "STALE" })
    local c = ctx.store.get(id)
    T.ok(not c.dispatching and not vim.tbl_contains(texts(c), "agent:STALE"))
    -- and the buffer is not marked as listed already: showing it again re-lists
    ctx.B.threads[1].turns[2].text = "changed on the server"
    ctx.store.load()
    T.eq(texts(ctx.store.get(id))[2], "agent:changed on the server")
  end)
end)

-- ── fail closed: non-file records, legacy and transitive (B1) ───────────────────

local SECRET = "REVIEW_LEGACY_SECRET"

local function legacy(file, id)
  return { id = id or "legacy", file = file, range = { sl = 1, el = 1 }, kind = "line", comment = SECRET }
end

-- run the REAL cli transport with vim.system intercepted; returns spawned?, err
local function real_cli(payload)
  local orig, spawned = vim.system, false
  vim.system = function()
    spawned = true
    error("intercepted")
  end
  local ok, err = pcall(require("obelus.transport").transports.cli, payload)
  vim.system = orig
  return spawned, ok, err
end

T.it("restart with a claimed-scheme record in the JSONL: quarantined, kept on disk, never sent", function()
  local ctx = T.fresh()
  clear_backends()
  fresh_claims()
  api.claim_schemes({ "memo" })
  claims._reset() -- "restart": this process's claims are gone, only the file remains
  local path = ctx.store.store_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({
    vim.json.encode(legacy("memo://guide/closed")),
    vim.json.encode(T.comment({ id = "plain", file = ctx.root .. "/a.lua", comment = "plain" })),
  }, path)
  ctx.store.load()
  local rec = ctx.store.get("legacy")
  T.ok(rec and not ctx.store.agent_eligible(rec), "classified from the record alone")
  T.eq(
    vim.tbl_map(function(c)
      return c.id
    end, ctx.store.pending()),
    { "plain" }
  )
  local log, restore = spy_transports()
  local msgs, restore_n = capture_notify()
  local r1 = require("obelus.transport").submit("cli", { comments = { rec } })
  local r2 = require("obelus.transport").submit("cli", { comments = { ctx.store.get("plain"), rec } })
  restore_n()
  restore()
  T.eq({ r1, r2 }, { false, false })
  T.eq(log, {})
  T.contains(vim.inspect(msgs), "never sent to obelus's agents")
  local spawned, ok, err = real_cli({ comments = { rec }, markdown = SECRET, opts = { stream = true } })
  T.ok(not spawned and not ok, "the CLI refuses before any spawn")
  T.contains(tostring(err), "refusing to run the CLI agent")
  ctx.store.save()
  ctx.store.load()
  T.ok(ctx.store.get("legacy"), "kept on disk, not deleted")
end)

T.it("an unloaded or matched legacy record never reaches the CLI, even with a backend registered", function()
  with_backend(nil, function(ctx)
    local unloaded = legacy("memo://guide/unloaded", "legacy-u")
    local matched = legacy(ctx.file, "legacy-m")
    table.insert(ctx.store.comments, unloaded)
    table.insert(ctx.store.comments, matched)
    local log, restore = spy_transports()
    local msgs, restore_n = capture_notify()
    local t = require("obelus.transport")
    local r = {
      t.submit("cli", { comments = { unloaded } }),
      t.submit("cli", { comments = { matched } }),
      t.submit("file", { comments = { matched } }),
    }
    restore_n()
    restore()
    T.eq(r, { false, false, false })
    T.eq(log, {})
    T.eq(#ctx.B.sends, 0, "a legacy record is not the backend's either")
    T.ok(not real_cli({ comments = { unloaded }, markdown = "x", opts = {} }))
    T.ok(#msgs >= 3)
  end)
end)

T.it("@thread mentions and briefings never expand a legacy or backend thread", function()
  with_backend(vim.deepcopy(SEED), function(ctx)
    table.insert(ctx.store.comments, legacy(ctx.file, "legacy"))
    table.insert(ctx.store.comments, legacy("memo://guide/unloaded", "legacy2"))
    local mention = require("obelus.mention")
    local suffix = mention.prompt_suffix("see @thread:legacy @thread:legacy2 @thread:api:memo:7") or ""
    T.ok(not suffix:find(SECRET, 1, true), "no legacy content in the mention suffix")
    T.ok(not suffix:find("why recursion", 1, true), "no backend content either")
    for _, item in ipairs(mention._items and mention._items(ctx.store.root()) or {}) do
      T.ok(not tostring(item.label):find("legacy", 1, true), "not offered for completion")
    end
    local brief = require("obelus.format").meta_context()
    T.ok(not brief:find(SECRET, 1, true) and not brief:find("why recursion", 1, true), "briefing")
    -- end to end: an ordinary file thread mentioning it, then the project thread
    local log, restore = spy_transports()
    local plain = ctx.store.add(T.comment({ file = ctx.root .. "/a.lua", comment = "look @thread:legacy" }))
    require("obelus.transport").submit("cli", { comments = { plain } })
    require("obelus").chat_send(ctx.store.meta_thread().id, "summarise @thread:legacy", "send")
    restore()
    T.eq(#log, 2, "ordinary threads still go to the CLI")
    for _, entry in ipairs(log) do
      T.ok(not entry.payload.markdown:find(SECRET, 1, true), "prompt free of legacy content")
      T.ok(not entry.payload.markdown:find("why recursion", 1, true), "prompt free of backend content")
      for _, x in ipairs((entry.payload.opts or {}).actions_comments or {}) do
        T.ok(ctx.store.agent_eligible(x), "write-back targets are eligible only")
      end
    end
  end)
end)

-- run `lua_src` in a NEW nvim (a real restart) with XDG_STATE_HOME = state_home;
-- returns its stdout
local function in_new_nvim(state_home, lua_src)
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local script = vim.fn.tempname() .. ".lua"
  local guard = "dofile(" .. vim.inspect(root .. "/tests/xdg_guard.lua") .. ")('api_spec restart child')\n"
  vim.fn.writefile(vim.split(guard .. "vim.opt.rtp:prepend(" .. vim.inspect(root) .. ")\n" .. lua_src, "\n"), script)
  local env = vim.fn.environ()
  env.XDG_STATE_HOME = state_home
  local res = vim
    .system({ vim.v.progpath, "--headless", "-n", "-u", "NONE", "-i", "NONE", "-l", script }, {
      env = env,
      clear_env = true,
      text = true,
    })
    :wait(20000)
  os.remove(script)
  return (res.stdout or "") .. (res.stderr or "")
end

T.it("a claim persists: after a real restart the record is ineligible before any backend registers", function()
  local state = vim.fn.tempname()
  fresh_claims(state)
  api.claim_schemes({ "memo" })
  local out = in_new_nvim(
    state,
    [[
local store = require("obelus.store")
io.write("claimed=", table.concat(require("obelus.api").claimed_schemes(), ","), "\n")
io.write("memo=", tostring(store.agent_eligible({ file = "memo://guide/1" })), "\n")
io.write("fugitive=", tostring(store.agent_eligible({ file = "fugitive:///repo/.git//0/a.lua" })), "\n")
io.write("file=", tostring(store.agent_eligible({ file = "/tmp/a.lua" })), "\n")
]]
  )
  T.contains(out, "claimed=memo\n")
  T.contains(out, "memo=false\n")
  T.contains(out, "fugitive=true\n")
  T.contains(out, "file=true\n")
  T.eq(vim.fn.readdir(claims.dir()), { "memo" }, "one immutable file per scheme")
end)

T.it("claim_schemes with no backend: that scheme is quarantined at once; names are validated", function()
  T.fresh()
  clear_backends()
  fresh_claims()
  local store = require("obelus.store")
  T.ok(store.agent_eligible({ file = "luodda://guide/1" }), "unclaimed: eligible as before")
  T.ok(api.claim_schemes({ "luodda" }))
  T.ok(not store.agent_eligible({ file = "luodda://guide/1" }))
  T.ok(not store.agent_eligible({ file = "LUODDA://guide/1" }), "schemes are case-insensitive")
  T.ok(store.agent_eligible({ file = "fugitive:///x" }))
  T.eq(api.claimed_schemes(), { "luodda" })
  for _, bad in ipairs({ {}, { "Luodda" }, { "1x" }, { "a/b" }, "luodda" }) do
    T.ok(not pcall(api.claim_schemes, bad), vim.inspect(bad) .. " rejected")
  end
  local log, restore = spy_transports()
  local msgs, restore_n = capture_notify()
  local r = require("obelus.transport").submit("cli", { comments = { legacy("luodda://guide/1") } })
  restore_n()
  restore()
  T.eq(r, false)
  T.eq(log, {})
  T.ok(#msgs == 1)
end)

-- the claims dir in a malformed shape: every scheme:// record fails closed,
-- ordinary files don't care, and nothing there is rewritten or removed
local function malformed_case(label, make, cleanup)
  T.fresh()
  clear_backends()
  fresh_claims()
  local dir = claims.dir()
  make(dir)
  claims._reset()
  local store = require("obelus.store")
  local ok, err = pcall(function()
    T.ok(not store.agent_eligible({ file = "fugitive:///x" }), label .. ": unclassifiable scheme fails closed")
    T.ok(not store.agent_eligible({ file = "oil:///tmp/" }), label)
    T.ok(store.agent_eligible({ file = "/tmp/a.lua" }), label .. ": ordinary files untouched")
    T.ok(store.agent_eligible({ file = vim.fn.getcwd() }), label .. ": the project thread untouched")
  end)
  if cleanup then
    cleanup(dir)
  end
  if not ok then
    error(err, 0)
  end
end

T.it("malformed claims fail closed for scheme:// records only and are kept as they are", function()
  malformed_case("claims path is a regular file", function(dir)
    vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
    vim.fn.writefile({ "luodda" }, dir)
  end)
  malformed_case("entry with an invalid name", function(dir)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, dir .. "/Bad_Name") -- (not "LUODDA": APFS is case-insensitive)
    vim.fn.writefile({}, dir .. "/memo")
    local msgs, restore = capture_notify()
    T.eq(api.claim_schemes({ "luodda" }), true, "its own claim is still made durable")
    restore()
    T.contains(vim.inspect(msgs), "cannot be classified")
    T.eq(vim.fn.readdir(dir), { "Bad_Name", "luodda", "memo" }, "nothing rewritten or removed")
  end)
  malformed_case("a hidden entry", function(dir)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, dir .. "/.tmp123")
  end)
  malformed_case("an entry that is a directory", function(dir)
    vim.fn.mkdir(dir .. "/luodda", "p")
  end)
  malformed_case("an entry that is a symlink", function(dir)
    vim.fn.mkdir(dir, "p")
    vim.uv.fs_symlink("/etc/hosts", dir .. "/luodda")
  end)
  malformed_case("the claims dir cannot be listed (EACCES)", function(dir)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, dir .. "/memo")
    vim.uv.fs_chmod(dir, 0)
  end, function(dir)
    vim.uv.fs_chmod(dir, 448)
  end)
  malformed_case("stat fails with an error other than ENOENT (EACCES)", function(dir)
    vim.fn.mkdir(dir, "p")
    vim.uv.fs_chmod(vim.fn.fnamemodify(dir, ":h"), 0)
  end, function(dir)
    vim.uv.fs_chmod(vim.fn.fnamemodify(dir, ":h"), 448)
  end)
  -- recovery is manual: removing the bad entry restores classification
  fresh_claims()
  vim.fn.mkdir(claims.dir() .. "/bad name", "p")
  claims._reset()
  T.ok(not require("obelus.store").agent_eligible({ file = "fugitive:///x" }))
  vim.fn.delete(claims.dir() .. "/bad name", "d")
  T.ok(require("obelus.store").agent_eligible({ file = "fugitive:///x" }))
end)

-- record (and optionally fail) every fsync, by path; returns a controller
local function sync_recorder()
  local uv = vim.uv
  local open, close, fsync = uv.fs_open, uv.fs_close, uv.fs_fsync
  local rec = { paths = {}, attempted = {}, fail_path = nil }
  uv.fs_open = function(path, ...)
    local fd, e, c = open(path, ...)
    if fd then
      rec.paths[fd] = path
    end
    return fd, e, c
  end
  uv.fs_close = function(fd, ...)
    rec.paths[fd] = nil
    return close(fd, ...)
  end
  uv.fs_fsync = function(fd)
    local p = rec.paths[fd]
    rec.attempted[#rec.attempted + 1] = p
    if p and p == rec.fail_path then
      return nil, "EIO: injected", "EIO"
    end
    return fsync(fd)
  end
  function rec.restore()
    uv.fs_open, uv.fs_close, uv.fs_fsync = open, close, fsync
  end
  return rec
end

-- claims/ and every ancestor up to and including /
local function ancestor_chain(dir)
  local chain, d = {}, dir
  while true do
    chain[#chain + 1] = d
    local parent = vim.fn.fnamemodify(d, ":h")
    if parent == d then
      return chain
    end
    d = parent
  end
end

T.it("every claim syncs its marker, claims/ and every ancestor directory up to /", function()
  T.fresh()
  clear_backends()
  fresh_claims() -- missing: the first claim creates every level
  local rec = sync_recorder()
  local msgs, restore = capture_notify()
  local ok, err = pcall(function()
    local chain = ancestor_chain(claims.dir())
    T.eq(chain[#chain], "/")
    for _, step in ipairs({
      { "luodda", "a fresh claim" },
      { "luodda", "the same claim again (nothing to create)" },
      { "memo", "another scheme" },
    }) do
      rec.attempted = {}
      T.eq(api.claim_schemes({ step[1] }), true, step[2])
      T.ok(vim.tbl_contains(rec.attempted, claims.dir() .. "/" .. step[1]), step[2] .. ": the marker")
      for _, d in ipairs(chain) do
        T.ok(vim.tbl_contains(rec.attempted, d), step[2] .. ": synced " .. d)
      end
    end
  end)
  rec.restore()
  restore()
  if not ok then
    error(err, 0)
  end
end)

T.it("a failed sync at ANY ancestor depth keeps the claim false across a restart until it succeeds", function()
  T.fresh()
  clear_backends()
  fresh_claims()
  local depths = #ancestor_chain(claims.dir())
  local rec = sync_recorder()
  local msgs, restore = capture_notify()
  local ok, err = pcall(function()
    for depth = 1, depths do
      fresh_claims() -- a new state root each time (and no memory in this process)
      local chain = ancestor_chain(claims.dir())
      local target = chain[depth]
      rec.fail_path = target
      T.eq(api.claim_schemes({ "luodda" }), false, "depth " .. depth .. " (" .. target .. "): first claim")
      claims._reset() -- a restart: nothing remembered
      rec.attempted = {}
      T.eq(api.claim_schemes({ "luodda" }), false, "depth " .. depth .. ": after a restart, still failing")
      T.ok(vim.tbl_contains(rec.attempted, target), "depth " .. depth .. ": the failed sync was tried again")
      rec.fail_path = nil
      claims._reset()
      T.eq(api.claim_schemes({ "luodda" }), true, "depth " .. depth .. ": after a restart, once it succeeds")
    end
  end)
  rec.restore()
  restore()
  if not ok then
    error(err, 0)
  end
end)

T.it("the review's restart probe in real processes: the 4th ancestor's failed sync is never forgotten", function()
  local state = vim.fn.tempname()
  fresh_claims(state)
  -- the directory above claims/, obelus/, nvim/ and the state root: the
  -- parent of the fourth claims-path directory, which round 6 found forgotten
  local target = ancestor_chain(claims.dir())[5]
  local function child(fail)
    return in_new_nvim(state, [[
local uv = vim.uv
local open, close, fsync = uv.fs_open, uv.fs_close, uv.fs_fsync
local paths = {}
local fail = ]] .. vim.inspect(fail) .. [[

uv.fs_open = function(path, ...)
  local fd, e, c = open(path, ...)
  if fd then paths[fd] = path end
  return fd, e, c
end
uv.fs_close = function(fd, ...) paths[fd] = nil return close(fd, ...) end
uv.fs_fsync = function(fd)
  if fail and paths[fd] == fail then return nil, "EIO: injected", "EIO" end
  return fsync(fd)
end
vim.notify = function() end
io.write("saved=", tostring(require("obelus.api").claim_schemes({ "luodda" })), "\n")
]])
  end
  T.contains(child(target), "saved=false\n", "editor 1: the sync fails")
  T.contains(child(target), "saved=false\n", "editor 2 (a restart), still failing: the marker exists, still false")
  T.contains(child(nil), "saved=true\n", "editor 3 (a restart), the sync works: true")
end)

T.it("a claim whose sync fails is not reported durable; its marker stays and blocks", function()
  T.fresh()
  clear_backends()
  fresh_claims()
  local store = require("obelus.store")
  -- fail the syncs of the MARKER file only (the directory sync still works),
  -- so a marker reported durable without a successful sync is visible
  local fsync, open, close = vim.uv.fs_fsync, vim.uv.fs_open, vim.uv.fs_close
  local marker_fds = {}
  vim.uv.fs_close = function(fd, ...)
    marker_fds[fd] = nil -- fd numbers are reused (e.g. by the directory's fd)
    return close(fd, ...)
  end
  vim.uv.fs_open = function(path, ...)
    local fd, e, c = open(path, ...)
    if fd and type(path) == "string" and path:match("/luodda$") then
      marker_fds[fd] = true
    end
    return fd, e, c
  end
  vim.uv.fs_fsync = function(fd)
    if marker_fds[fd] then
      return nil, "EIO: injected", "EIO"
    end
    return fsync(fd)
  end
  local msgs, restore = capture_notify()
  local ok, err = pcall(function()
    T.eq(api.claim_schemes({ "luodda" }), false, "first claim: sync failed, not durable")
    T.ok(vim.uv.fs_stat(claims.dir() .. "/luodda"), "the marker is kept")
    claims._reset() -- a fresh reader (another editor) sees the marker
    T.ok(not store.agent_eligible({ file = "luodda://x" }), "and it blocks")
    T.eq(api.claim_schemes({ "luodda" }), false, "an existing marker is re-synced too: still not durable")
  end)
  vim.uv.fs_fsync, vim.uv.fs_open, vim.uv.fs_close = fsync, open, close
  restore()
  if not ok then
    error(err, 0)
  end
  T.eq(api.claim_schemes({ "luodda" }), true, "durable once a sync succeeds")
  -- a real type error still refuses: the claims path's parent is a file
  fresh_claims()
  vim.fn.mkdir(vim.fn.fnamemodify(claims.dir(), ":h:h"), "p")
  vim.fn.writefile({}, vim.fn.fnamemodify(claims.dir(), ":h"))
  msgs, restore = capture_notify()
  T.eq(api.claim_schemes({ "memo" }), false)
  restore()
end)

T.it("a competing creator's EEXIST on any claims-path level is not a failure (deterministic)", function()
  T.fresh()
  clear_backends()
  fresh_claims()
  local mkdir = vim.uv.fs_mkdir
  local hits = 0
  -- every mkdir loses the race: the "other editor" creates the directory first
  vim.uv.fs_mkdir = function(path, mode)
    mkdir(path, mode)
    hits = hits + 1
    return nil, "EEXIST: file already exists: " .. path, "EEXIST"
  end
  local ok, saved = pcall(api.claim_schemes, { "luodda" })
  vim.uv.fs_mkdir = mkdir
  T.ok(ok, tostring(saved))
  T.ok(hits >= 3, "intermediate parents and the claims dir all raced (" .. hits .. ")")
  T.eq(saved, true, "the claim is still made durable")
  T.ok(vim.uv.fs_stat(claims.dir() .. "/luodda"))
end)

T.it("two editors claiming at once both stay claimed (filesystem barrier, real processes)", function()
  local state = vim.fn.tempname() -- missing: both editors must create every level of the claims path
  fresh_claims(state)
  local barrier = vim.fn.tempname()
  vim.fn.mkdir(barrier, "p")
  -- each editor pauses INSIDE claim, right before its FIRST directory creation,
  -- until both have arrived; then they race through every parent, the claims
  -- dir and their exclusive claim files
  local function editor(scheme)
    return [[
local uv = vim.uv
local mkdir = uv.fs_mkdir
local barrier = ]] .. vim.inspect(barrier) .. [[

local fnmkdir = vim.fn.mkdir
local waited = false
local function arrive()
  if not waited then
    waited = true
    io.open(barrier .. "/ready-]] .. scheme .. [[", "w"):close()
    for _ = 1, 6000 do
      if uv.fs_stat(barrier .. "/go") then break end
      uv.sleep(5)
    end
  end
end
-- whichever creates the first directory (uv or vim.fn), the barrier is there
uv.fs_mkdir = function(...)
  arrive()
  return mkdir(...)
end
vim.fn.mkdir = function(...)
  arrive()
  return fnmkdir(...)
end
local saved = require("obelus.api").claim_schemes({ "]] .. scheme .. [[" })
io.write("saved=", tostring(saved), "\n")
]]
  end
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local procs, exited = {}, {}
  for _, scheme in ipairs({ "luodda", "memo" }) do
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile(
      vim.split(
        "dofile("
          .. vim.inspect(root .. "/tests/xdg_guard.lua")
          .. ")('claims race child')\n"
          .. "vim.opt.rtp:prepend("
          .. vim.inspect(root)
          .. ")\n"
          .. editor(scheme),
        "\n"
      ),
      script
    )
    local env = vim.fn.environ()
    env.XDG_STATE_HOME = state
    local i = #procs + 1
    procs[i] = vim.system(
      { vim.v.progpath, "--headless", "-n", "-u", "NONE", "-i", "NONE", "-l", script },
      { env = env, clear_env = true, text = true },
      function(res)
        exited[i] = res
      end
    )
  end
  -- fail fast: stop waiting as soon as a child exits before the barrier
  local both = vim.wait(30000, function()
    return (vim.uv.fs_stat(barrier .. "/ready-luodda") ~= nil and vim.uv.fs_stat(barrier .. "/ready-memo") ~= nil)
      or next(exited) ~= nil
  end, 10) and next(exited) == nil
  io.open(barrier .. "/go", "w"):close() -- always release, so no child is left waiting
  local results = {}
  for i, p in ipairs(procs) do
    local res = p:wait(30000) -- always reap both before asserting
    results[i] = { res.code, res.stdout, res.stderr }
  end
  T.ok(both, "both editors reached the barrier; children: " .. vim.inspect(results))
  for _, r in ipairs(results) do
    T.eq({ r[1], r[2] }, { 0, "saved=true\n" }, vim.inspect(r))
  end
  local out = in_new_nvim(
    state,
    [[
local store = require("obelus.store")
io.write("luodda=", tostring(store.agent_eligible({ file = "luodda://guide/secret" })), "\n")
io.write("memo=", tostring(store.agent_eligible({ file = "memo://x" })), "\n")
io.write("claimed=", table.concat(require("obelus.api").claimed_schemes(), ","), "\n")
]]
  )
  T.contains(out, "luodda=false\n")
  T.contains(out, "memo=false\n")
  T.contains(out, "claimed=luodda,memo\n")
end)

T.it("unclaimed scheme:// comments behave as before: with no backend and with a luodda backend", function()
  local ctx = T.fresh()
  clear_backends()
  fresh_claims()
  local fug = ctx.store.add(T.comment({ file = "fugitive:///repo/.git//0/a.lua", comment = "fugitive note" }))
  local function sends_to_cli()
    local log, restore = spy_transports()
    local r = require("obelus.transport").submit("cli", { comments = { fug } })
    restore()
    return r, #log, log[1] and log[1].payload.markdown or ""
  end
  T.ok(ctx.store.agent_eligible(fug))
  T.eq(#ctx.store.pending(), 1)
  local r, n, md = sends_to_cli()
  T.eq({ r, n }, { true, 1 })
  T.contains(md, "fugitive note")
  local B = memo_backend()
  B.spec.name, B.spec.schemes = "luodda", { "luodda" }
  api.register_backend(B.spec)
  T.ok(ctx.store.agent_eligible(fug), "still eligible with a luodda backend")
  r, n = sends_to_cli()
  T.eq({ r, n }, { true, 1 })
  T.contains(require("obelus.mention").prompt_suffix("see @thread:" .. fug.id) or "", "fugitive note")
  T.ok(not ctx.store.agent_eligible({ file = "luodda://guide/1" }))
  clear_backends()
end)

T.it("a scheme claimed after a batch: its later text never reaches the batch's rounds", function()
  local ctx = T.fresh()
  clear_backends()
  fresh_claims()
  local batch_mod = require("obelus.batch")
  local plain = ctx.store.add(T.comment({ file = ctx.root .. "/a.lua", comment = "plain target" }))
  local late = ctx.store.add(T.comment({ file = "LuOdDa://guide/late", comment = "innocuous at first" }))
  local log, restore = spy_transports()
  local b = batch_mod.create({ plain, late }, {})
  T.ok(b and b.id, "batch created")
  ctx.store.update_batch(b.id, { session_id = "sess-invented" })
  -- the plain member got a reply so it stays open; then the URI scheme is claimed
  ctx.store.add_turn(plain.id, "agent", "noted")
  ctx.store.add_turn(plain.id, "you", "please continue")
  ctx.store.clear_dispatching(plain.id)
  ctx.store.clear_dispatching(late.id)
  api.claim_schemes({ "luodda" })
  ctx.store.update(late.id, { comment = "POST_CLAIM_PRIVATE_SENTINEL", status = "resolved" })
  batch_mod.continue("go on", ctx.store.get_batch(b.id))
  restore()
  T.eq(#log, 2, "create + continue dispatched")
  local round = log[2].payload
  T.ok(not round.markdown:find("POST_CLAIM_PRIVATE_SENTINEL", 1, true), "sentinel not in the round prompt")
  T.ok(not round.markdown:find("LuOdDa://", 1, true), "the claimed record is not even named")
  T.eq(
    vim.tbl_map(function(c)
      return c.id
    end, round.comments),
    { plain.id },
    "the plain target survives as the only target"
  )
  -- the tag-leave summary never names a claimed member either
  local brief = require("obelus.format").tag_deltas("t", { joins = {}, leaves = { { id = late.id, c = late } } })
  T.ok(not brief:find("LuOdDa", 1, true) and brief:find(late.id, 1, true), "a claimed leaver is shown by id only")
end)

T.it("with no backend registered, ordinary file comments are untouched", function()
  local ctx = T.fresh()
  clear_backends()
  fresh_claims()
  local c = ctx.store.add(T.comment({ file = ctx.root .. "/a.lua" }))
  T.is_nil(c.backend)
  T.ok(c.id:match("^%d+%-%d+$"), "obelus's own id scheme")
  T.ok(ctx.store.agent_eligible(c))
  T.eq(#ctx.store.pending(), 1)
end)

-- ── approve ────────────────────────────────────────────────────────────────────

-- throw away whatever input is still queued (never EXECUTE leftovers: a flood
-- of keys run as normal-mode commands would take minutes)
local function discard_input()
  for _ = 1, 1000000 do
    if vim.fn.getchar(0) == 0 then
      return
    end
  end
end

local function with_ui(fn)
  local orig = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return { { width = 80, height = 24 } }
  end
  local saved_arm = approve.arm_ms
  local ok, err = pcall(fn)
  pcall(approve._reset)
  approve.arm_ms = saved_arm
  vim.api.nvim_list_uis = orig
  pcall(discard_input) -- never leak a queued key into the next spec
  if not ok then
    error(err, 0)
  end
end

local function prompt()
  local results = {}
  local h = api.approve({
    summary = "Write 3 cards to deck 'recursion'",
    details = "cards: base case, recursive case, stack depth",
    on_result = function(v)
      results[#results + 1] = v
    end,
  })
  return results, h, approve._active()
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "x", false)
end

local function wait_armed(a)
  T.ok(
    vim.wait(2000, function()
      return a.armed == true
    end, 5),
    "prompt armed"
  )
end

T.it("approve: headless (no UI) denies at once — no float, exactly once", function()
  T.eq(#vim.api.nvim_list_uis(), 0, "spec runs headless")
  local wins = #vim.api.nvim_list_wins()
  local results = prompt()
  T.eq(results, { false })
  T.is_nil(approve._active())
  T.eq(#vim.api.nvim_list_wins(), wins, "no float opened")
  vim.wait(20)
  T.eq(results, { false }, "still exactly once")
end)

T.it("approve: focus, let it arm, `a` approves (exactly once)", function()
  with_ui(function()
    approve.arm_ms = 30
    local src = vim.api.nvim_get_current_win()
    local results, h, a = prompt()
    T.ok(a and vim.api.nvim_win_is_valid(a.win), "float open")
    T.eq(vim.api.nvim_get_current_win(), src, "opens unfocused")
    T.eq(vim.api.nvim_win_get_config(a.win).focusable, false)
    T.ok(api.approve_focus(), "focused")
    T.ok(not a.armed, "unarmed at first")
    wait_armed(a)
    keys("a")
    T.eq(results, { true })
    T.ok(not vim.api.nvim_win_is_valid(a.win), "closed")
    h.cancel()
    vim.wait(20)
    T.eq(results, { true }, "on_result once")
  end)
end)

T.it("approve: Esc, q, Enter, closing the float and leaving it each deny", function()
  with_ui(function()
    for _, how in ipairs({ "<Esc>", "q", "close", "leave", "<CR>" }) do
      approve.arm_ms = 0
      local results, _, a = prompt()
      api.approve_focus()
      wait_armed(a)
      if how == "close" then
        vim.api.nvim_win_close(a.win, true)
      elseif how == "leave" then
        vim.cmd("wincmd p")
      else
        keys(how)
      end
      vim.wait(50, function()
        return #results > 0
      end)
      T.eq(results, { false }, how .. " denies")
      vim.wait(20)
      T.eq(results, { false }, how .. ": exactly once")
    end
    local results, h = prompt()
    h.cancel()
    T.eq(results, { false })
  end)
end)

T.it("approve: typing and typeahead in the unarmed window are ignored", function()
  with_ui(function()
    approve.arm_ms = 600
    local results, _, a = prompt()
    keys("a") -- typing in the source window never reaches the prompt
    keys("<Esc>")
    T.eq(results, {})
    T.ok(api.approve_focus())
    keys("a")
    keys("aaa")
    T.eq(results, {}, "processed while unarmed: ignored")
    T.ok(vim.api.nvim_win_is_valid(a.win), "still open")
    keys("<Esc>")
    T.eq(results, { false })
  end)
end)

T.it("approve: input queued while unarmed, with the loop blocked past the window, never approves", function()
  with_ui(function()
    approve.arm_ms = 50
    local results, _, a = prompt()
    T.ok(api.approve_focus())
    vim.api.nvim_feedkeys("a", "t", false) -- typeahead, queued, not yet executed
    vim.api.nvim_input("a") -- pending input
    vim.uv.sleep(200) -- the loop is blocked well past arm_ms
    wait_armed(a)
    T.eq(vim.fn.getchar(1), 0, "the drain consumed every queued key")
    vim.api.nvim_feedkeys("", "x", false) -- execute whatever typeahead is left
    T.eq(results, {}, "queued input did not approve")
    T.ok(vim.api.nvim_win_is_valid(a.win))
    keys("a") -- a fresh key after arming
    T.eq(results, { true })
  end)
end)

T.it("approve: 15001 keys queued BETWEEN the drains (real timers) deny instead of arming", function()
  with_ui(function()
    approve.arm_ms = 60
    local results, _, a = prompt()
    local was_unarmed
    -- the review's producer: due just before the arming timer, it schedules a
    -- flood that lands between the timer's drain and the final scheduled drain
    vim.defer_fn(function()
      vim.schedule(function()
        was_unarmed = approve._active() == a and not a.armed
        vim.api.nvim_feedkeys(string.rep("a", 15001), "t", false)
      end)
    end, 59)
    T.ok(api.approve_focus())
    vim.uv.sleep(120) -- both timers become due while the loop is stalled
    T.ok(
      vim.wait(2000, function()
        return #results > 0
      end, 5),
      "decided"
    )
    T.ok(was_unarmed, "the flood arrived while unarmed")
    T.eq(results, { false }, "cap exhausted: dismissed, never armed")
    discard_input()
  end)
end)

T.it("approve: an overflowing queue at focus denies at once", function()
  with_ui(function()
    approve.arm_ms = 30
    local results, _, a = prompt()
    vim.api.nvim_feedkeys(string.rep("a", approve.drain_cap + 1), "t", false)
    T.ok(api.approve_focus())
    T.eq(results, { false })
    T.ok(not vim.api.nvim_win_is_valid(a.win), "closed")
    discard_input()
  end)
end)

T.it("approve: sustained input while unarmed denies (the queue is never seen empty within the cap)", function()
  with_ui(function()
    approve.arm_ms = 50
    local results, _, a = prompt()
    local t = vim.uv.new_timer()
    t:start(0, 1, function() -- a producer that keeps typing
      vim.schedule(function()
        vim.api.nvim_feedkeys(string.rep("a", 4000), "t", false)
      end)
    end)
    T.ok(api.approve_focus())
    local decided = vim.wait(3000, function()
      return #results > 0 or a.armed == true -- stop the producer either way
    end, 5)
    t:stop()
    t:close()
    vim.wait(20)
    discard_input()
    T.ok(decided, "decided")
    T.ok(not a.armed, "never armed")
    T.eq(results, { false })
  end)
end)

T.it("approve: a queued Esc during the drain is honoured as a dismissal", function()
  with_ui(function()
    approve.arm_ms = 30
    local results = prompt()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "t", false)
    T.ok(api.approve_focus())
    T.eq(results, { false })
  end)
end)

T.it("approve: Enter while still unarmed denies at once (Luodda parity)", function()
  with_ui(function()
    approve.arm_ms = 600
    local results, _, a = prompt()
    T.ok(api.approve_focus())
    T.ok(not a.armed, "unarmed")
    keys("<CR>")
    T.eq(results, { false }, "denied at once")
    T.ok(not vim.api.nvim_win_is_valid(a.win), "closed")
  end)
end)

T.it("approve handle: A open, B queued — B's focus is a no-op; B opens after A; stale focus is a no-op", function()
  with_ui(function()
    approve.arm_ms = 20
    local ra, rb, opened = {}, {}, {}
    local src = vim.api.nvim_get_current_win()
    local ha = api.approve({
      summary = "A",
      on_result = function(v)
        ra[#ra + 1] = v
      end,
      on_open = function(h)
        opened[#opened + 1] = "A"
        T.ok(h ~= nil and h.focus ~= nil, "on_open gets this prompt's handle")
      end,
    })
    local hb = api.approve({
      summary = "B",
      on_result = function(v)
        rb[#rb + 1] = v
      end,
      on_open = function()
        opened[#opened + 1] = "B"
      end,
    })
    T.eq(opened, { "A" }, "only A is open")
    local a = approve._active()
    T.eq(hb.focus(), false, "B is queued: focus does nothing")
    T.eq(vim.api.nvim_get_current_win(), src, "and A was NOT focused by it")
    T.ok(not a.armed)
    -- A closes (denied); B opens and reports it
    T.ok(ha.focus(), "A's own handle focuses A")
    keys("q")
    T.eq(ra, { false })
    T.ok(
      vim.wait(200, function()
        return #opened == 2
      end, 5),
      "B opened"
    )
    T.eq(opened, { "A", "B" })
    local b = approve._active()
    -- A's handle is stale now: focus and cancel do nothing to B
    T.eq(ha.focus(), false, "stale focus is a no-op")
    T.ok(not b.armed and vim.api.nvim_get_current_win() ~= b.win, "B untouched by A's handle")
    ha.cancel()
    T.eq(rb, {}, "stale cancel does nothing to B")
    T.ok(hb.focus(), "B's handle focuses B")
    wait_armed(b)
    keys("a")
    T.eq(rb, { true })
    T.eq(ra, { false }, "A decided exactly once")
    T.eq(hb.focus(), false, "closed: no-op")
  end)
end)

T.it("api.capabilities: read-only flags that match the behaviour", function()
  local caps = api.capabilities
  T.eq({ caps.approval_focus_hint, caps.approval_handle, caps.approval_on_open }, { true, true, true })
  T.ok(not pcall(function()
    caps.approval_handle = false
  end), "read-only")
  T.ok(not pcall(function()
    caps.new_flag = true
  end), "no new keys")
  T.eq(getmetatable(caps), false, "the freeze cannot be undone")
  T.is_nil(caps.no_such_capability)
  with_ui(function()
    approve.arm_ms = 0
    local opened, lines
    local h = api.approve({
      summary = "caps",
      focus_hint = ",A / :Luodda approve",
      on_result = function() end,
      on_open = function(handle)
        opened = handle
        lines = vim.api.nvim_buf_get_lines(approve._active().buf, 0, -1, false)
      end,
    })
    -- approval_handle
    T.eq({ type(h.cancel), type(h.focus) }, { "function", "function" })
    -- approval_on_open
    T.ok(opened == h, "on_open received this prompt's handle")
    -- approval_focus_hint
    T.ok(vim.tbl_contains(lines, "Focus: ,A / :Luodda approve, wait, then a approves"), vim.inspect(lines))
    h.cancel()
  end)
end)

T.it("approve: focus_hint rejects bidi, format and C1 controls, and is bounded in bytes", function()
  local rejected = {
    ["bidi sentinel: RIGHT-TO-LEFT OVERRIDE"] = "A\226\128\174B", -- U+202E
    ["LEFT-TO-RIGHT ISOLATE"] = "A\226\129\166B", -- U+2066
    ["RIGHT-TO-LEFT MARK"] = "A\226\128\143B", -- U+200F
    ["ARABIC LETTER MARK"] = "A\216\156B", -- U+061C
    ["ZERO WIDTH SPACE"] = "A\226\128\139B", -- U+200B
    ["BYTE ORDER MARK"] = "\239\187\191AB", -- U+FEFF
    ["SOFT HYPHEN"] = "A\194\173B", -- U+00AD
    ["C1 NEXT LINE"] = "A\194\133B", -- U+0085
    ["LINE SEPARATOR"] = "A\226\128\168B", -- U+2028
    ["TAG LATIN SMALL A"] = "A\243\160\129\161B", -- U+E0061
    ["DEL"] = "A\127B",
    ["invalid UTF-8"] = "A\255B",
    ["over 128 bytes, few cells"] = "e" .. string.rep("\204\129", 70), -- 141 bytes, 1 cell
    ["over 32 cells"] = string.rep("x", 33),
  }
  for label, hint in pairs(rejected) do
    T.ok(not pcall(api.approve, { summary = "x", focus_hint = hint, on_result = function() end }), label .. " rejected")
    T.eq(approve._hint_ok(hint), false, label)
  end
  for _, good in ipairs({ ",A / :Luodda approve", "Ärger · ok", string.rep("x", 32) }) do
    T.eq(approve._hint_ok(good), true, vim.inspect(good) .. " accepted")
  end
  T.is_nil(approve._active(), "nothing was queued")
end)

T.it("approve: focus_hint is validated; absent, the default instruction is unchanged", function()
  for _, bad in ipairs({ 42, "two\nlines", "", "   ", string.rep("x", 33), "tab\there" }) do
    T.ok(
      not pcall(api.approve, { summary = "x", focus_hint = bad, on_result = function() end }),
      vim.inspect(bad) .. " rejected"
    )
  end
  T.is_nil(approve._active(), "a rejected call queues nothing")
  with_ui(function()
    local lines
    api.approve({
      summary = "default",
      on_result = function() end,
      on_open = function()
        lines = vim.api.nvim_buf_get_lines(approve._active().buf, 0, -1, false)
      end,
    })
    T.ok(vim.tbl_contains(lines, "Focus: :ObelusApprove, wait, then a approves"), vim.inspect(lines))
  end)
end)

T.it("approve: a queued prompt waits its turn; validation rejects a missing on_result", function()
  T.ok(not pcall(api.approve, { summary = "x" }))
  with_ui(function()
    approve.arm_ms = 0
    local r1, _, a1 = prompt()
    local r2 = prompt()
    T.eq(approve._active(), a1)
    api.approve_focus()
    keys("q")
    T.eq(r1, { false })
    vim.wait(50, function()
      return approve._active() ~= nil
    end)
    local a2 = approve._active()
    T.ok(a2 and a2 ~= a1, "second prompt shown")
    api.approve_focus()
    wait_armed(a2)
    keys("a")
    T.eq(r2, { true })
  end)
end)

-- ── turn events (display only) ─────────────────────────────────────────────────

-- with_backend, but the memo backend registers with `turn_events` = te
local function with_events(te, fn)
  local ctx = T.fresh()
  clear_backends()
  fresh_claims()
  local B = memo_backend()
  B.threads = vim.deepcopy(SEED)
  B.spec.turn_events = te
  api.register_backend(B.spec)
  ctx.buf = memo_buffer()
  ctx.B = B
  ctx.file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":p")
  local ok, err = pcall(fn, ctx)
  teardown(ctx)
  if not ok then
    error(err, 0)
  end
end

-- the thread as text rows (content rows only), as thread.build lays it out
local function shown(c, live)
  local out = {}
  for _, r in ipairs(require("obelus.thread").build(c, 80, { live = live, spinner = "*" })) do
    if r.kind == "content" then
      local parts = {}
      for _, ch in ipairs(r.chunks) do
        parts[#parts + 1] = ch[1]
      end
      out[#out + 1] = table.concat(parts)
    end
  end
  return out
end

local function has_row(rows, text)
  return vim.tbl_contains(rows, text)
end

local ID = "api:memo:7"

T.it("turn events: the capability is declared and the opt-in must be a boolean", function()
  T.eq(api.capabilities.turn_events, true)
  T.ok(not pcall(function()
    api.capabilities.turn_events = false
  end), "read-only")
  local B = memo_backend()
  B.spec.turn_events = "yes"
  T.ok(not pcall(api.register_backend, B.spec), "a non-boolean turn_events is refused")
  clear_backends()
end)

T.it("turn events: without the opt-in every new event and an error's message are ignored exactly as before", function()
  local function run(extra)
    local rows, msgs
    with_events(nil, function(ctx)
      local s = start_send(ctx, ID, "more?")
      if extra then
        s.emit({ type = "thinking", text = "THINK" })
        s.emit({ type = "tool", operation = "fetch", url = "https://example.invalid/x" })
        s.emit({ type = "notice", text = "NOTICE" })
      end
      s.emit({ type = "delta", text = "partial" })
      local c = ctx.store.get(ID)
      rows = { live = shown(c, true) }
      T.is_nil(api._meta_of(c))
      local restore
      msgs, restore = capture_notify()
      s.emit(extra and { type = "error", message = "RAW-BACKEND-MESSAGE" } or { type = "error" })
      restore()
      rows.after = shown(ctx.store.get(ID), false)
      T.is_nil(api._meta_of(ctx.store.get(ID)))
    end)
    return rows, msgs
  end
  local plain_rows, plain_msgs = run(false)
  local rows, msgs = run(true)
  T.eq(rows, plain_rows, "the thread renders the same rows")
  T.eq(msgs, plain_msgs, "the same fixed notification")
  T.eq(msgs[1].msg, "obelus: the memo backend could not answer — your message is back in the draft")
end)

T.it("turn events: thinking, tool and notice rows show beside the reply and are never turns", function()
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    s.emit({ type = "start" })
    s.emit({ type = "notice", text = "switched to another provider" })
    s.emit({ type = "thinking", text = "Weighing the base case " })
    s.emit({ type = "thinking", text = "against the step." })
    s.emit({ type = "tool", operation = "fetch", url = "https://example.invalid/rec" })
    local c = ctx.store.get(ID)
    local rows = shown(c, true)
    T.ok(has_row(rows, "> switched to another provider"), vim.inspect(rows))
    T.ok(has_row(rows, "> fetched: https://example.invalid/rec"), vim.inspect(rows))
    T.ok(has_row(rows, "Weighing the base case against the step."), vim.inspect(rows))
    T.ok(has_row(rows, "* thinking…"), "beside the spinner row")
    -- the answer starts: the thinking goes, the lines stay above it
    s.emit({ type = "delta", text = "Because it stops." })
    s.emit({ type = "tool", operation = "search" })
    rows = shown(c, true)
    T.ok(not has_row(rows, "Weighing the base case against the step."), "thinking collapsed")
    s.emit({ type = "thinking", text = "LATE THINKING" })
    T.ok(not vim.inspect(shown(c, true)):find("LATE THINKING", 1, true), "thinking after the answer started is ignored")
    s.emit({ type = "done" })
    c = ctx.store.get(ID)
    rows = shown(c, false)
    local at = {}
    for i, r in ipairs(rows) do
      at[r] = i
    end
    T.ok(at["> switched to another provider"] < at["Because it stops."], "a line from before the answer sits above it")
    T.ok(at["> searched the web"] > at["Because it stops."], "a line from after it sits below it")
    T.ok(not at["Weighing the base case against the step."], "no thinking after the turn")
    -- never turns, never stored: the record and the backend hold only the reply
    T.eq(texts(c), { "you:why recursion?", "agent:It shrinks the problem.", "you:more?", "agent:Because it stops." })
    local dump = vim.inspect(c) .. vim.inspect(ctx.B.threads) .. vim.inspect(ctx.B.calls)
    for _, needle in ipairs({ "switched", "example.invalid", "Weighing", "searched" }) do
      T.ok(not dump:find(needle, 1, true), needle .. " is not in the record or the backend's store")
    end
  end)
end)

T.it("turn events: the next send carries only the user's text; the old rows go", function()
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    s.emit({ type = "notice", text = "NOTICE-ONE" })
    s.emit({ type = "thinking", text = "THINK-ONE" })
    s.emit({ type = "tool", operation = "open", url = "https://example.invalid/one" })
    s.emit({ type = "done", text = "first answer" })
    T.ok(has_row(shown(ctx.store.get(ID), false), "> NOTICE-ONE"))
    local s2 = start_send(ctx, ID, "and then?")
    T.eq(vim.tbl_keys(s2.req), vim.tbl_keys({ id = 1, turn_id = 1, text = 1 }))
    T.eq({ s2.req.id, s2.req.text }, { "7", "and then?" })
    T.ok(not vim.inspect(s2.req):find("ONE", 1, true), "nothing display-only is sent back")
    local rows = shown(ctx.store.get(ID), true)
    T.ok(not vim.inspect(rows):find("ONE", 1, true), "a new send clears the last reply's rows: " .. vim.inspect(rows))
    s2.emit({ type = "done", text = "second answer" })
  end)
end)

T.it("turn events: an error shows its short message under the thread and in the notification", function()
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    s.emit({ type = "tool", operation = "fetch", url = "https://example.invalid/e" })
    s.emit({ type = "delta", text = "PARTIAL" })
    local msgs, restore = capture_notify()
    s.emit({ type = "error", message = "provider overloaded\n(retry later)" })
    restore()
    local c = ctx.store.get(ID)
    T.eq(
      texts(c),
      { "you:why recursion?", "agent:It shrinks the problem.", "you:more?*" },
      "the message is a draft again"
    )
    local rows = shown(c, false)
    T.ok(has_row(rows, "agent ↩"), vim.inspect(rows))
    T.ok(has_row(rows, "> fetched: https://example.invalid/e"), vim.inspect(rows))
    T.eq(rows[#rows], "error: provider overloaded (retry later)")
    T.ok(not vim.inspect(rows):find("PARTIAL", 1, true), "the partial reply is still dropped")
    T.eq(
      msgs[1].msg,
      "obelus: the memo backend could not answer (provider overloaded (retry later)) — your message is back in the draft"
    )
    -- an error without a message: the fixed text, and no error row
    local s2 = start_send(ctx, ID, "more?")
    msgs, restore = capture_notify()
    s2.emit({ type = "error" })
    restore()
    T.eq(msgs[1].msg, "obelus: the memo backend could not answer — your message is back in the draft")
    T.ok(not vim.inspect(shown(ctx.store.get(ID), false)):find("error:", 1, true))
    T.is_nil(api._meta_of(ctx.store.get(ID)))
  end)
end)

T.it("turn events: unknown types and missing or wrong fields are ignored", function()
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    for _, ev in ipairs({
      { type = "nope", text = "UNKNOWN" },
      { type = "thinking" },
      { type = "thinking", text = 42 },
      { type = "tool" },
      { type = "tool", operation = "   " },
      { type = "tool", operation = 7 },
      { type = "tool", operation = "fetch", url = 9 },
      { type = "tool", operation = "fetch", url = "\226\128\174" }, -- only a bidi control: blank
      { type = "notice" },
      { type = "notice", text = { "x" } },
      { type = "notice", text = "\n\t " },
      "not a table",
    }) do
      s.emit(ev)
    end
    T.is_nil(api._meta_of(ctx.store.get(ID)), "nothing was kept")
    s.emit({ type = "error", message = 12 })
    T.is_nil(api._meta_of(ctx.store.get(ID)), "a non-string message shows no row")
  end)
end)

T.it("turn events: text is bounded, and the bounds are the documented ones", function()
  T.eq(api._META, { thinking_bytes = 8192, field_chars = 300, rows = 20, thinking_rows = 8 })
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    s.emit({ type = "notice", text = string.rep("n", 1000) })
    for i = 1, 25 do
      s.emit({ type = "tool", operation = "op" .. i })
    end
    s.emit({ type = "thinking", text = string.rep("word ", 4000) .. "LAST" })
    local m = api._meta_of(ctx.store.get(ID))
    T.eq(#m.rows, 20, "at most 20 lines")
    T.eq(m.rows[1].text, "> " .. string.rep("n", 299) .. "…")
    T.eq(m.rows[20].text, "> used a tool: op19")
    T.ok(m.cut and #m.thinking <= 8192 and m.thinking:sub(-4) == "LAST", "the latest 8 KiB of thinking")
    local rows = shown(ctx.store.get(ID), true)
    local think = vim.tbl_filter(function(r)
      return r:find("word", 1, true) ~= nil
    end, rows)
    T.eq(#think, 8, "8 thinking rows")
    T.ok(vim.startswith(think[1], "… "), think[1])
    for _, r in ipairs(rows) do
      T.ok(vim.fn.strdisplaywidth(r) <= 77, "one line within the width: " .. r)
    end
    s.emit({ type = "done", text = "ok" })
  end)
end)

T.it("turn events: controls, bidi and zero-width characters are neutralized", function()
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    s.emit({
      type = "notice",
      text = "a\nb\tc\27[31md\0e\194\133f \226\128\174g\226\128\139h\239\187\191i\243\160\128\129j\226\129\166k",
    })
    s.emit({ type = "tool", operation = "fe\226\128\174tch", url = "https://ex\226\128\139ample.invalid/\27]8;;x" })
    local m = api._meta_of(ctx.store.get(ID))
    T.eq(m.rows[1].text, "> a b c [31md e f ghijk")
    T.eq(m.rows[2].text, "> fetched: https://example.invalid/ ]8;;x")
    s.emit({ type = "done", text = "ok" })
  end)
end)

T.it("turn events: events after done, cancel, removal or unregister change nothing", function()
  with_events(true, function(ctx)
    local s = start_send(ctx, ID, "more?")
    s.emit({ type = "notice", text = "KEPT" })
    s.emit({ type = "done", text = "answer" })
    s.emit({ type = "notice", text = "AFTER-DONE" })
    s.emit({ type = "error", message = "AFTER-DONE-ERROR" })
    local m = api._meta_of(ctx.store.get(ID))
    T.eq(#m.rows, 1)
    T.is_nil(m.error)
    -- a cancelled turn keeps none of its rows
    local s2 = start_send(ctx, ID, "again?")
    s2.emit({ type = "notice", text = "CANCELLED" })
    require("obelus").cancel(ID)
    s2.emit({ type = "notice", text = "AFTER-CANCEL" })
    T.is_nil(api._meta_of(ctx.store.get(ID)))
    -- unregistering drops them
    local s3 = start_send(ctx, ID, "once more?")
    s3.emit({ type = "notice", text = "GONE" })
    s3.emit({ type = "done", text = "x" })
    local c = ctx.store.get(ID)
    T.ok(api._meta_of(c) ~= nil)
    api.unregister_backend("memo")
    T.is_nil(api._meta_of(c))
  end)
end)
