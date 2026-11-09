-- URI schemes claimed by obelus.api backends (see :h obelus-quarantine).
--
-- A record on a "scheme://…" buffer whose scheme was EVER claimed is never sent
-- to obelus's own agents, even after a restart and before its backend
-- registers again.
--
-- Storage: one immutable file per scheme,
--   stdpath("state")/obelus/claims/<scheme>
-- created exclusively (open with O_CREAT|O_EXCL, "wx") and fsynced. Writers
-- never read-merge-write, so concurrent claims from several editors cannot lose
-- each other; a claim is reported durable only once its file exists. Nothing
-- here ever rewrites or removes an entry.
--
-- Reading is strict. The directory missing (ENOENT) means "no claims". Any of
-- these means the claims cannot be classified, so EVERY scheme:// record is
-- treated as claimed (fail closed), and the entries are kept as they are:
--   * a stat error other than ENOENT, or the path is not a directory;
--   * the directory cannot be listed;
--   * an entry whose name is not a valid scheme, or that is not a regular file.
-- Ordinary file records never reach this module.
local M = {}

M._dir = nil -- test override

local uv = vim.uv or vim.loop
local session = {} ---@type table<string, true> claims made in this process
-- directories this process created ABOVE the fixed chain (see claim()) whose
-- parent has not been synced successfully yet; retried by every claim
local pending_parents = {} ---@type table<string, true>
local cache = { key = nil, set = {}, corrupt = false }
local warned = false

function M.dir()
  return M._dir or (vim.fn.stdpath("state") .. "/obelus/claims")
end

---Is `s` a valid scheme name to claim (lowercase, RFC 3986 characters)?
function M.valid(s)
  return type(s) == "string" and s:match("^[a-z][a-z0-9+.-]*$") ~= nil
end

-- The claims on disk: set, corrupt, why.
local function read()
  local dir = M.dir()
  local st, _, code = uv.fs_stat(dir)
  if not st then
    if code == "ENOENT" then
      cache = { key = nil, set = {}, corrupt = false }
      return cache.set, false
    end
    return {}, true, "cannot stat " .. dir .. " (" .. tostring(code) .. ")"
  end
  if st.type ~= "directory" then
    return {}, true, dir .. " is not a directory"
  end
  local key = table.concat({ dir, st.ino, st.mtime.sec, st.mtime.nsec, st.size }, ":")
  if cache.key == key then
    return cache.set, cache.corrupt, cache.why
  end
  local set, corrupt, why = {}, false, nil
  local handle, _, scode = uv.fs_scandir(dir)
  if not handle then
    corrupt, why = true, "cannot list " .. dir .. " (" .. tostring(scode) .. ")"
  else
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if not typ then
        local lst = uv.fs_lstat(dir .. "/" .. name)
        typ = lst and lst.type
      end
      if M.valid(name) and typ == "file" then
        set[name] = true
      else
        corrupt, why = true, "unexpected entry " .. vim.inspect(name) .. " (" .. tostring(typ) .. ") in " .. dir
      end
    end
  end
  cache = { key = key, set = set, corrupt = corrupt, why = why }
  return set, corrupt, why
end

---May a record on a `scheme://` buffer NOT reach obelus's agents? True when the
---scheme was ever claimed, or when the claims cannot be classified.
---@param scheme string
function M.blocks(scheme)
  scheme = scheme:lower()
  if session[scheme] then
    return true
  end
  local set, corrupt = read()
  return corrupt or set[scheme] == true
end

-- create <dir>/<scheme> exclusively; true when it exists as a regular file
-- fsync `fd`, retrying a few times; true once a sync succeeded
local function sync(fd)
  for _ = 1, 3 do
    if uv.fs_fsync(fd) then
      return true
    end
  end
  return false
end

