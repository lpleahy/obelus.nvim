-- obelus.api: extension backends for non-file buffers, and the approve prompt.
-- Uses an invented in-memory backend ("memo://…" buffers); no CLI, no network.
T.describe("api")

local api = require("obelus.api")
local approve = require("obelus.approve")

-- An in-memory backend. B.threads is its "database"; B.calls logs every store
-- call; B.sends every transport.send (with the emit callback to drive it).
local function memo_backend()
  local B = { threads = {}, calls = {}, sends = {}, seq = 0 }
  local function find(id)
    for i, t in ipairs(B.threads) do
      if t.id == id then
        return t, i
      end
    end
  end
  B.spec = {
    name = "memo",
    label = "memo",
    match = function(bufnr)
      return vim.api.nvim_buf_get_name(bufnr):match("^memo://") ~= nil
    end,
    store = {
      list = function(bufnr)
        B.calls[#B.calls + 1] = { "list", bufnr }
        return vim.deepcopy(B.threads)
      end,
      create = function(bufnr, new)
        B.seq = B.seq + 1
        local t = {
          id = "n" .. B.seq,
          range = new.range,
          kind = new.kind,
          turns = { { author = "you", text = new.text } },
          status = "open",
        }
        B.threads[#B.threads + 1] = t
        B.calls[#B.calls + 1] = { "create", bufnr, new.text }
        return vim.deepcopy(t)
      end,
      update = function(id, fields)
        B.calls[#B.calls + 1] = { "update", id, fields.text }
        find(id).turns[1].text = fields.text
      end,
      delete = function(id)
        B.calls[#B.calls + 1] = { "delete", id }
        local _, i = find(id)
        table.remove(B.threads, i)
      end,
      resolve = function(id, resolved)
        B.calls[#B.calls + 1] = { "resolve", id, resolved }
        find(id).status = resolved and "resolved" or "open"
      end,
    },
    transport = {
      send = function(req, emit)
        B.sends[#B.sends + 1] = { req = req, emit = emit }
        return function()
          B.cancelled = true
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

-- Spy on every transport obelus could run: if any of them is invoked for a
-- backend thread, the test fails. Returns the spy log and a restore function.
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

-- fresh obelus + the memo backend + a "memo://guide/1" buffer shown in the window
local function setup(seed)
  local ctx = T.fresh()
  for _, name in ipairs(api.backends()) do
    api.unregister_backend(name)
  end
  local B = memo_backend()
  B.threads = seed or {}
  api.register_backend(B.spec)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, "memo://guide/" .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Guide", "Recursion calls itself.", "Base case first." })
  vim.api.nvim_set_current_buf(buf)
  ctx.B, ctx.buf = B, buf
  ctx.file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
  return ctx
end

local function teardown(ctx)
  for _, name in ipairs(api.backends()) do
    api.unregister_backend(name)
  end
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

T.it("api.version is semver 0.1.x and register_backend validates its spec", function()
  T.eq(api.version, "0.1.0")
  T.ok(api.version:match("^%d+%.%d+%.%d+$"), "semver")
  local B = memo_backend()
  T.ok(not pcall(api.register_backend, { name = "x" }), "missing match/store/transport")
  local bad = vim.deepcopy(B.spec)
  bad.store.resolve = nil
  T.ok(not pcall(api.register_backend, bad), "store.resolve required")
  bad = vim.deepcopy(B.spec)
  bad.name = "has space"
  T.ok(not pcall(api.register_backend, bad), "name charset")
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

T.it("list: a backend's threads are mirrored into the UI store, never into the JSONL", function()
  local seed = {
    {
      id = 7,
      range = { sl = 2, el = 2 },
      turns = { { author = "you", text = "why recursion?" }, { author = "agent", text = "It shrinks the problem." } },
    },
    { id = "bad" }, -- malformed (no range): skipped
  }
  with_backend(seed, function(ctx)
    T.ok(#calls_of(ctx.B, "list") >= 1, "listed on register/show")
    local mine = ctx.store.by_file(ctx.file)
    T.eq(#mine, 1)
    local c = mine[1]
    T.eq(c.id, "api:memo:7")
    T.eq(c.backend, "memo")
    T.eq(c.backend_id, "7")
    T.eq(c.selected_text, { "Recursion calls itself." })
    T.eq(#ctx.store.turns(c), 2)
    -- rendered like any thread: an obelus extmark sits on the buffer
    local marks = vim.api.nvim_buf_get_extmarks(ctx.buf, -1, 0, -1, {})
    T.ok(#marks > 0, "the band/sign is placed")
    -- never in the batch set, the project briefing or obelus's own JSONL
    T.eq(#ctx.store.pending(), 0)
    T.ok(not require("obelus.format").meta_context():find("why recursion", 1, true), "not in the CLI briefing")
    ctx.store.add(T.comment({ file = ctx.root .. "/a.lua", comment = "plain one" }))
    ctx.store.save()
    local saved = table.concat(vim.fn.readfile(ctx.store.store_path()), "\n")
    T.contains(saved, "plain one")
    T.ok(not saved:find("why recursion", 1, true), "backend thread not persisted locally")
  end)
end)

T.it("create / edit / resolve / reopen / delete go through the backend store", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 3, "check the base case")
    T.ok(c, "comment created")
    T.eq(c.id, "api:memo:n1")
    T.eq(c.backend_id, "n1")
    T.eq(#ctx.B.threads, 1)
    T.eq(ctx.B.threads[1].turns[1].text, "check the base case")
    T.eq(ctx.B.threads[1].range.sl, 3)
    local review = require("obelus.review")
    review.resolve(c.id)
    review.resolve(c.id) -- already resolved: no second backend call
    T.eq(calls_of(ctx.B, "resolve"), { { "resolve", "n1", true } })
    review.reopen(c.id)
    T.eq(ctx.B.threads[1].status, "open")
    ctx.store.update(c.id, { comment = "check both base cases" })
    T.eq(ctx.B.threads[1].turns[1].text, "check both base cases")
    -- a later list() shows what the backend holds
    api.refresh(ctx.buf)
    T.eq(ctx.store.get(c.id).comment, "check both base cases")
    local msgs, restore = capture_notify()
    review.delete(c.id)
    restore()
    T.eq(#ctx.B.threads, 0)
    T.is_nil(ctx.store.get(c.id))
    T.ok(#msgs >= 1)
  end)
end)

T.it("a backend store failure shows a fixed message and keeps the comment out of the JSONL", function()
  with_backend(nil, function(ctx)
    ctx.B.spec.store.create = function()
      error("RAW-STORE-ERROR from the backend")
    end
    local msgs, restore = capture_notify()
    local c = new_comment(ctx, 2, "unsaved note")
    restore()
    T.ok(c and c.backend_error, "kept in memory, flagged")
    T.eq(#msgs, 1)
    T.contains(msgs[1].msg, "obelus: the memo backend could not save this comment")
    T.ok(not msgs[1].msg:find("RAW", 1, true), "no raw backend text")
    ctx.store.save()
    T.ok(not table.concat(vim.fn.readfile(ctx.store.store_path()), "\n"):find("unsaved note", 1, true))
  end)
end)

T.it("a turn streams through the backend transport (start/delta/done); the CLI never runs", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 2, "what is a base case?")
    local log, restore = spy_transports()
    local ok, err = pcall(function()
      require("obelus").chat_send(c.id, "and why first?", "send")
      T.eq(#ctx.B.sends, 1)
      local s = ctx.B.sends[1]
      T.eq(s.req.id, "n1")
      T.eq(s.req.text, "and why first?")
      T.eq(s.req.bufnr, ctx.buf)
      T.eq(s.req.thread.turns[#s.req.thread.turns], { author = "you", text = "and why first?" })
      T.ok(require("obelus.jobs").live(ctx.store.get(c.id)), "live while streaming")
      s.emit({ type = "start" })
      s.emit({ type = "delta", text = "It stops " })
      s.emit({ type = "delta", text = "the recursion." })
      local turns = ctx.store.turns(ctx.store.get(c.id))
      T.eq(turns[#turns].text, "It stops the recursion.")
      s.emit({ type = "done" })
      local cc = ctx.store.get(c.id)
      T.is_nil(cc.dispatching)
      T.ok(not require("obelus.jobs").is_running(c.id))
      T.eq(ctx.store.turns(cc)[#ctx.store.turns(cc)], {
        author = "agent",
        text = "It stops the recursion.",
        at = ctx.store.turns(cc)[#ctx.store.turns(cc)].at,
      })
      s.emit({ type = "delta", text = "late" }) -- after done: ignored
      T.eq(ctx.store.turns(ctx.store.get(c.id))[#ctx.store.turns(cc)].text, "It stops the recursion.")
    end)
    restore()
    if not ok then
      error(err, 0)
    end
    T.eq(log, {}, "no obelus transport (cli/file/…) was invoked")
  end)
end)

T.it("a backend error: fixed message, no partial reply left, the message is a draft again", function()
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
    for _, t in ipairs(ctx.store.turns(cc)) do
      T.ok(t.author ~= "agent", "no agent turn survives a failed reply")
    end
    local all = vim.inspect(msgs)
    T.ok(not all:find("RAW", 1, true), "raw backend text never shown")
    T.contains(all, "obelus: the memo backend could not answer — your message is back in the draft")
    -- a send() that throws is the same failure
    ctx.B.spec.transport.send = function()
      error("RAW-THROW")
    end
    msgs, restore = capture_notify()
    require("obelus").chat_send(c.id, "again", "send")
    restore()
    T.ok(not vim.inspect(msgs):find("RAW", 1, true))
    T.is_nil(ctx.store.get(c.id).dispatching)
  end)
end)

T.it("the CLI transport never runs on a backend-matched buffer (every entry point)", function()
  with_backend(nil, function(ctx)
    local c = new_comment(ctx, 2, "note")
    local transport = require("obelus.transport")
    local log, restore = spy_transports()
    local msgs, restore_n = capture_notify()
    local ok, err = pcall(function()
      -- explicit cli submit of a backend thread: routed to the backend instead
      T.eq(transport.submit("cli", { comments = { c }, stream = true }), true)
      T.eq(#ctx.B.sends, 1)
      ctx.B.sends[1].emit({ type = "done", text = "ok" })
      -- several threads / a batch / a fan-out including one: refused outright
      local plain = ctx.store.add(T.comment({ file = ctx.root .. "/a.lua" }))
      T.eq(transport.submit("cli", { comments = { plain, c } }), false)
      T.eq(transport.submit("cli", { comments = { plain }, actions_comments = { plain, c } }), false)
      -- a record on the matched buffer that predates the backend (no `backend`)
      local raw = { id = "legacy-1", file = ctx.file, range = { sl = 1, el = 1 }, kind = "line", comment = "old" }
      table.insert(ctx.store.comments, raw)
      T.eq(transport.submit("cli", { comments = { raw } }), false)
      -- batch submit/dispatch-all never pick backend threads up
      T.ok(not vim.tbl_contains(ctx.store.pending(), c))
    end)
    restore_n()
    restore()
    if not ok then
      error(err, 0)
    end
    T.eq(log, {}, "no obelus transport ran")
    -- defence in depth: the real CLI transport itself refuses, before any spawn
    local orig_system = vim.system
    local spawned = false
    vim.system = function()
      spawned = true
      error("must not spawn")
    end
    local ok2, err2 = pcall(transport.transports.cli, { comments = { c }, markdown = "x", opts = { stream = true } })
    vim.system = orig_system
    T.ok(not ok2, "cli refuses")
    T.contains(tostring(err2), "refusing to run the CLI agent")
    T.ok(not spawned, "nothing spawned")
    T.ok(#msgs >= 2)
  end)
end)

T.it("with no backend registered, comments and submits are untouched", function()
  local ctx = T.fresh()
  for _, name in ipairs(api.backends()) do
    api.unregister_backend(name)
  end
  local c = ctx.store.add(T.comment({ file = ctx.root .. "/a.lua" }))
  T.is_nil(c.backend)
  T.ok(c.id:match("^%d+%-%d+$"), "obelus's own id scheme")
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

T.it("approve: focus, wait out the arming window, `a` approves (exactly once)", function()
  with_ui(function()
    approve.arm_ms = 30
    local src = vim.api.nvim_get_current_win()
    local results, h, a = prompt()
    T.ok(a and vim.api.nvim_win_is_valid(a.win), "float open")
    T.eq(vim.api.nvim_get_current_win(), src, "opens unfocused")
    T.eq(vim.api.nvim_win_get_config(a.win).focusable, false)
    T.ok(api.approve_focus(), "focused")
    vim.wait(60)
    keys("a")
    T.eq(results, { true })
    T.ok(not vim.api.nvim_win_is_valid(a.win), "closed")
    h.cancel()
    vim.wait(20)
    T.eq(results, { true }, "on_result once")
  end)
end)

T.it("approve: Esc, q, closing the float and leaving it each deny", function()
  with_ui(function()
    for _, how in ipairs({ "<Esc>", "q", "close", "leave", "<CR>" }) do
      approve.arm_ms = 0
      local results, _, a = prompt()
      api.approve_focus()
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
    -- Esc denies even before arming (unfocused prompts deny via cancel)
    local results, h = prompt()
    h.cancel()
    T.eq(results, { false })
  end)
end)

T.it("approve: typing and typeahead can never approve", function()
  with_ui(function()
    approve.arm_ms = 600
    local results, _, a = prompt()
    -- typing in the source window never reaches the prompt
    keys("a")
    keys("<Esc>")
    T.eq(results, {}, "typing elsewhere: undecided")
    T.ok(vim.api.nvim_win_is_valid(a.win))
    -- focused, but `a` typed inside the arming window is discarded
    T.ok(api.approve_focus())
    keys("a")
    keys("aaa")
    T.eq(results, {}, "typeahead ignored")
    T.ok(vim.api.nvim_win_is_valid(a.win), "still open")
    keys("<Esc>")
    T.eq(results, { false })
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
    vim.wait(10)
    keys("a")
    T.eq(r2, { true })
  end)
end)
