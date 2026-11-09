-- UI snapshot harness driver (the PARENT process). Invoked by tests/ui/run.sh
-- (`make ui-snapshots`), which provides the hermetic environment.
--
-- For every scenario in tests/ui/scenarios.lua and every size in SIZES it spawns a
-- fresh child `nvim --embed -n -i NONE -u NONE` with an rgb linegrid UI attached,
-- runs the scenario there (synthetic fixtures + the fake transport only), captures
-- the composed screen + windows + extmarks + highlights (tests/ui/child.lua) and
-- compares the serialization byte-for-byte with tests/ui/baselines/<name>@<WxH>.snap.
--
--   OBELUS_UI_UPDATE=1   rewrite baselines instead of comparing
--   OBELUS_UI_ONLY=pat   run only scenarios whose name contains `pat` (plain find)
--   OBELUS_UI_OUT=dir    also write every produced snapshot to `dir` (used by the
--                        determinism check to diff whole runs)
local src = debug.getinfo(1, "S").source:sub(2)
local uidir = vim.fn.fnamemodify(src, ":p:h")
local repo = vim.fn.fnamemodify(uidir, ":h:h")
package.path = uidir .. "/?.lua;" .. package.path

local rpc = require("rpc")
local scenarios = require("scenarios")

local SIZES = { { 80, 24 }, { 160, 45 } }
local BASE = uidir .. "/baselines"
local update = vim.env.OBELUS_UI_UPDATE == "1"
local only = vim.env.OBELUS_UI_ONLY -- comma-separated substrings
local delay_ms = tonumber(vim.env.OBELUS_UI_DELAY_MS or "") or 0

-- hidden (self-test) scenarios run only when named exactly; others match any
-- OBELUS_UI_ONLY substring (or all, when unset)
local function selected(sc)
  if not only or only == "" then
    return not sc.hidden
  end
  for pat in only:gmatch("[^,]+") do
    if (sc.hidden and sc.name == pat) or (not sc.hidden and sc.name:find(pat, 1, true)) then
      return true
    end
  end
  return false
end
local outdir = vim.env.OBELUS_UI_OUT
local tmp = assert(vim.env.OBELUS_UI_TMP, "run via tests/ui/run.sh (OBELUS_UI_TMP unset)")

local function hex(n)
  return string.format("#%06x", n)
end

