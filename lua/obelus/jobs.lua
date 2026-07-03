-- Registry of live background agent jobs, keyed by comment id. One source of truth
-- for liveness: the store's c.dispatching says "awaiting a reply" (domain fact);
-- this registry says whether a real job still backs it, and records which transport
-- owns it (provenance) plus how to cancel it. busy()'s self-heal only fires when NO
-- registered job exists — a non-cli transport can no longer be insta-healed away
-- (a name-routed registry with a no-op default was rejected: it lacks provenance and
-- would insta-heal a live non-cli job just like the old cli-only probe did).
local store = require("obelus.store")

local M = {}

---@type table<string, { transport: string, cancel: (fun())? }>
local jobs = {}

---@param id string comment id
---@param spec { transport: string, cancel: (fun())? }
function M.register(id, spec)
  jobs[id] = spec
end

function M.clear(id)
  jobs[id] = nil
end

function M.is_running(id)
  return jobs[id] ~= nil
end

function M.get(id)
  return jobs[id]
end

-- Is a thread genuinely mid-dispatch? Clears a STALE `dispatching` flag (set but with
-- no registered job — e.g. left over from a crash, reload, or lost callback) so it can
-- never block replies forever. Only self-heals when NO job is registered at all; once
-- ANY transport has registered a job for this id, that's trusted (provenance-aware).
function M.busy(id)
  local c = id and store.get(id)
  if not (c and c.dispatching) then
    return false
  end
  if jobs[id] ~= nil then
    return true
  end
  store.abort(id) -- stale flag, no live job: clear it and let the reply through
  require("obelus.review").refresh() -- lazy: review top-requires jobs (avoid a load cycle)
  return false
end

-- Cancel the in-flight job for a comment (best-effort; the owning transport decides
-- how). Returns whether a job/closure actually existed to cancel.
function M.cancel(id)
  local spec = jobs[id]
  if not (spec and spec.cancel) then
    return false
  end
  pcall(spec.cancel)
  return true
end

-- Cancel every registered job (review.clear uses this before wiping the store out
-- from under them).
function M.cancel_all()
  for id in pairs(jobs) do
    M.cancel(id)
  end
end

-- Is `c` genuinely streaming right now — dispatching AND a real job backs it? The
-- "thinking…" spinner must never outlive its subprocess: trust `dispatching` only
-- if a registered job of ANY transport actually backs it (self-heals a stale flag
-- from a crash, a lost callback, or a throw in the finish path). The one helper
-- callers pass into thread.build's opts.live — thread.lua is a pure formatter and
-- no longer requires jobs.lua directly.
function M.live(c)
  return c ~= nil and c.dispatching == true and M.is_running(c.id)
end

return M
