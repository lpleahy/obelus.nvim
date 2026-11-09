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
local function persist(dir, scheme)
  local path = dir .. "/" .. scheme
  local fd, _, code = uv.fs_open(path, "wx", 420)
  if fd then
    local ok = uv.fs_write(fd, "obelus claim v1\n", 0) ~= nil
    ok = (uv.fs_fsync(fd) ~= nil) and ok
    uv.fs_close(fd)
    return ok
  end
  if code == "EEXIST" then
    local st = uv.fs_lstat(path)
    return st ~= nil and st.type == "file" -- another editor (or an earlier run) claimed it
  end
  return false
end

---Claim schemes (lowercase names, e.g. { "luodda" }) and persist the claim.
---The claim holds for this session even if it cannot be saved. Returns true
---only when every scheme's claim file exists on disk.
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
  local saved = pcall(vim.fn.mkdir, dir, "p") and vim.fn.isdirectory(dir) == 1
  if saved then
    for _, s in ipairs(schemes) do
      saved = persist(dir, s) and saved
    end
    -- make the new directory entries durable too (best effort where supported)
    local dfd = uv.fs_open(dir, "r", 0)
    if dfd then
      uv.fs_fsync(dfd)
      uv.fs_close(dfd)
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
end

return M
