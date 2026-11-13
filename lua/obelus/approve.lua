-- A generic, keyboard-driven Approve/Deny float (exposed as obelus.api.approve).
-- Behaviour follows Luodda's approval prompt (lua/luodda/approve.lua):
--   * text never approves: the float opens UNFOCUSED and unfocusable, so stray
--     typing goes to whatever window you were in;
--   * approving takes a deliberate focus (:ObelusApprove or api.approve_focus()).
--     The prompt is then UNARMED: every key is ignored. Arming is a sequence of
--     event-loop steps, not a clock reading: after `arm_ms` a timer DRAINS all
--     queued input (getchar(0) until empty), then — on the next scheduled loop
--     turn — drains again and only then arms. Typeahead queued while unarmed,
--     even if the loop was blocked past `arm_ms`, is consumed by a drain before
--     the armed flag can be set, so it can never approve; once armed, only a
--     key that arrived after the last drain reaches the prompt, and only `a`
--     approves. A drain must SEE the queue empty: if more than `drain_cap`
--     keys are queued (or input keeps arriving), or a queued Esc/q/<C-c>/Enter
--     is found, the prompt is denied — it never arms with input left over;
--   * every other exit is Deny: Esc, q, <C-c>, Enter, any other key once armed,
--     leaving or closing the window, the UI detaching, the timeout, an error
--     while opening, or no UI at all (headless: denied at once, no float);
--   * on_result is called exactly once.
-- Prompts queue: one is shown at a time.
local M = {}

---@class obelus.ApproveOpts
---@field summary string one-line description of the action (plain text)
---@field details? string|string[] optional extra lines (plain text)
---@field on_result fun(approved: boolean) called exactly once
---@field timeout_ms? integer deny after this long (default 120000)
---@field on_open? fun(handle: obelus.ApproveHandle) called when THIS prompt's float opens (it may wait in the queue)
---@field focus_hint? string replaces ":ObelusApprove" in the float's focus line (plain one-line text: 1..32 cells, <= 128 bytes)

---@class obelus.ApproveHandle
---@field cancel fun() deny this prompt (queued or open); no-op once decided
---@field focus fun(): boolean focus THIS prompt (as :ObelusApprove does); false — and nothing happens — while it is queued, or once it is closed

M.arm_ms = 600 -- the unarmed (typeahead-discard) window after focusing
M.timeout_ms = 120000

local queue, active = {}, nil
local pump

local function armed(a)
  return a.armed == true
end

M.drain_cap = 10000 -- keys one drain may discard; more left over = deny

-- forward-declared: finish is defined below
local finish

-- Discard every key already queued (typeahead and pending input) while the
-- prompt is focused and unarmed. Returns true only once the queue was seen
-- EMPTY. A queued Esc / q / <C-c> / Enter is honoured as a dismissal (deny);
-- running out of the cap with input still queued denies too ("dismissed"):
-- the prompt never arms with old input possibly left over.
local function drain(a, current)
  if not current() then
    return false
  end
  for _ = 1, M.drain_cap do
    local ok, key = pcall(vim.fn.getchar, 0)
    if not current() then
      return false
    end
    if not ok or key == 27 or key == 113 or key == 3 or key == 13 or key == 10 then
      finish(false, a)
      return false
    end
    if key == 0 then
      return true
    end
  end
  finish(false, a) -- cap exhausted: dismissed
  return false
end

---Is there a UI that can show the prompt? Headless = no.
function M.available()
  return #vim.api.nvim_list_uis() > 0
end

finish = function(approve, a)
  a = a or active
  if not a or a.done then
    return
  end
  if approve then
    -- belt and braces: re-check every precondition at the moment of approval
    local cur_ok = a.win and vim.api.nvim_win_is_valid(a.win) and vim.api.nvim_get_current_win() == a.win
    if not (armed(a) and not a.dismissed and M.available() and cur_ok) then
      approve = false
    end
  end
  a.done = true
  if active == a then
    active = nil
  end
  if a.group then
    pcall(vim.api.nvim_del_augroup_by_id, a.group)
  end
  if a.win and vim.api.nvim_win_is_valid(a.win) then
    pcall(vim.api.nvim_win_close, a.win, true)
  end
  if a.buf and vim.api.nvim_buf_is_valid(a.buf) then
    pcall(vim.api.nvim_buf_delete, a.buf, { force = true })
  end
  pcall(a.on_result, approve == true)
  vim.schedule(pump)
