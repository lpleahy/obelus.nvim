-- Scriptable in-process transport for end-to-end streaming specs. Mimics
-- transport/cli.lua's run_stream store/progress choreography EXACTLY (same calls,
-- same order) but driven synchronously by the spec instead of a real subprocess —
-- no vim.system, no polling, no timing flakiness.
--
-- Specs set `transport = { dispatch = "fake" }` in H.fresh's opts so
-- obelus.init's do_respond (and M.dispatch) route replies through this transport
-- instead of "cli".

local store = require("obelus.store")
local progress = require("obelus.progress")
local stream = require("obelus.stream")

local F = {
  payload = nil, -- the last payload the handler received
  target = nil, -- payload.comments[1] for the in-flight stream, if any
  job = nil, -- the progress handle for the in-flight stream, if any
  acc = "", -- accumulated streamed text (grown by F.delta/F.block_start)
  col = nil, -- the real stream.lua collector backing the in-flight stream
  oneshots = {}, -- non-stream payloads, in dispatch order
  cancelled = nil, -- set true by the registered job's cancel closure (jobs.cancel)
}

-- Register the fake transport against the live registry. Call once per spec (the
-- registry is module-level and outlives H.fresh's obelus.setup, which only resets
-- config/store state).
function F.install()
  require("obelus.transport").register("fake", function(payload)
    F.payload = payload
    F.target = payload.comments and payload.comments[1]
    if payload.opts and payload.opts.stream and F.target then
      store.stream_start(F.target.id)
      -- REGISTER BEFORE progress.start — same ordering contract as cli.lua: the
      -- progress tick can run a panel fill whose jobs.busy() cross-check would see
      -- dispatching==true with no registered job and self-heal (abort) the stream.
      -- Mirrors cli.lua's provenance registration so jobs.busy()/cancel() see a real
      -- job behind this thread. Unlike cli.lua (whose cancel closure only sends
      -- SIGTERM — the registration is cleared later, async, by the exit callback once
      -- the OS actually reaps the process), the fake has no real subprocess to reap:
      -- its cancel closure IS the end of the job, so it also clears its own
      -- registration (else a cancel with no F.finish() ever following would leak the
      -- entry forever).
      local id = F.target.id
      require("obelus.jobs").register(id, {
        transport = "fake",
        cancel = function()
          F.cancelled = true
          require("obelus.jobs").clear(id)
        end,
      })
      F.job = progress.start({ label = "fake", comments = payload.comments })
      F.acc = ""
      -- the REAL collector, same as cli.lua's run_stream — so a spec driving
      -- F.delta/F.block_start exercises the exact same block-boundary/narration
      -- bookkeeping (final_start) a live subprocess's stream-json would.
      F.col = stream.collector(function(text)
        store.stream_update(F.target.id, text, F.col.final_start())
      end)
    else
      -- mirror cli.lua's run_oneshot bookkeeping: each comment is claimed (live
      -- job + dispatching spinner flag) the moment the dispatch is accepted —
      -- store.pending()/jobs.busy() must see a dispatched thread as taken, or a
      -- second dispatch-all would double-fire it. F.finish_batch clears both.
      for _, cm in ipairs(payload.comments or {}) do
        local id = cm.id
        require("obelus.jobs").register(id, {
          transport = "fake",
          cancel = function()
            require("obelus.jobs").clear(id)
          end,
        })
        store.update(id, { dispatching = true })
      end
      F.oneshots[#F.oneshots + 1] = payload
    end
  end)
end

-- Feed one raw stream-json line through the real collector (F.delta/F.block_start
-- both funnel through this) and mirror F.acc for callers that still read it.
local function feed(ev)
  F.col.feed(vim.json.encode(ev) .. "\n")
  F.acc = F.col.text()
end

-- Grow the streamed reply by one chunk (a `content_block_delta` event) —
-- synchronous, the spec drives the loop instead of a subprocess's stdout callback.
function F.delta(chunk)
  feed({
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = chunk or "" } },
  })
end

-- Simulate a NEW text block opening (tools ran between two prose blocks) — a
-- `content_block_start` event. The lazy separator only lands once the NEXT
-- F.delta() actually produces text (see stream.lua's collector).
function F.block_start()
  feed({ type = "stream_event", event = { type = "content_block_start", content_block = { type = "text" } } })
end

-- End the stream: same order as cli.lua's run_stream exit callback (clear the job
-- registration — a finished job has no live process — then apply the CHAT
-- narration collapse exactly as run_stream does, then finalize the turn, then the
-- spinner, then a render pass).
function F.finish(ok, session)
  require("obelus.jobs").clear(F.target.id)
  local mode = (require("obelus.config").options.render or {}).narration
  local acc = stream.collapse(F.col.text(), F.col.final_start(), mode)
  F.acc = acc
  -- unified tag session (opts.session_owner_id — review.do_respond's tagged
  -- branches): mirrors cli.lua's run_stream exactly — a captured session lands on
  -- the OWNER (the tag meta) when it differs from the streaming target, never on
  -- the target's own session_id
  local owner_id = (F.payload and F.payload.opts and F.payload.opts.session_owner_id) or F.target.id
  store.stream_finish(F.target.id, acc, owner_id == F.target.id and session or nil, ok ~= false)
  if session and owner_id ~= F.target.id then
    store.update(owner_id, { session_id = session })
  end
  -- run-level success hook, mirroring cli.lua: tag membership commits ride this
  if ok ~= false and F.payload and F.payload.opts and F.payload.opts.on_success then
    pcall(F.payload.opts.on_success)
  end
  pcall(progress.finish, F.job, ok ~= false, acc)
  require("obelus.render").render_all()
end

-- Simulate a ONE-SHOT (batch) dispatch's exit-callback SESSION CAPTURE — same
-- owner-id branching as cli.lua's run_oneshot: a captured session lands on
-- opts.session_owner_id (a TAGGED batch, deferring to its tag meta) when present,
-- else on the batch record itself (an UNTAGGED batch, unchanged). Targets the
-- MOST RECENT oneshot payload (F.oneshots[#F.oneshots]) — batch.create/continue's
-- own dispatch. Turn/write-back bookkeeping (the .ai/review-actions-*.json file)
-- is a separate concern real specs don't need to simulate for session-focused
-- assertions; this only covers session capture.
---@param session? string
function F.finish_batch(session)
  local payload = F.oneshots[#F.oneshots]
  if not payload then
    return
  end
  for _, cm in ipairs(payload.comments or {}) do
    require("obelus.jobs").clear(cm.id)
    store.clear_dispatching(cm.id)
  end
  if not (session and payload.opts and payload.opts.batch) then
    return
  end
  local owner_id = payload.opts.session_owner_id
  if payload.opts.on_success then
    pcall(payload.opts.on_success) -- run-level success hook (cli.lua parity)
  end
  if owner_id then
    store.update(owner_id, { session_id = session })
  else
    store.update_batch(payload.opts.batch.id, { session_id = session })
  end
end

-- Clear all recorded state between specs.
function F.reset()
  if F.target then
    require("obelus.jobs").clear(F.target.id) -- drop any leftover registration
  end
  F.payload, F.target, F.job, F.acc, F.col, F.oneshots = nil, nil, nil, "", nil, {}
  F.cancelled = nil
end

return F
