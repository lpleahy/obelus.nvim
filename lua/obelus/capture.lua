local config = require("obelus.config")
local store = require("obelus.store")
local render = require("obelus.render")

local M = {}

local function bufpath(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":p") or nil
end

local function get_context(bufnr, sl, el)
  local cfg = config.options.context
  local total = vim.api.nvim_buf_line_count(bufnr)
  local before, after = {}, {}
  if cfg.before > 0 then
    before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, sl - 1 - cfg.before), sl - 1, false)
  end
  if cfg.after > 0 then
    after = vim.api.nvim_buf_get_lines(bufnr, el, math.min(total, el + cfg.after), false)
  end
  return { before = before, after = after }
end

local function get_selected_text(bufnr, kind, sl, sc, el, ec)
  if kind == "line" then
    return vim.api.nvim_buf_get_lines(bufnr, sl - 1, el, false)
  end
  local last = vim.api.nvim_buf_get_lines(bufnr, el - 1, el, false)[1] or ""
  local ok, text = pcall(vim.api.nvim_buf_get_text, bufnr, sl - 1, sc - 1, el - 1, math.min(ec, #last), {})
  return ok and text or vim.api.nvim_buf_get_lines(bufnr, sl - 1, el, false)
end

---Floating multiline scratch buffer for entering/editing a comment.
---Calls `cb(text|nil)` — nil means cancelled or empty.
local function prompt(opts, cb)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  if opts.default and opts.default ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.default, "\n"))
  end

  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local height = math.max(3, math.min(12, math.floor(vim.o.lines * 0.3)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = opts.title or " review comment ",
    title_pos = "center",
    footer = " <CR>/<C-s> submit · q/<Esc> cancel ",
    footer_pos = "right",
    zindex = config.z.OVERLAY, -- above the chat stack (incl. its input)
  })
  vim.wo[win].wrap = true
  vim.cmd("startinsert")

  local done = false
  local function finish(submit)
    if done then
      return
    end
    done = true
    local text
    if submit then
      text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      if text == "" then
        text = nil
      end
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    cb(text)
  end

  local kopts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function()
    finish(true)
  end, kopts)
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    finish(true)
  end, kopts)
  vim.keymap.set("n", "q", function()
    finish(false)
  end, kopts)
  vim.keymap.set("n", "<Esc>", function()
    finish(false)
  end, kopts)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      finish(false)
    end,
  })
end

M.prompt = prompt

function M._capture(bufnr, file, kind, sl, sc, el, ec)
  local selected = get_selected_text(bufnr, kind, sl, sc, el, ec)
  local context = get_context(bufnr, sl, el)
  -- Same inline composer as replies — adding a comment opens a new thread box. It's created on
  -- submit OR on cancel-with-text: escape/quit still SAVES the comment (as an unsent "· draft"),
  -- so you never lose it; delete it (<prefix>d) if you didn't mean to.
  local function create(text)
    if not (text and text ~= "") then
      return
    end
    local c = store.add({
      file = file,
      range = { sl = sl, sc = sc, el = el, ec = ec },
      kind = kind,
      selected_text = selected,
      context = context,
      comment = text,
    })
    render.place(bufnr, c)
    render.render_all() -- show it everywhere now (bands + the sidebar list)
  end
  render.compose({
    title = "review: " .. vim.fn.fnamemodify(file, ":t"),
    row = (el - sl) + 1,
    on_submit = create,
    on_cancel = create,
  })
end

function M.comment_normal()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = bufpath(bufnr)
  if not file then
    return vim.notify("obelus: buffer has no file", vim.log.levels.WARN)
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  M._capture(bufnr, file, "line", line, nil, line, nil)
end

function M.comment_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = bufpath(bufnr)
  if not file then
    return vim.notify("obelus: buffer has no file", vim.log.levels.WARN)
  end
  local mode = vim.fn.visualmode()
  local sp, ep = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local sl, sc, el, ec = sp[2], sp[3], ep[2], ep[3]
  if sl > el or (sl == el and sc > ec) then
    sl, el, sc, ec = el, sl, ec, sc
  end
  if mode == "V" then
    M._capture(bufnr, file, "line", sl, nil, el, nil)
  else
    M._capture(bufnr, file, "char", sl, sc, el, ec)
  end
end

function M.edit_comment(c)
  render.compose({
    title = "edit comment",
    default = c.comment,
    on_submit = function(text)
      store.update(c.id, { comment = text })
      render.render_all()
      vim.notify("obelus: comment updated", vim.log.levels.INFO)
    end,
  })
end

return M
