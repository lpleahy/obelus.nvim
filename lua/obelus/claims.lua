-- URI schemes claimed by obelus.api backends (see :h obelus-quarantine).
--
-- A record on a "scheme://…" buffer whose scheme was EVER claimed is never sent
-- to obelus's own agents, even after a restart and before its backend
-- registers again. Claims persist in stdpath("state")/obelus/claimed_schemes.json
-- ({ "version": 1, "schemes": [ ... ] }, written atomically). If that file
-- exists but cannot be read or parsed, no scheme can be classified, so EVERY
-- scheme:// record is treated as claimed (fail closed). Ordinary file records
-- never reach this module.
local M = {}

M._path = nil -- test override

local session = {} ---@type table<string, true> claims made in this process
local cache = { key = nil, set = {}, corrupt = false }
local warned = false

function M.path()
  return M._path or (vim.fn.stdpath("state") .. "/obelus/claimed_schemes.json")
end

---Is `s` a valid scheme name to claim (lowercase, RFC 3986 characters)?
function M.valid(s)
  return type(s) == "string" and s:match("^[a-z][a-z0-9+.-]*$") ~= nil
end

-- The claims on disk: set, corrupt. Re-read only when the file changed.
local function read()
  local p = M.path()
  local st = vim.uv.fs_stat(p)
  if not st then
    cache = { key = nil, set = {}, corrupt = false }
    return cache.set, false
  end
  local key = table.concat({ p, st.mtime.sec, st.mtime.nsec, st.size, st.ino }, ":")
  if cache.key == key then
    return cache.set, cache.corrupt
  end
  local set, corrupt = {}, false
  local f = io.open(p, "rb")
  local text = f and f:read("*a")
  if f then
    f:close()
  end
  local ok, data = pcall(vim.json.decode, text or "")
  if not (text and ok and type(data) == "table" and type(data.schemes) == "table") then
    corrupt = true
  else
    for _, s in ipairs(data.schemes) do
      if M.valid(s) then
        set[s] = true
      else
        corrupt = true
      end
    end
  end
  cache = { key = key, set = set, corrupt = corrupt }
  return set, corrupt
end

---May a record on a `scheme://` buffer NOT reach obelus's agents? True when the
---scheme was ever claimed, or when the claims file is unreadable/corrupt.
---@param scheme string
function M.blocks(scheme)
  scheme = scheme:lower()
  if session[scheme] then
    return true
  end
  local set, corrupt = read()
  return corrupt or set[scheme] == true
end

---Claim schemes (lowercase names, e.g. { "luodda" }) and persist the claim.
---The claim holds for this session even if it cannot be saved.
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
  local set, corrupt = read()
  local new = false
  for _, s in ipairs(schemes) do
    session[s] = true
    new = new or not set[s]
  end
  if corrupt then
    -- never overwrite: that would forget claims we can no longer read
    if not warned then
      warned = true
      vim.notify(
        "obelus: " .. M.path() .. " is unreadable — every scheme:// thread stays local until it is fixed or removed",
        vim.log.levels.WARN
      )
    end
    return false
  end
  if not new then
    return true
  end
  local all = vim.tbl_keys(set)
  for s in pairs(session) do
    if not set[s] then
      all[#all + 1] = s
    end
  end
  table.sort(all)
  local p = M.path()
  local tmp = p .. ".tmp." .. vim.uv.os_getpid()
  local ok = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(tmp, "wb"))
    assert(f:write(vim.json.encode({ version = 1, schemes = all })))
    assert(f:close())
    assert(vim.uv.fs_rename(tmp, p))
  end)
  if not ok then
    pcall(os.remove, tmp)
    vim.notify("obelus: could not save the claimed schemes — the claim holds for this session", vim.log.levels.WARN)
  end
  return ok
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