-- Create `dir` and any missing parents, safe against other editors creating
-- the same path at the same time: an EEXIST (or any error) is followed by a
-- fresh look, and creation counts as done only if a directory is there now.
-- Real permission or type errors still refuse (the path is not a directory).
-- `fresh` (a list) collects every level that did not exist when we looked:
-- its new entry lives in its parent, which must be synced for durability.
local function ensure_dir(dir, fresh)
  local st = uv.fs_stat(dir)
  if st then
    return st.type == "directory"
  end
  local parent = vim.fn.fnamemodify(dir, ":h")
  if parent ~= dir and not ensure_dir(parent, fresh) then
    return false
  end
  fresh[#fresh + 1] = dir
  if uv.fs_mkdir(dir, 493) then
    return true
  end
  local again = uv.fs_stat(dir) -- someone else may have created it meanwhile
  return again ~= nil and again.type == "directory"
end

-- Make <dir>/<scheme> exist as a regular file, created exclusively, and sync
-- it. True only when the marker exists AND a sync of it succeeded (an existing
-- marker from another editor or an earlier run is synced too). A marker whose
-- sync failed is KEPT: it already blocks the scheme for every reader.
local function persist(dir, scheme)
  local path = dir .. "/" .. scheme
  local fd, _, code = uv.fs_open(path, "wx", 420)
  if fd then
    local ok = uv.fs_write(fd, "obelus claim v1\n", 0) ~= nil
    ok = sync(fd) and ok
    uv.fs_close(fd)
    return ok
  end
  if code == "EEXIST" then
    local st = uv.fs_lstat(path)
    if not (st and st.type == "file") then
      return false
    end
    local rfd = uv.fs_open(path, "r", 0)
    if not rfd then
      return false
    end
    local ok = sync(rfd)
    uv.fs_close(rfd)
    return ok
  end
  return false
end

-- Sync the claims directory itself so the new entries are durable. Where the
-- platform refuses to fsync a directory (EINVAL/ENOTSUP), that part is best
-- effort; any other failure means "not durable".
local function sync_dir(dir)
  local dfd, _, ocode = uv.fs_open(dir, "r", 0)
  if not dfd then
    return ocode == "EINVAL" or ocode == "ENOTSUP"
  end
  local ok
  for _ = 1, 3 do
    local res, _, code = uv.fs_fsync(dfd)
    if res or code == "EINVAL" or code == "ENOTSUP" then
      ok = true
      break
    end
  end
  uv.fs_close(dfd)
  return ok == true
end

---Claim schemes (lowercase names, e.g. { "luodda" }) and persist the claim.
---The claim holds for this session even if it cannot be saved. Returns true
---only when every scheme's marker file exists, a sync of each marker
---succeeded, the claims directory was synced, and so was the parent of every
---directory this claim had to create (where the platform supports syncing a
---directory; otherwise that part is best effort). On false, any
---marker already created stays: it blocks the scheme for every reader.
---@param schemes string[]
---@return boolean saved
function M.claim(schemes)
  if type(schemes) ~= "table" or #schemes == 0 then
    error("obelus.api.claim_schemes: schemes must be a non-empty list", 2)
  end
  for _, s in ipairs(schemes) do
    if not M.valid(s) then
      error("obelus.api.claim_schemes: invalid scheme " .. vim.inspect(s) .. " (lowercase, [a-z][a-z0-9+.-]*)", 2)
    end
  end
  for _, s in ipairs(schemes) do
    session[s] = true
  end
  local dir = M.dir()
  local fresh = {}
  local saved = ensure_dir(dir, fresh)
  if saved then
    for _, s in ipairs(schemes) do
      saved = persist(dir, s) and saved
    end
    -- EVERY claim re-syncs the directory entries the claims path depends on —
    -- claims/, obelus/, the state base and the base's parent — whether or not
    -- this call created them: an earlier attempt (here or in another editor)
    -- may have created them and failed their sync. True means all of these
    -- syncs succeeded in this call; an existing marker is never enough.
    local chain = {}
    local level = dir
    for _ = 1, 4 do
      chain[#chain + 1] = level
      level = vim.fn.fnamemodify(level, ":h")
    end
    local synced = {} ---@type table<string, boolean> path -> did its sync succeed
    for _, d in ipairs(chain) do
      synced[d] = sync_dir(d)
      saved = synced[d] and saved
    end
    -- a directory created above that chain (a missing state root's ancestors):
    -- its parent must be synced too; kept pending in this process until it is
    for _, d in ipairs(fresh) do
      pending_parents[d] = true
    end
    for d in pairs(pending_parents) do
      local parent = vim.fn.fnamemodify(d, ":h")
      if synced[parent] == nil then
        synced[parent] = sync_dir(parent)
      end
      if synced[parent] then
        pending_parents[d] = nil
      else
        saved = false
      end
    end
  end
  local _, corrupt, why = read()
  if corrupt and not warned then
    warned = true
    vim.notify(
      "obelus: the claimed schemes cannot be classified ("
        .. tostring(why)
        .. ") — every scheme:// thread stays local",
      vim.log.levels.WARN
    )
  end
  if not saved then
    vim.notify("obelus: could not save the claimed schemes — the claim holds for this session", vim.log.levels.WARN)
  end
  return saved
end

---Schemes claimed (on disk and this session), sorted.
function M.list()
  local set = read()
  local out = {}
  for s in pairs(set) do
    out[#out + 1] = s
  end
  for s in pairs(session) do
    if not set[s] then
      out[#out + 1] = s
    end
  end
  table.sort(out)
  return out
end

-- test hook: forget this process's claims and the cache
function M._reset()
  session, cache, warned = {}, { key = nil, set = {}, corrupt = false }, false
  pending_parents = {}
end

return M