-- one attr-table entry -> a stable signature: resolved rgb attributes + the
-- highlight-group chain that produced them (ext_hlstate). Attr IDS never appear in
-- a snapshot — they depend on allocation order, not on what is drawn.
local RGB_ORDER = { "foreground", "background", "special" }
local RGB_SHORT = { foreground = "fg", background = "bg", special = "sp" }
local function attr_sig(a, defaults)
  local rgb = a and a.rgb or {}
  local parts = {}
  for _, k in ipairs(RGB_ORDER) do
    if rgb[k] then
      parts[#parts + 1] = RGB_SHORT[k] .. "=" .. hex(rgb[k])
    end
  end
  local flags = {}
  for k, v in pairs(rgb) do
    if not RGB_SHORT[k] then
      flags[#flags + 1] = (v == true) and k or (k .. "=" .. tostring(v))
    end
  end
  table.sort(flags)
  vim.list_extend(parts, flags)
  local chain = {}
  for _, i in ipairs(a and a.info or {}) do
    local n = i.kind == "ui" and i.ui_name or i.hi_name
    if n and n ~= "" then
      chain[#chain + 1] = n
    end
  end
  local s = #parts > 0 and table.concat(parts, " ") or "default"
  if #chain > 0 then
    s = s .. "  [" .. table.concat(chain, "+") .. "]"
  end
  return s
end

-- one symbol per screen cell; legend letters are assigned in row-major order of
-- first appearance so the file is stable and diffs stay local
local SYMBOLS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_{}~"

local function serialize(name, w, h, cap, attrs, describe)
  local out = {}
  local function push(s)
    out[#out + 1] = s
  end
  push(string.format("# obelus ui snapshot: %s @ %dx%d", name, w, h))
  push("## screen")
  for r = 1, cap.rows do
    push("|" .. cap.text[r] .. "|")
  end
  push("## attrs")
  local sym_of, legend = {}, {}
  for r = 1, cap.rows do
    local line = {}
    for c = 1, cap.cols do
      local sig = attr_sig(attrs[cap.attrs[r][c]])
      local s = sym_of[sig]
      if not s then
        local n = #legend + 1
        assert(n <= #SYMBOLS, "more distinct cell attributes than legend symbols")
        s = SYMBOLS:sub(n, n)
        sym_of[sig] = s
        legend[n] = s .. " " .. sig
      end
      line[#line + 1] = s
    end
    push("|" .. table.concat(line) .. "|")
  end
  push("## legend")
  vim.list_extend(out, legend)
  vim.list_extend(out, cap.body)
  push("## highlights")
  vim.list_extend(out, describe)
  return table.concat(out, "\n") .. "\n"
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

-- first differing line, for a readable failure
local function first_diff(a, b)
  local al, bl = vim.split(a, "\n", { plain = true }), vim.split(b, "\n", { plain = true })
  for i = 1, math.max(#al, #bl) do
    if al[i] ~= bl[i] then
      return i, al[i] or "<eof>", bl[i] or "<eof>"
    end
  end
end

local function is_fault(msg)
  return type(msg) == "string" and msg:find("rpc-fault:", 1, true) ~= nil
end

local function run_one(sc, w, h)
  local root = tmp .. "/proj"
  if vim.fn.isdirectory(root) == 1 then
    vim.fn.delete(root, "rf") -- exact path, recreated per child
  end
  vim.fn.mkdir(root, "p")
  local sok, child = pcall(rpc.spawn, {
    cmd = { vim.v.progpath, "--embed", "-n", "-i", "NONE", "-u", "NONE", "--noplugin" },
    cwd = root,
  })
  if not sok then
    return false, child
  end
  local ok, res = pcall(function()
    child:request("nvim_ui_attach", { w, h, { ext_linegrid = true, rgb = true, ext_hlstate = true } })
    child:lua(
      "_G.__ui = dofile(...); _G.__ui.boot(select(2, ...))",
      uidir .. "/child.lua",
      { repo = repo, root = root, tmp = tmp }
    )
    child:lua("return require('scenarios').run(...)", sc.name)
    if delay_ms > 0 then
      -- self-test knob: a real wall-clock stall between arranging and capturing,
      -- standing in for a loaded host. Snapshots must not change (virtual clock).
      vim.wait(delay_ms)
    end
    -- one no-op key through the input queue, then a synchronous round-trip: the
    -- child's state loop runs once, so a pending `startinsert` (open_thread, the
    -- composers) takes effect exactly as it would after a real keypress
    child:request("nvim_input", { "<Ignore>" })
    child:lua("return _G.__ui.settle()")
    if sc.kind == "registration" then
      local lines = child:lua("return _G.__ui.registration()")
      return string.format("# obelus ui snapshot: %s @ %dx%d\n", sc.name, w, h) .. table.concat(lines, "\n") .. "\n"
    end
    local cap = child:lua("return _G.__ui.capture()")
    -- the default cell colours (attr 0) come from Normal; floats default to NormalFloat
    for _, g in ipairs({ "Normal", "NormalFloat" }) do
      if not vim.tbl_contains(cap.groups, g) then
        cap.groups[#cap.groups + 1] = g
      end
    end
    table.sort(cap.groups)
    local describe = child:lua(
      "local out = {} for _, g in ipairs(...) do out[#out + 1] = _G.__ui.describe_hl(g) end return out",
      cap.groups
    )
    return serialize(sc.name, w, h, cap, child.attrs, describe)
  end)
  -- always reap the child (quit -> SIGTERM -> SIGKILL, awaited); a reap failure
  -- outranks whatever the scenario returned
  local cok, cerr = pcall(child.close, child)
  if not cok then
    return false, cerr
  end
  return ok, res
end

-- Our wrapper (run.sh) is our parent. If it is SIGKILLed it cannot run its trap,
-- so we notice the reparenting, stop starting scenarios, and remove the run's
-- private dir ourselves (the exact path run.sh created, passed as OBELUS_UI_DIR).
local wrapper_ppid = vim.uv.os_getppid()
local function orphaned()
  return vim.uv.os_getppid() ~= wrapper_ppid
end

local t0 = vim.uv.hrtime()
vim.fn.mkdir(BASE, "p")
-- failed = baseline MISMATCHES (a rendering differs); errors = the harness could
-- not produce/compare a rendering (scenario error, transport fault, no baseline,
-- version mismatch). Reported distinctly: tests/ui/mutations.sh counts only the
-- former as a caught mutation.
local failed, errors, passed, written = {}, {}, 0, 0
local function main()
  -- baselines are Neovim-version specific (the grid, treesitter parsers and the
  -- default colorscheme all ship with nvim): refuse to compare across versions
  -- instead of reporting a wall of unrelated diffs
  local version = vim.split(vim.fn.execute("version"), "\n", { trimempty = true })[1] .. "\n"
  local vpath = BASE .. "/NVIM_VERSION"
  if update and not only then
    write(vpath, version)
  elseif read(vpath) ~= version then
    errors[#errors + 1] = string.format(
      "baselines were recorded with %s but this is %s (re-record with OBELUS_UI_UPDATE=1 after reviewing)",
      vim.trim(read(vpath) or "<none>"),
      vim.trim(version)
    )
    return
  end
  for _, sc in ipairs(scenarios.list) do
    if orphaned() then
      errors[#errors + 1] = "wrapper (run.sh) died: stopping"
      return
    end
    if selected(sc) then
      for _, size in ipairs(sc.sizes or SIZES) do
        local w, h = size[1], size[2]
        local key = string.format("%s@%dx%d", sc.name, w, h)
        local path = BASE .. "/" .. key .. ".snap"
        local ok, got = run_one(sc, w, h)
        if not ok then
          errors[#errors + 1] = key .. ": " .. tostring(got)
          io.write("E")
          if is_fault(got) then
            errors[#errors + 1] = "transport fault: stopping the suite"
            return
          end
        else
          if outdir then
            write(outdir .. "/" .. key .. ".snap", got)
          end
          if update then
            if read(path) ~= got then
              write(path, got)
              written = written + 1
            end
            passed = passed + 1
            io.write(".")
          else
            local want = read(path)
            if want == got then
              passed = passed + 1
              io.write(".")
            elseif not want then
              errors[#errors + 1] = key .. ": no baseline (run with OBELUS_UI_UPDATE=1)"
              io.write("E")
            else
              local ln, a, b = first_diff(want, got)
              failed[#failed + 1] = string.format(
                "%s: differs from baseline at line %d\n      baseline: %s\n      current:  %s",
                key,
                ln,
                a,
                b
              )
              -- keep the rendering for review: diff baselines/<key>.snap actual/<key>.snap
              vim.fn.mkdir(uidir .. "/actual", "p")
              write(uidir .. "/actual/" .. key .. ".snap", got)
              io.write("F")
            end
          end
        end
        io.flush()
      end
    end
  end
end
local mok, merr = xpcall(main, debug.traceback)
if not mok then
  errors[#errors + 1] = "harness error: " .. tostring(merr)
end
io.write("\n")
for _, f in ipairs(failed) do
  io.write("FAIL " .. f .. "\n")
end
for _, e in ipairs(errors) do
  io.write("ERROR " .. e .. "\n")
end
io.write(
  string.format(
    "obelus ui snapshots: %d passed, %d failed, %d errors%s (%.1fs)\n",
    passed,
    #failed,
    #errors,
    update and string.format(", %d baseline(s) rewritten", written) or "",
    (vim.uv.hrtime() - t0) / 1e9
  )
)
if orphaned() and vim.env.OBELUS_UI_DIR and vim.env.OBELUS_UI_DIR ~= "" then
  vim.fn.delete(vim.env.OBELUS_UI_DIR, "rf") -- exact path; every child is already reaped
end
vim.cmd((#failed == 0 and #errors == 0) and "qall!" or "cquit 1")
