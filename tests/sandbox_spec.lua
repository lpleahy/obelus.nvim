-- sandbox: the OS-level enforcement wrapper — SBPL profile / bwrap argv
-- construction and the wrap() dispatch. (Real sandbox-exec ENFORCEMENT is
-- exercised out-of-band — these specs pin the generated shapes.)
T.describe("sandbox")

local sb = require("obelus.sandbox")
local uv = vim.uv or vim.loop

local function mkdirp()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function ctx(over)
  return vim.tbl_deep_extend("force", { root = mkdirp(), mode = "project-edit", state = {}, write = {} }, over or {})
end

-- find the index where `seq` starts inside `list` (plain equality), or nil
local function find_seq(list, seq)
  for i = 1, #list - #seq + 1 do
    local hit = true
    for j = 1, #seq do
      if list[i + j - 1] ~= seq[j] then
        hit = false
        break
      end
    end
    if hit then
      return i
    end
  end
  return nil
end

T.it("sbpl (project-edit): global write deny, project-root allow, temp allows", function()
  local c = ctx()
  local prof = sb._sbpl(c)
  T.contains(prof, "(deny file-write*)")
  T.contains(prof, '(allow file-write* (subpath "' .. uv.fs_realpath(c.root) .. '"))', "project root writable")
  T.contains(prof, "(allow default)")
end)

T.it("sbpl (read-only): the project root is NOT in the write allows", function()
  local c = ctx({ mode = "read-only" })
  local prof = sb._sbpl(c)
  T.ok(not prof:find(uv.fs_realpath(c.root), 1, true), "read-only never allows project writes")
end)

T.it("sbpl: state dirs stay writable in read-only mode; custom deny_read lands as a read deny", function()
  local state, secret = mkdirp(), mkdirp()
  local c = ctx({ mode = "read-only", state = { state }, deny_read = { secret } })
  local prof = sb._sbpl(c)
  T.contains(prof, '(allow file-write* (subpath "' .. uv.fs_realpath(state) .. '"))', "state writable even read-only")
  T.contains(prof, '(deny file-read* (subpath "' .. uv.fs_realpath(secret) .. '"))', "secret read denied")
end)

T.it("sbpl: deny_read = {} denies nothing; nonexistent entries are dropped", function()
  local c = ctx({ deny_read = {}, state = { "/no/such/dir/obelus-xyz" } })
  local prof = sb._sbpl(c)
  T.ok(not prof:find("file-read*", 1, true), "no read denies with an empty list")
  T.ok(not prof:find("obelus-xyz", 1, true), "nonexistent paths never reach the profile")
end)

T.it("bwrap (project-edit): ro-bind /, project bound writable, secrets masked, -- separator", function()
  local secret = mkdirp()
  local c = ctx({ deny_read = { secret } })
  local args = sb._bwrap({ "mycli", "-p", "hi" }, c)
  T.eq(args[1], "bwrap")
  T.ok(find_seq(args, { "--ro-bind", "/", "/" }), "root filesystem read-only")
  local root = uv.fs_realpath(c.root)
  T.ok(find_seq(args, { "--bind", root, root }), "project bound writable")
  T.ok(find_seq(args, { "--tmpfs", uv.fs_realpath(secret) }), "secret dir masked with tmpfs")
  local sep = find_seq(args, { "--", "mycli", "-p", "hi" })
  T.ok(sep, "the -- separator precedes the command")
  T.eq(sep + 3, #args, "command comes last, after the -- separator")
end)

T.it("bwrap (read-only): the project is NOT bound writable", function()
  local c = ctx({ mode = "read-only" })
  local args = sb._bwrap({ "mycli" }, c)
  local root = uv.fs_realpath(c.root)
  T.is_nil(find_seq(args, { "--bind", root, root }), "read-only never binds the project writable")
end)

T.it("wrap: wrapper = false → unchanged; wrapper = function → applied with the ctx", function()
  local c = ctx({ wrapper = false })
  local cmd = { "mycli", "-p", "hi" }
  T.eq(sb.wrap(cmd, c), cmd, "false disables wrapping")
  local seen
  local c2 = ctx({
    wrapper = function(inner, wctx)
      seen = wctx
      return vim.list_extend({ "WRAP" }, inner)
    end,
  })
  local out = sb.wrap(cmd, c2)
  T.eq(out[1], "WRAP")
  T.eq(out[2], "mycli")
  T.eq(seen.mode, "project-edit", "the ctx reaches a custom wrapper")
end)

T.it("wrap: an unavailable wrapper binary warns and returns the cmd unchanged", function()
  local cmd = { "mycli" }
  T.eq(sb.wrap(cmd, ctx({ wrapper = "obelus-no-such-wrapper" })), cmd)
end)

T.it("{root} placeholder in state entries expands to the project root", function()
  local root = mkdirp()
  vim.fn.mkdir(root .. "/.crush", "p")
  local c = ctx({ root = root, mode = "read-only", state = { "{root}/.crush" } })
  local prof = sb._sbpl(c)
  T.contains(prof, '(allow file-write* (subpath "' .. uv.fs_realpath(root .. "/.crush") .. '"))')
  T.ok(
    not prof:find('(allow file-write* (subpath "' .. uv.fs_realpath(root) .. '"))', 1, true),
    "root itself stays read-only"
  )
end)
