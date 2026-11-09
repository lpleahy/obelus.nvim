-- Minimal msgpack-RPC client for driving a child `nvim --embed` from the parent
-- harness process, with a real (rgb, linegrid) UI attached so the child composes
-- its floating windows into the screen grid exactly like a terminal UI sees it.
--
-- Why not vim.fn.jobstart({ rpc = true })? A UI-attached child sends "redraw"
-- notifications, which a parent *Nvim* channel treats as a call to an unknown API
-- method and closes the channel. Here the parent speaks msgpack-RPC itself over
-- plain pipes: it answers nothing, records the `hl_attr_define` table (attr id ->
-- resolved rgb attributes + the highlight-group chain, via ext_hlstate) and ignores
-- every other UI event.
--
-- Every wait is condition-based (a response arrived / the child exited), never a
-- sleep; the only clock is a generous deadlock guard.
local uv = vim.uv or vim.loop

local M = {}

local GUARD_MS = 300000 -- deadlock guard only; a healthy call returns in milliseconds

---@param opts { cmd: string[], cwd: string, env: string[], cols: integer, rows: integer }
function M.spawn(opts)
  local self = {
    attrs = { [0] = { rgb = {}, info = {} } }, -- attr id -> { rgb = {...}, info = {...} }
    responses = {},
    next_id = 0,
    exited = false,
    stderr = {},
  }
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local args = {}
  for i = 2, #opts.cmd do
    args[#args + 1] = opts.cmd[i]
  end
  local handle, err = uv.spawn(opts.cmd[1], {
    args = args,
    cwd = opts.cwd,
    env = opts.env,
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    self.exited = true
    self.code, self.signal = code, signal
  end)
  assert(handle, "spawn failed: " .. tostring(err))
  self.handle, self.stdin = handle, stdin

  local unpack = vim.mpack.Unpacker()
  local function on_msg(msg)
    local kind = msg[1]
    if kind == 1 then -- response: [1, id, error, result]
      self.responses[msg[2]] = { err = msg[3], result = msg[4] }
    elseif kind == 2 and msg[2] == "redraw" then -- notification: [2, method, params]
      for _, batch in ipairs(msg[3]) do
        if batch[1] == "hl_attr_define" then
          for i = 2, #batch do
            local ev = batch[i] -- { id, rgb_attr, cterm_attr, info }
            self.attrs[ev[1]] = { rgb = ev[2], info = ev[4] }
          end
        end
      end
    end
  end
  stdout:read_start(function(rerr, chunk)
    assert(not rerr, rerr)
    if not chunk then
      return
    end
    local pos = 1
    while pos <= #chunk do
      local obj
      obj, pos = unpack(chunk, pos)
      if obj == nil then
        break -- partial message: the unpacker keeps its state for the next chunk
      end
      on_msg(obj)
    end
  end)
  stderr:read_start(function(_, chunk)
    if chunk then
      self.stderr[#self.stderr + 1] = chunk
    end
  end)
  self.pipes = { stdin, stdout, stderr }
  setmetatable(self, { __index = M })
  return self
end

function M:request(method, params)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.stdin:write(vim.mpack.encode({ 0, id, method, params }))
  local ok = vim.wait(GUARD_MS, function()
    return self.responses[id] ~= nil or self.exited
  end, 2)
  local r = self.responses[id]
  if not r then
    error(
      string.format(
        "rpc %s: no response (%s); child stderr: %s",
        method,
        ok and "child exited" or "deadlock guard",
        table.concat(self.stderr)
      )
    )
  end
  self.responses[id] = nil
  if r.err ~= nil and r.err ~= vim.NIL then
    local e = r.err
    error(string.format("rpc %s failed: %s", method, type(e) == "table" and tostring(e[2]) or vim.inspect(e)), 0)
  end
  return r.result
end

-- Run Lua in the child; `...` are passed as the chunk's varargs.
function M:lua(code, ...)
  return self:request("nvim_exec_lua", { code, { ... } })
end

function M:close()
  if not self.exited then
    pcall(function()
      self.stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qall!" } }))
    end)
    vim.wait(GUARD_MS, function()
      return self.exited
    end, 2)
  end
  for _, p in ipairs(self.pipes) do
    if not p:is_closing() then
      p:close()
    end
  end
  if not self.handle:is_closing() then
    self.handle:close()
  end
end

return M