end

-- plain text only: control characters (escape sequences, NULs) are dropped
local function clean(s)
  return (tostring(s or ""):gsub("[%z\1-\8\11-\31\127]", ""))
end

local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(clean(text), "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        out[#out + 1] = line
        line = word
      end
      while vim.fn.strdisplaywidth(line) > width do
        out[#out + 1] = vim.fn.strcharpart(line, 0, width)
        line = vim.fn.strcharpart(line, width)
      end
    end
    out[#out + 1] = line
  end
  return out
end

local function ensure_command()
  if vim.fn.exists(":ObelusApprove") ~= 2 then
    vim.api.nvim_create_user_command("ObelusApprove", function()
      M.focus()
    end, { desc = "obelus: focus the pending approval prompt (then wait, a approves)" })
  end
end

local function open(a)
  local config = require("obelus.config")
  local width = math.max(24, math.min(64, vim.o.columns - 6))
  local inner = width - 2
  local lines = wrap(a.summary ~= "" and a.summary or "Confirm action", inner)
  local details = a.details
  if type(details) == "table" then
    details = table.concat(details, "\n")
  end
  if details and details ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, wrap(details, inner))
  end
  -- a long text is cut (with "…") rather than failing to open, which would deny
  local room = vim.o.lines - 4 - 6
  if #lines > room and room >= 1 then
    lines = vim.list_slice(lines, 1, room)
    lines[room] = "…"
  end
  lines[#lines + 1] = ""
  a.deny_row = #lines + 1
  vim.list_extend(lines, {
    "  Deny     Enter · Esc · q",
    "  Approve  a",
    "",
    "Focus: :ObelusApprove, wait, then a approves",
    "Leaving or closing the prompt denies",
  })
  local hint_from = #lines - 1
  assert(#lines <= vim.o.lines - 4, "approval does not fit this UI")
  a.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[a.buf].bufhidden = "wipe"
  vim.bo[a.buf].filetype = "obelus_approve"
  vim.api.nvim_buf_set_lines(a.buf, 0, -1, false, lines)
  vim.bo[a.buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("obelus_approve")
  for row = hint_from, #lines do
    vim.api.nvim_buf_set_extmark(a.buf, ns, row - 1, 0, { line_hl_group = "ObelusThreadMeta" })
  end
  vim.api.nvim_buf_set_extmark(a.buf, ns, a.deny_row - 1, 2, { end_col = 6, hl_group = "ObelusThreadHeader" })
  vim.api.nvim_buf_set_extmark(a.buf, ns, a.deny_row, 2, { end_col = 9, hl_group = "ObelusThreadHeader" })
  a.win = vim.api.nvim_open_win(a.buf, false, {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    focusable = false, -- never reachable by <C-w>w or a stray mouse click
    border = "rounded",
    title = { { " ▎ " .. (a.title or "approve") .. " ", "ObelusInputHeader" } },
    title_pos = "left",
    zindex = config.z.OVERLAY,
  })
  vim.wo[a.win].cursorline = true
  vim.wo[a.win].wrap = false
  vim.wo[a.win].winhighlight =
    "Normal:ObelusInput,NormalFloat:ObelusInput,FloatBorder:ObelusInputBorder,FloatTitle:ObelusThreadHeader,CursorLine:ObelusThreadBg,EndOfBuffer:ObelusInput"
  vim.api.nvim_win_set_cursor(a.win, { a.deny_row, 0 }) -- Deny is the default

  local function map(key, fn)
    vim.keymap.set({ "n", "i", "v" }, key, fn, { buffer = a.buf, nowait = true, silent = true })
  end
  -- once armed, a key decides; before that (the typeahead window) it is ignored
  local function decide(yes)
    if active == a and armed(a) then
      finish(yes, a)
    end
  end
  for code = 32, 126 do
    local key = string.char(code)
    if key == "<" then
      key = "<LT>"
    elseif key == " " then
      key = "<Space>"
    end
    map(key, function()
      decide(false)
    end)
  end
  map("a", function()
    decide(true)
  end)
  for _, key in ipairs({ "<Up>", "<Down>", "<Left>", "<Right>", "<Tab>", "<BS>" }) do
    map(key, function()
      decide(false)
    end)
  end
  -- Enter (Deny's own key), q, Esc and <C-c> deny at once, armed or not
  -- (Luodda parity: a deliberate Enter while unarmed is a deny, not ignored)
  for _, key in ipairs({ "<CR>", "q", "<Esc>", "<C-c>" }) do
    map(key, function()
      finish(false, a)
    end)
  end
  a.group = vim.api.nvim_create_augroup("obelus_approve", { clear = true })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout", "BufHidden" }, {
    group = a.group,
    buffer = a.buf,
    callback = function()
      a.dismissed = true
      vim.schedule(function()
        finish(false, a)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = a.group,
    pattern = tostring(a.win),
    callback = function()
      a.dismissed = true
      vim.schedule(function()
        finish(false, a)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("UILeave", {
    group = a.group,
    callback = function()
      if not M.available() then
        a.dismissed = true
        vim.schedule(function()
          finish(false, a)
        end)
      end
    end,
  })
  vim.defer_fn(function()
    finish(false, a)
  end, a.timeout_ms)
end

pump = function()
  if active or #queue == 0 then
    return
  end
  local a = table.remove(queue, 1)
  active = a
  if not M.available() then
    return finish(false, a) -- headless: deny now, never fall through
  end
  ensure_command()
  local ok = pcall(open, a)
  if not ok then
    return finish(false, a)
  end
  if a.on_open then
    pcall(a.on_open, a.handle) -- external: it may focus, cancel or queue more
  end
end

---Focus the pending prompt, UNARMED. Keys are ignored until it arms: after
---`arm_ms`, queued input is drained, and on the following loop turn drained
---again before `a` can approve (see the header).
function M.focus()
  return M._focus(active)
end

-- focus prompt `a` — only while it is THE open prompt; a queued, closed or
-- stale prompt is left alone (false)
function M._focus(a)
  if not a or a ~= active or a.done or not a.win or not vim.api.nvim_win_is_valid(a.win) or vim.fn.mode() ~= "n" then
    return false
  end
  a.armed = false
  a.focus_seq = (a.focus_seq or 0) + 1
  local seq = a.focus_seq
  if vim.api.nvim_get_current_win() ~= a.win then
    vim.api.nvim_set_current_win(a.win)
  end
  local function current()
    return active == a
      and not a.done
      and not a.dismissed
      and a.focus_seq == seq
      and M.available()
      and vim.api.nvim_win_is_valid(a.win)
      and vim.api.nvim_get_current_win() == a.win
  end
  if not drain(a, current) then
    return true
  end
  vim.defer_fn(function()
    if not drain(a, current) then
      return
    end
    -- a loop boundary after the drain; the final drain must find the queue empty
    vim.schedule(function()
      if drain(a, current) then
        a.armed = true
      end
    end)
  end, M.arm_ms)
  return true
end

-- Is `cp` a code point a focus hint may not contain? C0 controls, DEL, C1
-- controls, line/paragraph separators and every Unicode format control (Cf):
-- bidi embeddings, overrides, isolates and marks, zero-width characters,
-- the BOM, interlinear annotation, invisible operators and tag characters.
local function forbidden(cp)
  return cp < 0x20
    or (cp >= 0x7F and cp <= 0x9F)
    or cp == 0xAD
    or (cp >= 0x0600 and cp <= 0x0605)
    or cp == 0x061C
    or cp == 0x06DD
    or cp == 0x070F
    or cp == 0x0890
    or cp == 0x0891
    or cp == 0x08E2
    or cp == 0x180E
    or (cp >= 0x200B and cp <= 0x200F)
    or (cp >= 0x2028 and cp <= 0x202E)
    or (cp >= 0x2060 and cp <= 0x2064)
    or (cp >= 0x2066 and cp <= 0x206F)
    or cp == 0xFEFF
    or (cp >= 0xFFF9 and cp <= 0xFFFB)
    or cp == 0x110BD
    or cp == 0x110CD
    or (cp >= 0x13430 and cp <= 0x1343F)
    or (cp >= 0x1BCA0 and cp <= 0x1BCA3)
    or (cp >= 0x1D173 and cp <= 0x1D17A)
    or cp == 0xE0001
    or (cp >= 0xE0020 and cp <= 0xE007F)
end

-- shared with obelus.api, which neutralizes a backend's display-only text with it
M._forbidden = forbidden

---Is `hint` an acceptable focus_hint: valid UTF-8, 1..128 bytes, 1..32
---display cells, not blank, and free of every forbidden code point above?
function M._hint_ok(hint)
  if type(hint) ~= "string" or #hint == 0 or #hint > 128 then
    return false
  end
  local cps = vim.fn.str2list(hint, true)
  if vim.fn.list2str(cps, true) ~= hint then
    return false -- not valid UTF-8
  end
  for _, cp in ipairs(cps) do
    if forbidden(cp) then
      return false
    end
  end
  return vim.trim(hint) ~= "" and vim.fn.strdisplaywidth(hint) <= 32
end

---Queue an approval prompt. Returns a handle whose `cancel()` denies it.
---@param opts obelus.ApproveOpts
---@return { cancel: fun() }
function M.approve(opts)
  if type(opts) ~= "table" or type(opts.on_result) ~= "function" then
    error("obelus.api.approve: opts.on_result must be a function", 2)
  end
  local hint = opts.focus_hint
  if hint ~= nil and not M._hint_ok(hint) then
    error("obelus.api.approve: focus_hint must be plain single-line text of 1..32 cells and at most 128 bytes", 2)
  end
  local a = {
    summary = clean(opts.summary or ""),
    details = opts.details,
    title = opts.title and clean(opts.title) or nil,
    on_result = opts.on_result,
    timeout_ms = tonumber(opts.timeout_ms) or M.timeout_ms,
    on_open = type(opts.on_open) == "function" and opts.on_open or nil,
    focus_hint = hint,
    armed = false,
  }
  a.handle = {
    cancel = function()
      for i = #queue, 1, -1 do
        if queue[i] == a then
          table.remove(queue, i)
          a.done = true
          pcall(a.on_result, false)
        end
      end
      finish(false, a)
    end,
    focus = function()
      return M._focus(a)
    end,
  }
  if hint then
    -- swap the caller's instruction into the focus line once the float is
    -- open (kept out of open(): the prompt's rendering is otherwise unchanged)
    local user_on_open = a.on_open
    a.on_open = function(handle)
      if a.buf and vim.api.nvim_buf_is_valid(a.buf) then
        local lines = vim.api.nvim_buf_get_lines(a.buf, 0, -1, false)
        for i, line in ipairs(lines) do
          if line == "Focus: :ObelusApprove, wait, then a approves" then
            vim.bo[a.buf].modifiable = true
            vim.api.nvim_buf_set_lines(a.buf, i - 1, i, false, { "Focus: " .. hint .. ", wait, then a approves" })
            vim.bo[a.buf].modifiable = false
          end
        end
      end
      if user_on_open then
        user_on_open(handle)
      end
    end
  end
  queue[#queue + 1] = a
  pump()
  return a.handle
end

-- test/teardown hook: deny everything pending
function M._reset()
  local q = queue
  queue = {}
  for _, a in ipairs(q) do
    a.done = true
    pcall(a.on_result, false)
  end
  if active then
    finish(false, active)
  end
end

function M._active()
  return active
end

return M
