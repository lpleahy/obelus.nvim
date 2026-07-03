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

local F = {
  payload = nil, -- the last payload the handler received
  target = nil, -- payload.comments[1] for the in-flight stream, if any
  job = nil, -- the progress handle for the in-flight stream, if any
  acc = "", -- accumulated streamed text (grown by F.delta)
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
      F.job = progress.start({ label = "fake", comments = payload.comments })
      F.acc = ""
      -- mirror cli.lua's provenance registration so jobs.busy()/cancel() see a real
      -- job behind this thread instead of self-healing it away. Unlike cli.lua (whose
      -- cancel closure only sends SIGTERM — the registration is cleared later, async,
      -- by the exit callback once the OS actually reaps the process), the fake has no
      -- real subprocess to reap: its cancel closure IS the end of the job, so it also
      -- clears its own registration (else a cancel with no F.finish() ever following
      -- would leak the entry forever).
      local id = F.target.id
      require("obelus.jobs").register(id, {
        transport = "fake",
        cancel = function()
          F.cancelled = true
          require("obelus.jobs").clear(id)
        end,
      })
    else
      F.oneshots[#F.oneshots + 1] = payload
    end
  end)
end

-- Grow the streamed reply by one chunk. Synchronous — the spec drives the loop
-- instead of a subprocess's stdout callback.
function F.delta(chunk)
  F.acc = F.acc .. (chunk or "")
  store.stream_update(F.target.id, F.acc)
end

-- End the stream: same order as cli.lua's run_stream exit callback (clear the job
-- registration — a finished job has no live process — then finalize the turn, then
-- the spinner, then a render pass).
function F.finish(ok, session)
  require("obelus.jobs").clear(F.target.id)
  store.stream_finish(F.target.id, F.acc, session, ok ~= false)
  pcall(progress.finish, F.job, ok ~= false, F.acc)
  require("obelus.render").render_all()
end

-- Clear all recorded state between specs.
function F.reset()
  if F.target then
    require("obelus.jobs").clear(F.target.id) -- drop any leftover registration
  end
  F.payload, F.target, F.job, F.acc, F.oneshots = nil, nil, nil, "", {}
  F.cancelled = nil
end

return F
