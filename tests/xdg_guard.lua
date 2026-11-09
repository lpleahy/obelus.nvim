-- The nvim side of the test containment guard (see tests/xdg_guard.sh). Run it
-- first, before require("obelus") or anything that could write through
-- stdpath(): `dofile("<repo>/tests/xdg_guard.lua")("<who>")`. It exits nvim
-- with status 3 unless OBELUS_TEST_ROOT is a private root (not /, not HOME or
-- an ancestor of it); every XDG_*_HOME, XDG_RUNTIME_DIR, TMPDIR, every entry of
-- XDG_CONFIG_DIRS / XDG_DATA_DIRS and NVIM_LOG_FILE is ABSOLUTE and resolves
-- inside it (a relative value would follow a later chdir); none is a
-- real default under HOME; and stdpath("data"/"state"/"cache"/"config"/"run"/
-- "log") resolve inside it. Merely non-empty values are not enough.
local uv = vim.uv or vim.loop

local function refuse(who, why)
  io.stderr:write(
    who
      .. ": refusing to run: "
      .. why
      .. ". Tests write only inside a private root: run them via make (it creates one)"
      .. " or tests/private.sh <command>.\n"
  )
  io.stderr:flush()
  os.exit(3)
end

-- realpath of `p`, or of its deepest existing ancestor (+ the rest appended)
local function resolve(p)
  local rest = ""
  while p and p ~= "" do
    local r = uv.fs_realpath(p)
    if r then
      return r .. rest
    end
    local parent = vim.fn.fnamemodify(p, ":h")
    if parent == p then
      return nil
    end
    rest = "/" .. vim.fn.fnamemodify(p, ":t") .. rest
    p = parent
  end
end

local function inside(path, root)
  return path ~= nil and path:sub(1, #root + 1) == root .. "/" and #path > #root + 1
end

return function(who)
  who = who or "obelus tests"
  local root = vim.env.OBELUS_TEST_ROOT
  if not root or root == "" then
    refuse(who, "OBELUS_TEST_ROOT is not set")
  end
  if root:sub(1, 1) ~= "/" then
    refuse(who, "OBELUS_TEST_ROOT=" .. root .. " is not absolute")
  end
  local rroot = uv.fs_realpath(root)
  if not rroot or vim.fn.isdirectory(rroot) == 0 then
    refuse(who, "OBELUS_TEST_ROOT=" .. root .. " is not a directory")
  end
  if rroot == "/" then
    refuse(who, "OBELUS_TEST_ROOT is /")
  end
  local home = vim.env.HOME
  local rhome = home and home ~= "" and uv.fs_realpath(home)
  if rhome and (rhome == rroot or inside(rhome, rroot)) then
    refuse(who, "OBELUS_TEST_ROOT=" .. root .. " contains HOME (" .. home .. ")")
  end
  -- the real defaults, canonical (symlinks resolved), so that no spelling of
  -- a path — an alias root, a symlinked component — can reach them
  local reals = {}
  if home and home ~= "" then
    for _, d in ipairs({ "/.local", "/.config", "/.cache" }) do
      reals[#reals + 1] = resolve(home .. d) or (home .. d)
    end
  end
  local function in_default(path)
    for _, real in ipairs(reals) do
      if path == real or inside(path, real) then
        return real
      end
    end
  end
  local hit = in_default(rroot)
  if hit then
    refuse(who, "OBELUS_TEST_ROOT=" .. root .. " resolves into a real default (" .. hit .. ")")
  end
  local function check(var, val)
    if val:sub(1, 1) ~= "/" then
      -- a relative value resolves against the working directory, which can
      -- change after this check (vim.fn.chdir, :cd) and carry writes outside
      refuse(who, var .. "=" .. val .. " is relative (it would follow the working directory)")
    end
    local r = resolve(val)
    hit = r and in_default(r)
    if hit then
      refuse(who, var .. "=" .. val .. " resolves into a real default (" .. hit .. ")")
    end
    if not inside(r, rroot) then
      refuse(who, var .. "=" .. val .. " is outside OBELUS_TEST_ROOT=" .. root)
    end
  end
  local vars = { "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMPDIR" }
  for _, var in ipairs(vars) do
    local val = vim.env[var]
    if not val or val == "" then
      refuse(who, var .. " is not set")
    end
    check(var, val)
  end
  for _, var in ipairs({ "XDG_CONFIG_DIRS", "XDG_DATA_DIRS" }) do
    local val = vim.env[var]
    if not val or val == "" then
      refuse(who, var .. " is not set (an unset one defaults to system dirs)")
    end
    for _, entry in ipairs(vim.split(val, ":", { plain = true })) do
      check(var .. " entry", entry)
    end
  end
  local log = vim.env.NVIM_LOG_FILE
  if not log or log == "" then
    refuse(who, "NVIM_LOG_FILE is not set")
  end
  local lst = uv.fs_lstat(log)
  if lst and lst.type == "link" then
    refuse(who, "NVIM_LOG_FILE=" .. log .. " is a symlink")
  end
  if lst and lst.type ~= "file" then
    refuse(who, "NVIM_LOG_FILE=" .. log .. " is not a regular file")
  end
  check("NVIM_LOG_FILE", log)
  for _, what in ipairs({ "data", "state", "cache", "config", "run", "log" }) do
    local p = vim.fn.stdpath(what)
    if type(p) ~= "string" or p:sub(1, 1) ~= "/" or not inside(resolve(p), rroot) then
      refuse(who, 'stdpath("' .. what .. '")=' .. tostring(p) .. " is outside OBELUS_TEST_ROOT=" .. root)
    end
  end
  return true
end
