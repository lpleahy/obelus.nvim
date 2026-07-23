-- OS-level sandbox wrapping for cli-transport spawns — the ENFORCEMENT half of
-- obelus's permission model (the semantic half is the CLI's own mode flags,
-- e.g. claude's --permission-mode / agy's --mode, handled in transport/cli.lua).
-- The spawned agent process gets:
--   writes  — confined to the project root (project-edit only) + the CLI's own
--             state dirs + temp dirs; everything else is denied at the OS level
--   reads   — unrestricted EXCEPT a secrets deny-list (~/.ssh etc.)
-- Wrappers: sandbox-exec on macOS (ships with the OS), bwrap (bubblewrap) on
-- Linux. No wrapper available => warn once and run with CLI-native permissions
-- only — the semantic layer still applies, the guarantee doesn't.
local M = {}

local uv = vim.uv or vim.loop

-- Default read deny-list (transport.cli.permissions.deny_read = nil): the
-- classic PLAINTEXT secret stores. Deliberately NOT ~/Library/Keychains —
-- keychain files are encrypted at rest (a raw read leaks nothing usable) and
-- denying them breaks CLIs that keep their own oauth in the login keychain
-- (claude does; verified: the deny yields "Not logged in"). Resolved here, not
-- in config.defaults: a LIST default can't be emptied through tbl_deep_extend
-- — `deny_read = {}` must mean "deny nothing".
M.DEFAULT_DENY_READ = { "~/.ssh", "~/.gnupg", "~/.aws", "~/.netrc", "~/.config/gh" }

-- Expand ~ and resolve symlinks (sandbox-exec matches on REAL paths — /tmp
-- must become /private/tmp); a path that doesn't exist resolves to itself.
local function real(p)
  local e = vim.fn.expand(p)
  return uv.fs_realpath(e) or e
end

-- { path = <realpath>, dir = <bool> } for every entry that EXISTS (binding or
-- allowing a non-existent path is at best a no-op, at worst a bwrap error).
-- A literal "{root}" in an entry expands to the project root — for per-project
-- CLI dirs like crush's ./.crush that must stay writable even in read-only.
local function existing(list, root)
  local out = {}
  for _, p in ipairs(list or {}) do
    if root then
      p = p:gsub("{root}", root)
    end
    local r = real(p)
    local st = uv.fs_stat(r)
    if st then
      out[#out + 1] = { path = r, dir = st.type == "directory" }
    end
  end
  return out
end

-- Temp locations every CLI needs writable (session log capture, node/go temp
-- files): the platform temp roots + $TMPDIR (macOS: per-user /var/folders/…).
local function temp_dirs()
  local dirs = { "/tmp", "/var/tmp" }
  if vim.env.TMPDIR and vim.env.TMPDIR ~= "" then
    dirs[#dirs + 1] = vim.env.TMPDIR
  end
  -- macOS: cover the whole per-user temp tree, not just this shell's $TMPDIR
  dirs[#dirs + 1] = "/private/var/folders"
  return dirs
end

-- Writable set for a spawn: temp + CLI state (+ extra write dirs) + the
-- project root when mode allows edits.
local function writable(ctx)
  local list = temp_dirs()
  vim.list_extend(list, ctx.state or {})
  vim.list_extend(list, ctx.write or {})
  if ctx.mode ~= "read-only" then
    list[#list + 1] = ctx.root
  end
  return list
end

local function deny_read(ctx)
  return ctx.deny_read or M.DEFAULT_DENY_READ
end

-- ── macOS: sandbox-exec with an inline SBPL profile ─────────────────────────

local function sbpl_str(p)
  return '"' .. p:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- The generated profile (exposed for specs). `(allow default)` keeps process
-- exec/network/etc. intact — this is FILE permission enforcement, not a full
-- jail; later rules override earlier ones in SBPL, so the write allows punch
-- holes in the global write deny, and the read denies are terminal.
function M._sbpl(ctx)
  local lines = {
    "(version 1)",
    "(allow default)",
    "(deny file-write*)",
    '(allow file-write* (subpath "/dev"))',
  }
  for _, e in ipairs(existing(writable(ctx), ctx.root)) do
    lines[#lines + 1] = ("(allow file-write* (%s %s))"):format(e.dir and "subpath" or "literal", sbpl_str(e.path))
  end
  for _, e in ipairs(existing(deny_read(ctx), ctx.root)) do
    lines[#lines + 1] = ("(deny file-read* (%s %s))"):format(e.dir and "subpath" or "literal", sbpl_str(e.path))
  end
  return table.concat(lines, "\n")
end

local function wrap_macos(cmd, ctx)
  local out = { "sandbox-exec", "-p", M._sbpl(ctx) }
  vim.list_extend(out, cmd)
  return out
end

-- ── Linux: bwrap (bubblewrap) ───────────────────────────────────────────────

-- Read-only root, /dev + /proc virtualized, writable binds punched through for
-- the allowed set, and secrets MASKED (--tmpfs for dirs, /dev/null bind for
-- files) — masks come last so they win inside any writable tree. Network stays
-- shared (the agent needs its API). Exposed for specs.
function M._bwrap(cmd, ctx)
  local args = { "bwrap", "--die-with-parent", "--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc", "/proc" }
  for _, e in ipairs(existing(writable(ctx), ctx.root)) do
    vim.list_extend(args, { "--bind", e.path, e.path })
  end
  for _, e in ipairs(existing(deny_read(ctx), ctx.root)) do
    if e.dir then
      vim.list_extend(args, { "--tmpfs", e.path })
    else
      vim.list_extend(args, { "--ro-bind", "/dev/null", e.path })
    end
  end
  args[#args + 1] = "--"
  vim.list_extend(args, cmd)
  return args
end

-- ── entry point ─────────────────────────────────────────────────────────────

---Wrap `cmd` in the platform sandbox. ctx:
---  root      — project root (writable only when mode ~= "read-only")
---  mode      — "read-only" | "project-edit" (unrestricted never reaches here)
---  wrapper   — nil = auto by platform; "sandbox-exec" | "bwrap";
---              function(cmd, ctx) -> cmd for a custom wrapper; false = off
---  state     — CLI state dirs, writable in EVERY mode (the tool must be able
---              to save its own conversations/caches even read-only)
---  write     — extra always-writable dirs
---  deny_read — nil = DEFAULT_DENY_READ; {} = deny nothing
---@return string[] cmd (wrapped, or unchanged when no wrapper is available)
function M.wrap(cmd, ctx)
  local wrapper = ctx.wrapper
  if wrapper == false then
    return cmd
  end
  if type(wrapper) == "function" then
    return wrapper(cmd, ctx) or cmd
  end
  if wrapper == nil then
    local sys = uv.os_uname().sysname
    wrapper = (sys == "Darwin" and "sandbox-exec") or (sys == "Linux" and "bwrap") or nil
  end
  if not wrapper or vim.fn.executable(wrapper) ~= 1 then
    vim.notify_once(
      "obelus: sandbox wrapper unavailable ("
        .. tostring(wrapper or "unsupported platform")
        .. ") — file isolation is NOT enforced; running with CLI-native permissions only"
        .. (wrapper == "bwrap" and " (install bubblewrap)" or ""),
      vim.log.levels.WARN
    )
    return cmd
  end
  if wrapper == "sandbox-exec" then
    return wrap_macos(cmd, ctx)
  end
  return M._bwrap(cmd, ctx)
end

return M
