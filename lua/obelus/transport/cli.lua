local config = require("obelus.config")
local store = require("obelus.store")
local stream = require("obelus.stream")
local jobs = require("obelus.jobs")

-- cancelled[id]: set by M.cancel (via jobs.lua's cancel closure) so the exit
-- callback can tell a real SIGTERM apart from a natural exit. Liveness itself now
-- lives in jobs.lua (single owner, records provenance) — no local `running` table.
local cancelled = {}

-- Headless execution of a CLI agent (e.g. `claude -p`) in the project root.
--   one-shot (default): --output-format json; parse the final result; resolve.
--   streaming (opts.stream): --output-format stream-json; grow the agent turn live.
-- The output-format is managed here, so transport.cli.cmd should NOT set it.

-- drop the given value-taking flags (and their values) from a cmd, so obelus owns
-- them — it always sets --output-format itself, and --model per send-mode
local function strip_flags(cmd, flags)
  local out, i = {}, 1
  while i <= #cmd do
    if vim.tbl_contains(flags, cmd[i]) then
      i = i + 2
    else
      out[#out + 1] = cmd[i]
      i = i + 1
    end
  end
  return out
end

local function base_cmd(resume, model)
  local c = config.options.transport.cli or {}
  local cmd = strip_flags(vim.deepcopy(c.cmd or { "claude", "-p" }), { "--output-format", "--model" })
  if model and model ~= "" then
    table.insert(cmd, "--model")
    table.insert(cmd, tostring(model))
  end
  if resume then
    table.insert(cmd, "--resume")
    table.insert(cmd, tostring(resume))
  end
  return cmd, c
end

local function notify_done(label, ok, code)
  if config.options.transport.notify ~= true then
    return -- opt-in: the run still lands in :ObelusJobs / the thread updates inline
  end
  vim.notify(
    "obelus: " .. label .. (ok and " finished — :ObelusJobs for output" or " failed (" .. tostring(code) .. ")"),
    ok and vim.log.levels.INFO or vim.log.levels.ERROR
  )
end

local function run_oneshot(payload)
  local actions = require("obelus.actions")
  local first = payload.comments and payload.comments[1]
  -- per-job actions-file key: per-BATCH (not per-round — a resumed session
  -- remembers the round-1 filename), else the first comment's id (a comment can
  -- only be in one live dispatch at a time, so that's collision-free too)
  local akey = (payload.opts and payload.opts.batch and payload.opts.batch.id) or (first and first.id) or "adhoc"
  local allowed = {}
  for _, cm in ipairs(payload.comments or {}) do
    allowed[cm.id] = true
  end
  if payload.opts and payload.opts.batch then
    -- a batch dispatch may also `reopen` a previously-resolved member that isn't
    -- in this round's working set
    for _, cm in ipairs(store.batch_members(payload.opts.batch)) do
      allowed[cm.id] = true
    end
  end
  local use_actions = config.options.transport.actions ~= false
  local prompt = payload.markdown
  if use_actions then
    prompt = prompt .. "\n\n" .. actions.instructions(payload.comments, akey)
  end
  local cmd, c = base_cmd(payload.opts and payload.opts.resume, payload.opts and payload.opts.model)
  -- STREAM the batch (not a blocking --output-format json) so the user sees the
  -- agent working live instead of a spinner that looks hung. The deltas grow a
  -- TRANSIENT progress turn on the first comment; the real per-comment outcomes
  -- still come from the per-job .ai/review-actions-<key>.json via actions.apply().
  vim.list_extend(cmd, { "--output-format", "stream-json", "--verbose", "--include-partial-messages" })
  local sysopts = { cwd = store.root(), text = true, timeout = c.timeout or 240000 }
  if c.stdin then
    sysopts.stdin = prompt
  else
    table.insert(cmd, prompt)
  end
  require("obelus.log").set_prompt(prompt) -- :ObelusPrompt shows exactly what was sent

  for _, cm in ipairs(payload.comments or {}) do
    cancelled[cm.id] = nil
    jobs.register(cm.id, { transport = "cli" }) -- mark live immediately (a cancel
    -- closure is attached below once spawn succeeds) so the dispatching cross-check
    -- in thread.build never sees a gap before vim.system returns
    store.update(cm.id, { dispatching = true }) -- show a spinner in the band/popup
  end
  -- the batch has no single "target" turn; surface the live stream on the first
  -- comment as a transient agent turn that grows with the deltas (a "working…"
  -- preview), then discard it before applying the per-comment actions
  if first then
    store.stream_start(first.id)
  end
  require("obelus.review").refresh()
  local progress = require("obelus.progress")
  local job = progress.start({ label = cmd[1], comments = payload.comments })

  -- grow the transient progress turn; the progress timer re-renders in sync.
  -- (the collector owns the line buffering + delta/result precedence — stream.lua)
  local col = stream.collector(function(text)
    vim.schedule(function()
      if first then
        store.stream_update(first.id, text)
      end
    end)
  end)
  sysopts.stdout = function(_, data)
    col.feed(data)
  end

  local ok_spawn, obj = pcall(vim.system, cmd, sysopts, function(res)
    vim.schedule(function()
      local acc, session = col.text(), col.session()
      -- cancelled: M.cancel already aborted the thread, so don't surface the
      -- SIGTERM exit (143) as an error or attach a turn — just drop the handles
      local was_cancelled = false
      for _, cm in ipairs(payload.comments or {}) do
        jobs.clear(cm.id)
        if cancelled[cm.id] then
          cancelled[cm.id] = nil
          was_cancelled = true
        end
      end
      if was_cancelled then
        -- drop the busy flags + the transient preview turn so nothing strands on
        -- "thinking…" and the planning text isn't left behind as a fake reply
        for _, cm in ipairs(payload.comments or {}) do
          store.clear_dispatching(cm.id)
        end
        if first then
          store.stream_discard(first.id)
        end
        progress.finish(job, false, acc)
        require("obelus.review").refresh()
        return
      end
      local ok = res.code == 0
      local text = acc
      if not ok and (res.stderr or "") ~= "" then
        text = (text ~= "" and text .. "\n" or "") .. res.stderr
      end
      -- clear `dispatching` FIRST (so a throw in the spinner job can't strand the
      -- thread on "thinking…"), then finish the spinner under pcall
      local is_batch = payload.opts and payload.opts.batch ~= nil
      for _, cm in ipairs(payload.comments or {}) do
        store.clear_dispatching(cm.id)
        -- a per-comment session is for ISOLATED per-thread replies; a batch's session
        -- belongs to the batch alone (stored below), so don't stamp it on the members —
        -- that would make a <CR> reply silently resume (and fork) the shared session
        if session and not is_batch then
          store.update(cm.id, { session_id = session })
        end
        -- With the actions protocol, per-comment outcomes come from the file;
        -- otherwise fall back to attaching the result + auto-resolving. The first
        -- comment already streamed the result into its transient turn — finalize
        -- that in place instead of appending a duplicate.
        if not use_actions then
          if first and cm.id == first.id then
            store.stream_finish(cm.id, (text or ""):sub(1, 4000), session, ok)
            store.update(cm.id, { status = ok and "resolved" or "open" })
          else
            store.add_turn(cm.id, "agent", (text or ""):sub(1, 4000))
            store.update(cm.id, { status = ok and "resolved" or "open" })
          end
        end
      end
      -- batch conversation: store the ONE shared session on the batch (not per
      -- comment) so later rounds can --resume it (obelus.batch.continue)
      if payload.opts and payload.opts.batch and session then
        store.update_batch(payload.opts.batch.id, { session_id = session })
      end
      -- actions mode: the streamed text was only a live preview — drop the transient
      -- turn BEFORE actions.apply() seeds the real per-comment turns from the file
      if use_actions and first then
        store.stream_discard(first.id)
      end
      pcall(progress.finish, job, ok, text)
      local applied = use_actions and actions.apply(akey, allowed) or 0
      require("obelus.review").refresh()
      require("obelus.log").append({
        label = cmd[1],
        ok = ok,
        text = (applied > 0 and ("[applied " .. applied .. " action(s)]\n") or "") .. text,
      })
      notify_done(cmd[1], ok, res.code)
    end)
  end)
  if not ok_spawn then
    -- vim.system itself threw synchronously (e.g. ENOENT on a missing binary):
    -- roll every payload member back to idle instead of wedging them on a spinner
    -- that no exit callback will ever arrive to clear
    for _, cm in ipairs(payload.comments or {}) do
      jobs.clear(cm.id)
      store.abort(cm.id) -- clears dispatching + pops the empty placeholder turn
    end
    pcall(progress.finish, job, false, tostring(obj))
    require("obelus.review").refresh()
    vim.notify("obelus: failed to launch " .. cmd[1] .. ": " .. tostring(obj), vim.log.levels.ERROR)
    error(obj, 0) -- re-raise: transport/init.lua's pcall catches it and skips clear_on_submit
  end
  for _, cm in ipairs(payload.comments or {}) do
    jobs.register(cm.id, {
      transport = "cli",
      cancel = function()
        cancelled[cm.id] = true
        pcall(function()
          obj:kill(15) -- SIGTERM
        end)
      end,
    })
  end
end

local function run_stream(payload)
  local target = payload.comments and payload.comments[1]
  if not target then
    return run_oneshot(payload)
  end
  local actions = require("obelus.actions")
  -- chat replies are a conversation, not a review-triage task — don't inject the
  -- actions protocol by default. It makes the agent write a keyed actions-file reply
  -- + a short "Done — wrote the reply" summary that truncated the real streamed
  -- response. Opt in with transport.chat_actions = true if you want triage in chat.
  -- opts.actions_comments (the project/meta thread's fan-out — review.do_respond)
  -- overrides that: it's ALWAYS on then, and the protocol lists (and `allowed`
  -- below permits) every id in that list rather than just `target` — acting on
  -- OTHER threads from the project chat is the entire point of that send.
  local actions_comments = payload.opts and payload.opts.actions_comments
  local use_actions = actions_comments ~= nil or config.options.transport.chat_actions == true
  local prompt = payload.markdown
  if use_actions then
    prompt = prompt .. "\n\n" .. actions.instructions(actions_comments or payload.comments, target.id)
  end
  -- keep replies clean for the in-editor markdown renderer (markview): zero-width
  -- spaces show up literally as <200b> and break fenced-code/table parsing
  prompt = prompt
    .. "\n\n[Formatting] Reply in normal GitHub-flavored Markdown. Do NOT insert zero-width"
    .. " spaces or other invisible characters. To show a fenced code block INSIDE a code block,"
    .. " use a longer OUTER fence (four or more backticks) instead of escaping the inner fence."
  local cmd, c = base_cmd(payload.opts and payload.opts.resume, payload.opts and payload.opts.model)
  vim.list_extend(cmd, { "--output-format", "stream-json", "--verbose", "--include-partial-messages" })
  local sysopts = { cwd = store.root(), text = true, timeout = c.timeout or 240000 }
  if c.stdin then
    sysopts.stdin = prompt
  else
    table.insert(cmd, prompt)
  end
  require("obelus.log").set_prompt(prompt) -- :ObelusPrompt shows exactly what was sent

  cancelled[target.id] = nil
  store.stream_start(target.id)
  jobs.register(target.id, { transport = "cli" }) -- mark live immediately (a cancel
  -- closure is attached below once spawn succeeds) so the dispatching cross-check
  -- in thread.build never sees a gap before vim.system returns
  local progress = require("obelus.progress")
  local job = progress.start({ label = cmd[1], comments = payload.comments })

  -- grow the stored turn; the progress timer re-renders bands/sidebar in sync.
  -- (the collector owns the line buffering + delta/result precedence — stream.lua).
  -- final_start() feeds thread.build's live narration-greying (grey while streaming).
  local col = stream.collector(function(text)
    vim.schedule(function()
      store.stream_update(target.id, text, col.final_start())
    end)
  end)
  sysopts.stdout = function(_, data)
    col.feed(data)
  end

  local ok_spawn, obj = pcall(vim.system, cmd, sysopts, function(res)
    vim.schedule(function()
      local acc, session = col.text(), col.session()
      jobs.clear(target.id)
      if cancelled[target.id] then
        cancelled[target.id] = nil
        progress.finish(job, false, acc) -- M.cancel already aborted the thread
        return
      end
      local ok = res.code == 0
      -- CHAT-only narration collapse (render.narration, default "collapse"): store
      -- ONLY the final block once the stream settles — the interim "let me check X"
      -- narration and its separators vanish. BATCH runs never reach this function
      -- (run_oneshot above has its own finish path — see its notes), so this can't
      -- affect a batch's actions-file / transient-preview finish.
      acc = stream.collapse(acc, col.final_start(), (config.options.render or {}).narration)
      if not ok and (res.stderr or "") ~= "" then
        acc = (acc ~= "" and acc .. "\n" or "") .. res.stderr
      end
      -- clear `dispatching` FIRST so a throw in the spinner job can't strand the
      -- thread on "thinking…"; then finish the spinner (pcall: never let it strand)
      store.stream_finish(target.id, acc, session, ok)
      if use_actions then
        local allowed = { [target.id] = true }
        if actions_comments then
          allowed = {}
          for _, cm in ipairs(actions_comments) do
            allowed[cm.id] = true
          end
        end
        actions.apply(target.id, allowed)
      end
      pcall(progress.finish, job, ok, acc)
      require("obelus.review").refresh()
      require("obelus.log").append({ label = cmd[1], ok = ok, text = acc })
      notify_done(cmd[1], ok, res.code)
    end)
  end)
  if not ok_spawn then
    -- vim.system itself threw synchronously (e.g. ENOENT on a missing binary):
    -- roll the thread back to idle instead of wedging it on a spinner that no exit
    -- callback will ever arrive to clear
    jobs.clear(target.id)
    store.abort(target.id) -- clears dispatching + pops the empty placeholder turn
    pcall(progress.finish, job, false, tostring(obj))
    require("obelus.review").refresh()
    vim.notify("obelus: failed to launch " .. cmd[1] .. ": " .. tostring(obj), vim.log.levels.ERROR)
    error(obj, 0) -- re-raise: transport/init.lua's pcall catches it and skips clear_on_submit
  end
  jobs.register(target.id, {
    transport = "cli",
    cancel = function()
      cancelled[target.id] = true
      pcall(function()
        obj:kill(15) -- SIGTERM
      end)
    end,
  })
end

local M = {}

-- Thin compat delegates: liveness/cancellation now live in jobs.lua (single owner,
-- records provenance). Kept as one-liners for any external caller still reaching
-- through the cli transport; review.lua, thread.lua, and obelus.batch all go
-- through jobs.lua directly now.
function M.is_running(id)
  return jobs.is_running(id)
end

function M.cancel(id)
  return jobs.cancel(id)
end

-- callable: `require("obelus.transport.cli")(transport)` registers the backend
return setmetatable(M, {
  __call = function(_, transport)
    transport.register("cli", function(payload)
      if payload.opts and payload.opts.stream then
        run_stream(payload)
      else
        run_oneshot(payload)
      end
    end)
  end,
})
