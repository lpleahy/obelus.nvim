local config = require("obelus.config")
local store = require("obelus.store")
local stream = require("obelus.stream")
local jobs = require("obelus.jobs")

-- cancelled[id]: set by M.cancel (via jobs.lua's cancel closure) so the exit
-- callback can tell a real SIGTERM apart from a natural exit. Liveness itself now
-- lives in jobs.lua (single owner, records provenance) — no local `running` table.
local cancelled = {}

-- Headless execution of a CLI agent (e.g. `claude -p`) in the project root.
--   one-shot (default): batch submit; per-comment outcomes come from the actions file.
--   streaming (opts.stream): grow the agent turn live.
-- BOTH paths stream stdout; transport.cli.output picks how it's parsed:
--   "stream-json" (default) — Claude Code's --output-format stream-json events
--   "text"                  — raw stdout chunks ARE the reply (any plain-streaming
--                             CLI, e.g. Google's `agy -p`)
-- The streaming flags are managed here, so transport.cli.cmd should NOT set them;
-- the per-CLI flag NAMES are configurable — transport.cli.flags (model/resume/
-- stream), .plan (the read-only swap), .prompt_flag, .session (id capture).

-- claude defaults for the configurable per-CLI bits. Resolved HERE, not in
-- config.defaults: a LIST default can't be emptied through tbl_deep_extend (the
-- user's `stream = {}` would merge back into the claude list), so the defaults
-- table keeps these nil and the fallback lives at the point of use.
local DEFAULT_STREAM_ARGS = { "--output-format", "stream-json", "--verbose", "--include-partial-messages" }
local DEFAULT_PLAN = { strip = { "--permission-mode" }, strip_flags = {}, args = { "--permission-mode", "plan" } }

-- transport.cli.flags.*: `false` disables the flag outright; nil = claude default
local function flag_or(v, default)
  if v == nil then
    return default
  end
  return v
end

-- drop the given value-taking flags (and their values) from a cmd, so obelus owns
-- them — it always sets the output-format itself, and the model flag per send-mode
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

-- drop the given VALUELESS (boolean) flags from a cmd — e.g. the read-only plan
-- swap removing a --dangerously-skip-permissions that must not survive into a
-- supposedly read-only run
local function strip_bool_flags(cmd, flags)
  local out = {}
  for _, a in ipairs(cmd) do
    if not vim.tbl_contains(flags, a) then
      out[#out + 1] = a
    end
  end
  return out
end

local function base_cmd(resume, model)
  local c = config.options.transport.cli or {}
  local f = c.flags or {}
  local model_flag = flag_or(f.model, "--model")
  local resume_flag = flag_or(f.resume, "--resume")
  local strip = { "--output-format" }
  if model_flag then
    table.insert(strip, model_flag)
  end
  local cmd = strip_flags(vim.deepcopy(c.cmd or { "claude", "-p" }), strip)
  -- the global edits toggle (:ObelusEdits): read-only means every NEW spawn runs
  -- in the CLI's read-only/plan mode — the configured mode (acceptEdits etc.) is
  -- swapped out here rather than edited in the user's config, so toggling back
  -- restores their cmd exactly. transport.cli.plan owns the swap recipe: a table
  -- { strip, strip_flags, args } (default: claude's --permission-mode plan), or
  -- a function(cmd) -> cmd for anything the table form can't express.
  if not config.edits_enabled() then
    local plan = c.plan or DEFAULT_PLAN
    if type(plan) == "function" then
      cmd = plan(cmd) or cmd
    else
      cmd = strip_flags(cmd, plan.strip or {})
      cmd = strip_bool_flags(cmd, plan.strip_flags or {})
      vim.list_extend(cmd, vim.deepcopy(plan.args or {}))
    end
  end
  if model and model ~= "" and model_flag then
    vim.list_extend(cmd, { model_flag, tostring(model) })
  end
  if resume then
    if resume_flag then
      vim.list_extend(cmd, { resume_flag, tostring(resume) })
    else
      -- a resume was requested but this CLI can't (flags.resume = false): the
      -- spawn still runs, but as a FRESH conversation — the delta-only batch
      -- prompt would lack its context, so tell the user how to fix the config
      vim.notify_once(
        "obelus: transport.cli.flags.resume = false but a session resume was requested — "
          .. 'this CLI starts fresh each run; set transport.batch.mode = "stateless"',
        vim.log.levels.WARN
      )
    end
  end
  return cmd, c
end

-- Append the streaming flags, the optional session-capture log flag, and the
-- prompt itself (stdin | prompt_flag value | trailing positional). Returns the
-- temp log-file path when transport.cli.session = { flag, pattern } is set —
-- captured_session() reads + deletes it once the process exits.
local function finish_cmd(cmd, c, prompt, sysopts)
  vim.list_extend(cmd, vim.deepcopy((c.flags or {}).stream or DEFAULT_STREAM_ARGS))
  local logfile
  if type(c.session) == "table" and c.session.flag then
    logfile = vim.fn.tempname()
    vim.list_extend(cmd, { c.session.flag, logfile })
  end
  if c.stdin then
    sysopts.stdin = prompt
  elseif c.prompt_flag then
    -- CLIs whose prompt is a FLAG VALUE (e.g. `agy -p <prompt>`): appended as
    -- `<flag> <prompt>` — a trailing positional would be parsed as the value of
    -- whatever flag happens to precede it
    vim.list_extend(cmd, { c.prompt_flag, prompt })
  else
    table.insert(cmd, prompt)
  end
  return logfile
end

-- Pick the stdout collector for transport.cli.output (see stream.lua).
local function collector_for(c, on_update)
  if c.output == "text" then
    return stream.text_collector(on_update)
  end
  return stream.collector(on_update)
end

-- The session id: from the stream itself (stream-json's system/result events),
-- else extracted from the per-spawn temp log a text-mode CLI wrote — e.g. agy's
-- "Print mode: conversation=<uuid>" line, matched by transport.cli.session
-- .pattern. The temp log is consumed (deleted) either way, including on a
-- cancelled run.
local function captured_session(col, c, logfile)
  local session = col.session()
  if logfile then
    if not session then
      local fd = io.open(logfile, "r")
      if fd then
        local body = fd:read("*a") or ""
        fd:close()
        session = body:match(c.session.pattern or "conversation=([%x%-]+)")
      end
    end
    os.remove(logfile)
  end
  return session
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
  -- edits OFF (:ObelusEdits) forces the NON-actions path: plan mode can't write
  -- the actions file, so demanding it would lose the whole reply (the transient
  -- preview is discarded and apply() finds nothing) — fall back to attaching the
  -- streamed result as a plain reply instead
  local edits_ok = config.edits_enabled()
  local use_actions = config.options.transport.actions ~= false and edits_ok
  local prompt = payload.markdown
  if use_actions then
    prompt = prompt .. "\n\n" .. actions.instructions(payload.comments, akey)
  end
  local cmd, c = base_cmd(payload.opts and payload.opts.resume, payload.opts and payload.opts.model)
  -- STREAM the batch (not a blocking one-shot wait) so the user sees the agent
  -- working live instead of a spinner that looks hung. The deltas grow a
  -- TRANSIENT progress turn on the first comment; the real per-comment outcomes
  -- still come from the per-job .ai/review-actions-<key>.json via actions.apply().
  local sysopts = { cwd = store.root(), text = true, timeout = c.timeout or 240000 }
  local logfile = finish_cmd(cmd, c, prompt, sysopts)
  require("obelus.log").set_prompt(prompt) -- :ObelusPrompt shows exactly what was sent

  if type(c.before_spawn) == "function" then
    pcall(c.before_spawn, sysopts.cwd, cmd, payload)
  end

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
  local col = collector_for(c, function(text)
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
      local acc, session = col.text(), captured_session(col, c, logfile)
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
      local owner_id = payload.opts and payload.opts.session_owner_id
      for _, cm in ipairs(payload.comments or {}) do
        store.clear_dispatching(cm.id)
        -- a per-comment session is for ISOLATED per-thread replies; a batch's session
        -- belongs to the batch (or, tagged, its tag meta — see below), so don't stamp
        -- it on the members — that would make a <CR> reply silently resume (and fork)
        -- the shared session
        if session and not is_batch and not owner_id then
          store.update(cm.id, { session_id = session })
        end
        -- With the actions protocol, per-comment outcomes come from the file;
        -- otherwise fall back to attaching the result + auto-resolving. The first
        -- comment already streamed the result into its transient turn — finalize
        -- that in place instead of appending a duplicate.
        if not use_actions then
          -- read-only runs (edits toggled off) never auto-resolve: the agent
          -- couldn't act on anything, it only answered — keep the thread open
          local status = (ok and edits_ok) and "resolved" or "open"
          if first and cm.id == first.id then
            store.stream_finish(cm.id, (text or ""):sub(1, 4000), session, ok)
            store.update(cm.id, { status = status })
          else
            store.add_turn(cm.id, "agent", (text or ""):sub(1, 4000))
            store.update(cm.id, { status = status })
          end
        end
      end
      -- batch conversation: store the ONE shared session so later rounds can
      -- --resume it (obelus.batch.continue) — on the batch record itself for an
      -- UNTAGGED batch, or (session_owner_id present) on the TAGGED batch's tag
      -- meta record instead — a unified tag session defers session ownership to
      -- the tag meta, never the batch (see obelus.batch.create/continue)
      if payload.opts and payload.opts.batch and session then
        if owner_id then
          if store.get(owner_id) then
            store.update(owner_id, { session_id = session })
          else
            vim.notify(
              "obelus: the tag conversation record was deleted mid-run — its session was not saved",
              vim.log.levels.WARN
            )
          end
        else
          store.update_batch(payload.opts.batch.id, { session_id = session })
        end
      end
      if ok and payload.opts and payload.opts.on_success then
        pcall(payload.opts.on_success) -- run-level success hook (see run_stream's note)
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
  -- edits OFF (:ObelusEdits): never demand write-backs the read-only plan mode
  -- can't perform — the streamed reply lands in the thread as usual either way
  local use_actions = (actions_comments ~= nil or config.options.transport.chat_actions == true)
    and config.edits_enabled()
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
  local sysopts = { cwd = store.root(), text = true, timeout = c.timeout or 240000 }
  local logfile = finish_cmd(cmd, c, prompt, sysopts)
  require("obelus.log").set_prompt(prompt) -- :ObelusPrompt shows exactly what was sent

  if type(c.before_spawn) == "function" then
    pcall(c.before_spawn, sysopts.cwd, cmd, payload)
  end

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
  -- forward-declared: the callback closure is COMPILED before `local col = …`
  -- finishes, so referencing col inside it without this captures the GLOBAL col
  -- (nil) — "attempt to index global 'col'" on the very first delta
  local col
  col = collector_for(c, function(text)
    vim.schedule(function()
      store.stream_update(target.id, text, col.final_start())
    end)
  end)
  sysopts.stdout = function(_, data)
    col.feed(data)
  end

  local ok_spawn, obj = pcall(vim.system, cmd, sysopts, function(res)
    vim.schedule(function()
      local acc, session = col.text(), captured_session(col, c, logfile)
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
      -- unified tag session (opts.session_owner_id — review.do_respond's tagged
      -- branches): the captured session lands on the TAG META, never on `target`
      -- itself, when the owner differs (a reply on a tagged member thread X
      -- streams into X's transcript, but the session it just spoke through
      -- belongs to X's tag, not X)
      local owner_id = (payload.opts and payload.opts.session_owner_id) or target.id
      store.stream_finish(target.id, acc, owner_id == target.id and session or nil, ok)
      if session and owner_id ~= target.id then
        if store.get(owner_id) then
          store.update(owner_id, { session_id = session })
        else
          -- the tag conversation's record was deleted mid-run: the session has
          -- nowhere to land — say so instead of silently dropping continuity
          vim.notify(
            "obelus: the tag conversation record was deleted mid-run — its session was not saved",
            vim.log.levels.WARN
          )
        end
      end
      if ok and payload.opts and payload.opts.on_success then
        -- run-level success hook (tag membership commits ride this: a spawned-
        -- but-FAILED run must not advance known_ids, or the retry would skip the
        -- join briefings the agent never actually received — a silent,
        -- permanent context hole)
        pcall(payload.opts.on_success)
      end
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

-- Test hooks (tests/cli_transport_spec.lua): argv construction and session
-- extraction are pure given config.options — expose them so the per-CLI flag
-- mapping (claude regression + a text-CLI profile) is spec-testable without a
-- subprocess.
M._base_cmd = base_cmd
M._finish_cmd = finish_cmd
M._captured_session = captured_session

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
