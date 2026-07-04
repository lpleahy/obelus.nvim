local M = {}

---@class obelus.Config
---@field render obelus.Config.Render
M.defaults = {
  -- Surrounding lines captured with each comment (no git/diff dependency).
  context = { before = 3, after = 3 },

  -- Engagement modality (one or the other — toggle with :ObelusMode):
  --   "inline"  — chat in the file via bands; the sidebar is a navigator
  --   "sidebar" — chat lives in the threads sidebar
  mode = "inline",

  persist = {
    backend = "data", -- "data" (out-of-repo, keyed by project) | "jsonl" (in-repo file)
    path = ".ai/review.jsonl", -- used when backend == "jsonl"
    auto = true, -- save on every mutation, load on setup
  },

  -- Project key: the nearest ancestor with a project marker (.git / .hg / .svn), so
  -- threads are scoped per-project regardless of where you cd; falls back to the cwd.
  root = function()
    local start = vim.fn.getcwd()
    local found = vim.fs.find({ ".git", ".hg", ".svn" }, { upward = true, path = start })[1]
    if found then
      return vim.fn.fnamemodify(found, ":h")
    end
    return start
  end,

  view = { default = "buffer" }, -- "buffer" | "quickfix" | "split"

  render = {
    enabled = true,
    -- In-file gutter/eol decorations for a comment's range.
    annotations = {
      signs = true, -- gutter sign on every line of the range
      sign = "▌", -- the gutter sign glyph
      sign_hl = "DiagnosticInfo", -- gutter sign highlight group
      preview = true, -- eol first-line preview text (inline mode, bands off only)
      preview_hl = "Comment", -- eol preview highlight group
      preview_prefix = "  ▌ ", -- eol preview glyph/prefix
      resolved_sign = "✓", -- gutter sign for a hidden resolved comment
      show_resolved = false, -- hide resolved threads (just the gutter sign); <leader>oh toggles
    },
    winblend = 0, -- 0 = opaque floats; >0 (e.g. 12) = see-through popup/input/compose
    transparent = false, -- drop bubble backgrounds (NONE) everywhere; keep bars/dividers/text
    bar = "▎", -- left accent bar glyph (1 cell); e.g. "▌" or "█" for a thicker/bolder bar
    -- Keybind hint footers in the chat surfaces (the sidebar/popup keybind line, the
    -- docked reply box's footer, and the quick-reply composer's footer) — ONE switch
    -- for all of them. Off = cleaner (the keys still work). Toggle live with
    -- <prefix>? / :ObelusHints / obelus.toggle_hints().
    hints = false,
    -- How the docked reply box behaves as you scroll the chat output:
    --   "pinned" — floats at the bottom of the view at all times (type while you read
    --              back through history). Its accent bar dims while you're scrolled up
    --              and brightens once you're seated at the bottom again.
    --   "serial" — sits after the last message and scrolls off-screen with the chat;
    --              reappears when you scroll back to the bottom.
    reply_dock = "pinned",
    -- Markdown renderer for the sidebar/popup turn bodies (inside obelus's bars/
    -- dividers/headers). Toggle live with :ObelusRenderer [markview|builtin|treesitter].
    --   "markview"   — markview.nvim renders tables/code/links (prettiest; needs the plugin)
    --   "builtin"    — obelus's own light in-house styling (no deps; always-clean bubble bg)
    --   "treesitter" — raw Markdown + treesitter syntax highlighting (real lines, no conceal)
    -- nil = auto: markview if installed, else builtin.
    renderer = nil,

    -- Inline thread bands: how a comment's conversation shows at its spot in the
    -- buffer (native, collapsible review view — either a rooted hover popup or a
    -- virt_lines band that pushes code down).
    bands = {
      enabled = true, -- on by default for buffers with comments
      mode = "focus", -- "focus" (expand the comment under the cursor + pinned) | "all"
      separator = true, -- blank line above each inline band, so adjacent threads don't merge
      -- how a thread shows at its comment (toggle with <prefix>B / :ObelusBandStyle):
      --   "popup"  = a rooted hover float on the focused comment (overlays, scrollable)
      --   "inline" = virt_lines band (pushes code down)
      style = "popup",
      markdown = true, -- light inline-markdown styling of the body
      rules = true, -- horizontal rule bars delineating the band
      max_width = nil, -- cap band width; nil = full window text width
      -- cap band height: line count (>=1), fraction of window (0<n<1), or nil = 60%.
      -- Long threads paginate in place — scroll with <prefix>J/<prefix>K.
      max_height = 0.6,
    },

    -- Source highlight groups the thread tints blend from (all theme-driven).
    colors = {
      you = "DiagnosticInfo", -- accent for your turns
      agent = "DiagnosticOk", -- accent for agent turns
      meta = "Comment", -- metadata (range, timestamps)
      tint = 0.08, -- background blend strength (0 = none); kept subtle
      rule = 0.75, -- divider brightness: blend toward the turn colour (0..1, 1 = full)
      -- markview inline `code` background inside the bubble:
      --   nil   — none: inline code inherits the bubble tint (no dark box), just a distinct fg
      --   true  — a subtle recessed box blended from the editor bg (the old look)
      --   <hl>/<0xRRGGBB> — an explicit background
      inline_code = nil,
      -- Visual-selection highlight INSIDE obelus chat windows (the theme's Visual can clash
      -- with the tinted bubbles): nil = leave the theme's Visual; a hl group name or 0xRRGGBB
      -- to override it just in the chat/popup.
      selection = nil,
    },
  },

  -- Pluggable AI backends. `default` = transport for :ObelusSubmit (batch);
  -- `dispatch` = transport for :ObelusDispatch (single comment, background).
  transport = {
    default = "sidekick",
    dispatch = "cli",
    sidekick = { name = "crush", focus = true },
    cli = {
      cmd = { "claude", "-p" }, -- headless agent; prompt appended as final arg
      stdin = false, -- true => pipe the prompt on stdin instead of as an arg
      -- Per send-mode models (nil = whatever the cmd / account default is). obelus
      -- passes `--model` itself, so DON'T also bake one into `cmd`.
      models = {
        send = nil, -- normal chat reply  (<CR> in the reply box)  — your "harder" model
        fast = nil, -- "send fast"     (<M-CR> in the reply box) — a quicker/cheaper model
        batch = nil, -- the batch submit (<prefix>s) — falls back to `send` when nil
      },
    },
    -- Continuable batch conversations: send related comments to ONE agent and keep
    -- talking to it across rounds (shared context). Only the session-capable transport
    -- (cli) can capture + resume a session, so batch submit routes there. <prefix>s
    -- creates a Batch + captures its session; <prefix>S continues it (next round).
    batch = {
      enabled = true, -- <prefix>s creates a continuable Batch (vs a one-shot send)
      transport = "cli", -- session-capable backend that captures + resumes the session
      mode = "session", -- "session" (--resume the shared session) | "stateless" (re-serialize)
      object = false, -- Phase 2: surface the Batch as a first-class meta-thread in the sidebar
      prompt = "diff", -- per-round prompt: "diff" (delta only) | "full" (re-serialize each round)
    },
    file = { path = ".ai/review.md" },
    clear_on_submit = false, -- mark "sent" (false) vs delete (true) after submit
    notify = false, -- toast when an agent run finishes/fails (off by default; :ObelusJobs has the log)
    -- Agent write-back protocol: inject instructions to write a per-job
    -- .ai/review-actions-<key>.json (resolve / needs_response / reply / move),
    -- then apply it after the run.
    actions = true,
    -- Use that triage protocol for interactive CHAT replies too? Off by default — in
    -- a conversation it makes the agent write a summary that replaces its real reply.
    chat_actions = false,
  },

  -- Background-job spinner. "auto" | "inline" | "corner" | "statusline" | "off".
  progress = { display = "auto" },

  input = {
    -- "@" in an obelus input buffer (the docked reply box, the quick-reply
    -- composer): false disables it entirely; true (the default) is sugar for
    -- the table below; a table overrides individual fields.
    --   picker     — fall back to a file picker (fzf-lua if installed, else
    --                 vim.ui.select) when no completion engine is active.
    --   completion — "auto" (blink.cmp if installed, else nvim-cmp, else
    --                 neither), "blink"/"cmp" to force one (warns once + falls
    --                 back to the picker if that plugin isn't present), or
    --                 false to never use a completion engine. When an engine
    --                 IS active it owns "@" — the picker keymap is not bound.
    mention = true,
  },

  keys = {
    prefix = "<leader>o", -- set keys = false to skip default mappings
    -- skip specific default mappings by suffix (the letter after the prefix), e.g.
    -- keys.disabled = { "x", "T" } to skip the "clear all" / "toggle global" maps.
    disabled = {},
    -- hold Alt and d/u to scroll a long inline band in place (half-page). Set
    -- band_scroll = false to disable, or add line_down/line_up = "<A-j>"/"<A-k>"
    -- if those are free for you. <prefix>J/<prefix>K also scroll.
    band_scroll = { down = "<A-d>", up = "<A-u>" },
  },
}

---@class obelus.Config.Render
---@field bands obelus.Config.Render.Bands

-- input.mention's expanded shape once normalized from the true|false|table sugar.
local MENTION_DEFAULTS = { picker = true, completion = "auto" }

---@class obelus.Config.Render.Bands
---@field enabled boolean
---@field mode "focus"|"all"
---@field separator boolean
---@field style "popup"|"inline"
---@field markdown boolean
---@field rules boolean
---@field max_width integer|nil
---@field max_height number|nil

M.options = vim.deepcopy(M.defaults)

-- Session-scoped UI toggles. They OVERRIDE options without mutating them, so
-- re-running setup() (e.g. a plugin manager reload) never reverts a live toggle.
-- nil = never toggled (fall through to options); set_renderer("auto") stores the
-- string "auto" — an EXPLICIT auto that still overrides an options.render.renderer.
M.ui = { renderer = nil, mode = nil, band_style = nil, show_resolved = nil, hints = nil }

---Effective engagement modality: the session override if one was ever set
---(:ObelusMode / toggle_mode), else options.mode.
---@return "inline"|"sidebar"
function M.mode()
  if M.ui.mode ~= nil then
    return M.ui.mode
  end
  return M.options.mode
end

-- Warn once per distinct bad value (path + value + allowed set both baked into the
-- message, so a different typo/path warns again but the same one doesn't spam).
-- `allowed` may itself contain non-strings (e.g. input.mention.completion's
-- `false`) — table.concat requires strings/numbers, so stringify first.
local function warn_enum(path, given, allowed)
  local shown = {}
  for i, a in ipairs(allowed) do
    shown[i] = tostring(a)
  end
  vim.notify_once(
    string.format(
      "obelus: %s = %s is invalid (expected one of: %s) — using the default",
      path,
      vim.inspect(given),
      table.concat(shown, " | ")
    ),
    vim.log.levels.WARN
  )
end

local function is_allowed(v, allowed)
  for _, a in ipairs(allowed) do
    if v == a then
      return true
    end
  end
  return false
end

-- Validate `opts[key]` against `allowed`; a disallowed non-nil value warns once and
-- resets the field to `default`. `allow_nil` marks nil itself as a legal value (e.g.
-- render.renderer's nil == auto) that should neither warn nor be replaced.
local function enum(opts, key, path, allowed, default, allow_nil)
  local v = opts[key]
  if v == nil then
    if not allow_nil then
      opts[key] = default
    end
    return
  end
  if not is_allowed(v, allowed) then
    warn_enum(path, v, allowed)
    opts[key] = default
  end
end

-- Validate a boolean-typed field: anything other than `true`/`false` warns once and
-- resets to `default`. render.hints used to be a { chat, compose } table —
-- normalize_hints (below) coerces that shape to a boolean before this ever runs, so
-- by the time validate() gets here only a genuinely bad value (a string, a number,
-- some other stray table) trips this.
local function boolean(opts, key, path, default)
  local v = opts[key]
  if type(v) ~= "boolean" then
    vim.notify_once(
      string.format("obelus: %s = %s is invalid (expected true|false) — using the default", path, vim.inspect(v)),
      vim.log.levels.WARN
    )
    opts[key] = default
  end
end

-- A scalar where a config TABLE belongs (e.g. `render = false`, `transport = 0`)
-- would crash the normalize/validate passes below with an index error — restore the
-- default subtable and warn once instead. `keys = false` is exempt (documented:
-- skip the default mappings entirely), as are the false-table shorthands
-- normalize_false_tables handles right after this.
local function ensure_table(parent, key, path, default)
  if type(parent[key]) ~= "table" then
    vim.notify_once("obelus: " .. path .. " must be a table — using the defaults", vim.log.levels.WARN)
    parent[key] = vim.deepcopy(default)
  end
end

local function ensure_tables(o)
  ensure_table(o, "persist", "persist", M.defaults.persist)
  ensure_table(o, "view", "view", M.defaults.view)
  ensure_table(o, "render", "render", M.defaults.render)
  ensure_table(o, "progress", "progress", M.defaults.progress)
  ensure_table(o, "input", "input", M.defaults.input)
  ensure_table(o, "transport", "transport", M.defaults.transport)
  ensure_table(o.transport, "batch", "transport.batch", M.defaults.transport.batch)
  ensure_table(o.transport, "cli", "transport.cli", M.defaults.transport.cli)
  ensure_table(o.transport.cli, "models", "transport.cli.models", M.defaults.transport.cli.models)
  if o.render.bands ~= false then -- false is the documented all-off shorthand (normalized below)
    ensure_table(o.render, "bands", "render.bands", M.defaults.render.bands)
  end
  ensure_table(o.render, "annotations", "render.annotations", M.defaults.render.annotations)
  ensure_table(o.render, "colors", "render.colors", M.defaults.render.colors)
end

-- render.bands == false is a documented "all off" shorthand, but
-- tbl_deep_extend("force", ...) REPLACES the whole subtable with the boolean `false`
-- rather than merging — so `(cfg.bands or {}).enabled ~= false` at every call site
-- silently reads an empty table and re-enables bands. Normalize false → the real
-- all-off shape before anything else touches it. `keys = false` is NOT normalized
-- here — it's documented to mean "skip mappings entirely" and stays a bare boolean.
local function normalize_false_tables(o)
  if o.render.bands == false then
    -- style/mode/separator/markdown/... keep their defaults — they're inert while
    -- disabled, and keeps re-enabling (bands.enabled = true) a one-key change.
    o.render.bands = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults.render.bands), { enabled = false })
  end
end

-- MIGRATION: render.hints was a { chat, compose } table; it's now a single boolean
-- (see config.defaults.render.hints). A user-passed table coerces to `true` if ANY of
-- its values was true, else `false` — so a config that had SOME hints already on
-- doesn't go fully silent. Runs after ensure_tables, so o.render is guaranteed a table.
local function normalize_hints(o)
  if type(o.render.hints) ~= "table" then
    return
  end
  local any = false
  for _, v in pairs(o.render.hints) do
    if v == true then
      any = true
      break
    end
  end
  vim.notify_once(
    "obelus: render.hints is a single boolean now (was { chat = ..., compose = ... }) — using " .. tostring(any),
    vim.log.levels.WARN
  )
  o.render.hints = any
end

-- input.mention: false | true | { picker?, completion? }. Runs after ensure_tables
-- (o.input is guaranteed a table by then). `false` is left alone — attach() short-
-- circuits on it, so it never becomes a table. `true` expands to MENTION_DEFAULTS.
-- A table merges over MENTION_DEFAULTS, so `{ completion = "cmp" }` still implies
-- `picker = true`. Anything else (a number, a string, ...) warns once and resets to
-- the default table, same "garbage in, defaults out" idiom as boolean()/enum().
local function normalize_mention(o)
  local v = o.input.mention
  if v == false then
    return
  end
  if v == true then
    o.input.mention = vim.deepcopy(MENTION_DEFAULTS)
    return
  end
  if type(v) == "table" then
    o.input.mention = vim.tbl_deep_extend("force", vim.deepcopy(MENTION_DEFAULTS), v)
    return
  end
  vim.notify_once(
    string.format(
      "obelus: input.mention = %s is invalid (expected false|true|table) — using the default",
      vim.inspect(v)
    ),
    vim.log.levels.WARN
  )
  o.input.mention = vim.deepcopy(MENTION_DEFAULTS)
end

-- One-time "removed — use X" warning per OLD key actually found in `raw_parent` (the
-- user's RAW opts subtable — never the merged/normalized copy, so the warning fires
-- on exactly what the user wrote). This is a clean break, not a migration: clears the
-- stale key from `merged_parent` too, so `config.options` never carries old-shape
-- leftovers forward — the value is fully ignored, not just unconsulted.
local function warn_and_clear(raw_parent, merged_parent, key, msg)
  if raw_parent and raw_parent[key] ~= nil then
    vim.notify_once("obelus: " .. msg, vim.log.levels.WARN)
    merged_parent[key] = nil
  end
end

-- Runs after ensure_tables, so merged.render / merged.transport.cli are guaranteed
-- tables. Guards raw opts.render/opts.transport/opts.transport.cli with type checks
-- (opts is unvalidated input, so any of them could be scalar garbage).
local function warn_removed(opts, merged)
  warn_and_clear(opts, merged, "engage", "engage is removed — use `mode` instead")

  local r = type(opts.render) == "table" and opts.render or nil
  local mr = merged.render
  warn_and_clear(r, mr, "thread", "render.thread is removed — its keys merged into render.bands")
  warn_and_clear(r, mr, "markview", 'render.markview is removed — use render.renderer = "markview"|"builtin"')
  warn_and_clear(r, mr, "signs", "render.signs is removed — moved into render.annotations.signs")
  warn_and_clear(r, mr, "sign_text", "render.sign_text is removed — moved into render.annotations.sign")
  warn_and_clear(r, mr, "sign_hl", "render.sign_hl is removed — moved into render.annotations.sign_hl")
  warn_and_clear(r, mr, "virt_text", "render.virt_text is removed — moved into render.annotations.preview")
  warn_and_clear(r, mr, "virt_text_hl", "render.virt_text_hl is removed — moved into render.annotations.preview_hl")
  warn_and_clear(
    r,
    mr,
    "virt_text_prefix",
    "render.virt_text_prefix is removed — moved into render.annotations.preview_prefix"
  )
  warn_and_clear(
    r,
    mr,
    "resolved_sign",
    "render.resolved_sign is removed — moved into render.annotations.resolved_sign"
  )
  warn_and_clear(
    r,
    mr,
    "show_resolved",
    "render.show_resolved is removed — moved into render.annotations.show_resolved"
  )

  local t = type(opts.transport) == "table" and opts.transport or nil
  local cli = t and type(t.cli) == "table" and t.cli or nil
  local mc = merged.transport.cli
  warn_and_clear(cli, mc, "model", "transport.cli.model is removed — moved into transport.cli.models.send")
  warn_and_clear(cli, mc, "fast_model", "transport.cli.fast_model is removed — moved into transport.cli.models.fast")
  warn_and_clear(
    cli,
    mc,
    "batch_model",
    "transport.cli.batch_model is removed — moved into transport.cli.models.batch"
  )
end

local function validate(o)
  enum(o, "mode", "mode", { "inline", "sidebar" }, M.defaults.mode)
  enum(o.persist, "backend", "persist.backend", { "data", "jsonl" }, M.defaults.persist.backend)
  enum(o.view, "default", "view.default", { "buffer", "quickfix", "split" }, M.defaults.view.default)
  enum(
    o.render,
    "renderer",
    "render.renderer",
    { "markview", "builtin", "treesitter" },
    M.defaults.render.renderer,
    true -- nil == auto: legal, not a typo
  )
  enum(o.render, "reply_dock", "render.reply_dock", { "pinned", "serial" }, M.defaults.render.reply_dock)
  boolean(o.render, "hints", "render.hints", M.defaults.render.hints)
  if o.input.mention ~= false then
    boolean(o.input.mention, "picker", "input.mention.picker", MENTION_DEFAULTS.picker)
    enum(
      o.input.mention,
      "completion",
      "input.mention.completion",
      { "auto", "blink", "cmp", false },
      MENTION_DEFAULTS.completion
    )
  end
  enum(o.render.bands, "style", "render.bands.style", { "popup", "inline" }, M.defaults.render.bands.style)
  enum(o.render.bands, "mode", "render.bands.mode", { "focus", "all" }, M.defaults.render.bands.mode)
  enum(
    o.progress,
    "display",
    "progress.display",
    { "auto", "inline", "corner", "statusline", "off" },
    M.defaults.progress.display
  )
  enum(o.transport.batch, "mode", "transport.batch.mode", { "session", "stateless" }, M.defaults.transport.batch.mode)
  enum(o.transport.batch, "prompt", "transport.batch.prompt", { "diff", "full" }, M.defaults.transport.batch.prompt)
end

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

  ensure_tables(merged)
  normalize_false_tables(merged)
  normalize_hints(merged)
  normalize_mention(merged)
  warn_removed(opts, merged)
  validate(merged)

  if type(merged.root) == "string" then
    local r = merged.root
    merged.root = function()
      return r
    end
  end

  M.options = merged
  -- M.ui is intentionally NOT reset here: session toggles (:ObelusRenderer,
  -- :ObelusMode, band style, show-resolved, hints) must survive a re-run of setup().
  return M.options
end

return M
