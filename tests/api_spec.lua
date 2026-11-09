-- obelus.api: extension backends for non-file buffers, and the approve prompt.
-- Uses an invented in-memory backend ("memo://…" buffers); no CLI, no network.
T.describe("api")

local api = require("obelus.api")
local approve = require("obelus.approve")
local claims = require("obelus.claims")

-- every spec claims into its own temp file: never the user's state dir
local function fresh_claims(dir)
  dir = dir or vim.fn.tempname()
  claims._path = dir .. "/nvim/obelus/claimed_schemes.json" -- = stdpath("state") with XDG_STATE_HOME=dir
  claims._reset()
  return dir
end

-- An in-memory backend. B.threads is its "database"; B.calls logs every store
-- call; B.sends every transport.send (with the emit callback to drive it).
-- B.fail[op] = true makes that store op throw (a raw sentinel message).
local function memo_backend()
  local B = { threads = {}, calls = {}, sends = {}, seq = 0, fail = {}, cancels = 0 }
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
          turns = { { author = "you", text = new.text } },
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
        return function()
          B.cancels = B.cancels + 1
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

T.it("api.version is semver 0.1.x and register_backend validates its spec", function()
  T.eq(api.version, "0.1.0")
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
    T.eq(ctx.B.sends[1].req, { id = "7", text = "new draft" }, "only the id and the new text")
    ctx.B.sends[1].emit({ type = "done", text = "answer" })
    T.eq(texts(ctx.store.get(id))[4], "you:new draft", "sent and answered: now committed")
    -- dispatching a thread whose tail is a sent, unanswered turn asks for an answer
    local t = vim.deepcopy(seed[1])
    t.id = 8
    t.turns = { { author = "you", text = "unanswered" } }
    table.insert(ctx.B.threads, t)
    api.refresh(ctx.buf)
    require("obelus").dispatch("api:memo:8")
    T.eq(ctx.B.sends[2].req, { id = "8", text = "" })
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
      T.eq(s.req, { id = "n1", text = "and why first?" })
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

-- ── generations (B4) and reload (N1) ────────────────────────────────────────────

local function start_send(ctx, id, text)
  local n = #ctx.B.sends
  require("obelus").chat_send(id, text, "send")
  T.eq(#ctx.B.sends, n + 1, "send started")
  return ctx.B.sends[n + 1]
end

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
  local saved = vim.json.decode(table.concat(vim.fn.readfile(claims.path()), "\n"))
  T.eq(saved, { version = 1, schemes = { "memo" } })
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

T.it("a corrupt claims file fails closed for scheme:// records only, and is never overwritten", function()
  T.fresh()
  clear_backends()
  fresh_claims()
  vim.fn.mkdir(vim.fn.fnamemodify(claims.path(), ":h"), "p")
  vim.fn.writefile({ "{ not json" }, claims.path())
  local store = require("obelus.store")
  T.ok(not store.agent_eligible({ file = "fugitive:///x" }), "unclassifiable scheme: closed")
  T.ok(not store.agent_eligible({ file = "oil:///tmp/" }))
  T.ok(store.agent_eligible({ file = "/tmp/a.lua" }), "ordinary files untouched")
  T.ok(store.agent_eligible({ file = vim.fn.getcwd() }), "a directory (the project thread) untouched")
  local msgs, restore = capture_notify()
  T.eq(api.claim_schemes({ "luodda" }), false, "not saved")
  restore()
  T.eq(vim.fn.readfile(claims.path()), { "{ not json" }, "left as it was")
  T.contains(vim.inspect(msgs), "unreadable")
  -- an invalid entry is corrupt too
  vim.fn.writefile({ vim.json.encode({ version = 1, schemes = { "ok", "NOT OK" } }) }, claims.path())
  claims._reset()
  T.ok(not store.agent_eligible({ file = "fugitive:///x" }))
  -- removing the file recovers (claims made since still hold)
  os.remove(claims.path())
  claims._reset()
  T.ok(store.agent_eligible({ file = "fugitive:///x" }))
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
  pcall(vim.fn.getchar, 0) -- never leak a queued key into the next spec
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
