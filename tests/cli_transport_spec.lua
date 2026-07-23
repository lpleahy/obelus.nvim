-- cli transport: per-CLI argv construction (base_cmd/finish_cmd) + session
-- capture — the configurable flag mapping that lets a non-claude CLI (e.g.
-- Google's `agy`) drive the transport. All pure given config.options: no
-- subprocess is spawned here (the spawn/rollback path is covered in e2e_spec).
T.describe("cli_transport")

local cli = require("obelus.transport.cli")
local config = require("obelus.config")

-- The agy-shaped profile several specs below share: plain-text streaming, prompt
-- as -p's VALUE, --conversation resume, session id fished out of a --log-file.
local AGY = {
  cmd = { "agy", "--dangerously-skip-permissions", "--sandbox" },
  prompt_flag = "-p",
  output = "text",
  flags = { resume = "--conversation", stream = {} },
  plan = {
    strip = { "--mode" },
    strip_flags = { "--dangerously-skip-permissions" },
    args = { "--mode", "plan" },
  },
  session = { flag = "--log-file", pattern = "Print mode: conversation=([%x%-]+)" },
}

local function setup_cli(cli_opts)
  config.setup({ transport = { cli = cli_opts } })
end

T.it("claude default: argv is exactly the pre-refactor shape", function()
  setup_cli({ cmd = { "claude", "-p", "--permission-mode", "acceptEdits" } })
  local cmd, c = cli._base_cmd("sess-1", "opus")
  local sysopts = {}
  local logfile = cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.eq(cmd, {
    "claude",
    "-p",
    "--permission-mode",
    "acceptEdits",
    "--model",
    "opus",
    "--resume",
    "sess-1",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "PROMPT",
  }, "claude argv unchanged by the per-CLI refactor")
  T.is_nil(logfile, "no session log for stream-json CLIs")
  T.is_nil(sysopts.stdin, "prompt on argv, not stdin")
end)

T.it("claude default: edits-off swaps --permission-mode for plan", function()
  setup_cli({ cmd = { "claude", "-p", "--permission-mode", "acceptEdits" } })
  config.ui.perms = "read-only"
  local cmd = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.eq(cmd, { "claude", "-p", "--permission-mode", "plan" })
end)

T.it("owned flags baked into cmd are stripped (output-format + model)", function()
  setup_cli({ cmd = { "claude", "-p", "--output-format", "json", "--model", "haiku" } })
  local cmd = cli._base_cmd(nil, "opus")
  T.eq(cmd, { "claude", "-p", "--model", "opus" })
end)

T.it("agy profile: prompt as -p's value, custom resume flag, no stream-json args, session log", function()
  setup_cli(AGY)
  local cmd, c = cli._base_cmd("conv-42", "gemini-3.6-flash-low")
  local sysopts = {}
  local logfile = cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.ok(logfile and logfile ~= "", "session capture allocated a temp log path")
  T.eq(cmd, {
    "agy",
    "--dangerously-skip-permissions",
    "--sandbox",
    "--model",
    "gemini-3.6-flash-low",
    "--conversation",
    "conv-42",
    "--log-file",
    logfile,
    "-p",
    "PROMPT",
  }, "agy argv shape")
  T.is_nil(sysopts.stdin, "prompt on argv, not stdin")
end)

T.it("agy profile: edits-off strips the dangerous bool flag and swaps in --mode plan", function()
  setup_cli(AGY)
  config.ui.perms = "read-only"
  local cmd = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.eq(cmd, { "agy", "--sandbox", "--mode", "plan" })
end)

T.it("plan as a function owns the whole read-only swap", function()
  setup_cli({
    cmd = { "mycli" },
    plan = function()
      return { "mycli", "--read-only" }
    end,
  })
  config.ui.perms = "read-only"
  local cmd = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.eq(cmd, { "mycli", "--read-only" })
end)

T.it("flags.model = false: never passes a model", function()
  setup_cli({ cmd = { "mycli" }, flags = { model = false } })
  local cmd = cli._base_cmd(nil, "opus")
  T.eq(cmd, { "mycli" })
end)

T.it("flags.resume = false: resume dropped (fresh conversation), argv otherwise intact", function()
  setup_cli({ cmd = { "mycli" }, flags = { resume = false } })
  local cmd = cli._base_cmd("sess-1", nil)
  T.eq(cmd, { "mycli" })
end)

T.it("stdin mode wins over prompt_flag", function()
  setup_cli({ cmd = { "mycli" }, stdin = true, prompt_flag = "-p", flags = { stream = {} } })
  local cmd, c = cli._base_cmd(nil, nil)
  local sysopts = {}
  cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.eq(sysopts.stdin, "PROMPT")
  T.eq(cmd, { "mycli" }, "prompt not on argv when stdin is set")
end)

T.it("captured_session: extracts the id from the temp log and consumes the file", function()
  setup_cli(AGY)
  local c = config.options.transport.cli
  local logfile = vim.fn.tempname()
  local fd = assert(io.open(logfile, "w"))
  fd:write("I0722 13:23:32 printmode.go:216] Print mode: conversation=9daf0cc7-9535-49fd-a187-97855a4b72dc, sending\n")
  fd:close()
  local col = require("obelus.stream").text_collector(nil)
  local session = cli._captured_session(col, c, logfile)
  T.eq(session, "9daf0cc7-9535-49fd-a187-97855a4b72dc")
  T.is_nil((vim.uv or vim.loop).fs_stat(logfile), "temp log consumed")
end)

T.it("captured_session: the stream's own session id wins over the log", function()
  setup_cli(AGY)
  local c = config.options.transport.cli
  local logfile = vim.fn.tempname()
  local fd = assert(io.open(logfile, "w"))
  fd:write("Print mode: conversation=aaaaaaaa-0000-0000-0000-000000000000\n")
  fd:close()
  local col = require("obelus.stream").collector(nil)
  col.feed(vim.json.encode({ type = "system", session_id = "from-the-stream" }) .. "\n")
  local session = cli._captured_session(col, c, logfile)
  T.eq(session, "from-the-stream")
  T.is_nil((vim.uv or vim.loop).fs_stat(logfile), "temp log still consumed")
end)

-- ── presets, labels, permission levels ──────────────────────────────────────

T.it("preset 'antigravity': fills the protocol knobs; keys set alongside override it", function()
  config.setup({
    transport = { cli = { preset = "antigravity", models = { send = "my-model" }, name = "gravity" } },
  })
  local c = config.options.transport.cli
  T.eq(c.cmd[1], "agy")
  T.eq(c.prompt_flag, "-p")
  T.eq(c.output, "text")
  T.eq(c.flags.resume, "--conversation")
  T.eq(c.session.flag, "--log-file")
  T.eq(type(c.before_spawn), "function", "the --add-dir hook rides the preset")
  T.ok(vim.tbl_contains(c.permissions.state, "~/.gemini"), "agy state dir writable")
  T.eq(c.models.send, "my-model", "user models survive")
  T.eq(c.name, "gravity", "user keys override the preset")
end)

T.it("preset 'claude': acceptEdits cmd + claude state dirs; unknown preset is ignored", function()
  config.setup({ transport = { cli = { preset = "claude" } } })
  local c = config.options.transport.cli
  T.eq(c.cmd, { "claude", "-p", "--permission-mode", "acceptEdits" })
  T.ok(vim.tbl_contains(c.permissions.state, "~/.claude"))
  config.setup({ transport = { cli = { preset = "no-such-cli" } } })
  T.eq(config.options.transport.cli.cmd, { "claude", "-p" }, "unknown preset falls back to the defaults")
end)

T.it("agent_label: cli basename by default, name override, sidekick name for sidekick dispatch", function()
  config.setup({ transport = { cli = { cmd = { "/opt/homebrew/bin/agy", "--sandbox" } } } })
  T.eq(config.agent_label(), "agy")
  config.setup({ transport = { cli = { cmd = { "agy" }, name = "antigravity" } } })
  T.eq(config.agent_label(), "antigravity")
  config.setup({ transport = { dispatch = "sidekick", sidekick = { name = "crush" } } })
  T.eq(config.agent_label(), "crush")
end)

T.it("enforce: wraps for project-edit with the project root; read-only mode reaches the wrapper", function()
  local seen
  config.setup({
    transport = {
      cli = {
        permissions = {
          wrapper = function(cmd, wctx)
            seen = wctx
            return vim.list_extend({ "WRAP" }, cmd)
          end,
        },
      },
    },
  })
  local c = config.options.transport.cli
  config.ui.perms = nil -- default level: project-edit
  local out = cli._enforce({ "mycli", "-p", "hi" }, c, "/proj/root")
  T.eq(out[1], "WRAP")
  T.eq(seen.root, "/proj/root")
  T.eq(seen.mode, "project-edit")
  config.ui.perms = "read-only"
  cli._enforce({ "mycli" }, c, "/proj/root")
  T.eq(seen.mode, "read-only")
  config.ui.perms = nil
end)

T.it("enforce: 'unrestricted' and permissions.enabled = false skip the wrap", function()
  config.setup({
    transport = {
      cli = {
        permissions = {
          wrapper = function(cmd)
            return vim.list_extend({ "WRAP" }, cmd)
          end,
        },
      },
    },
  })
  local c = config.options.transport.cli
  config.ui.perms = "unrestricted"
  local cmd = { "mycli" }
  T.eq(cli._enforce(cmd, c, "/proj"), cmd, "unrestricted never wraps")
  config.ui.perms = nil
  config.setup({ transport = { cli = { permissions = { enabled = false } } } })
  T.eq(cli._enforce(cmd, config.options.transport.cli, "/proj"), cmd, "enabled = false never wraps")
end)

T.it(":ObelusPerms cycles; :ObelusEdits maps onto the levels", function()
  T.fresh({})
  local cfg = require("obelus.config")
  T.eq(cfg.perms_level(), "project-edit", "default level")
  vim.cmd("ObelusPerms")
  T.eq(cfg.perms_level(), "unrestricted", "cycle: project-edit → unrestricted")
  vim.cmd("ObelusPerms")
  T.eq(cfg.perms_level(), "read-only", "cycle wraps to read-only")
  T.ok(not cfg.edits_enabled(), "read-only means edits off")
  vim.cmd("ObelusPerms project-edit")
  T.eq(cfg.perms_level(), "project-edit", "explicit level")
  vim.cmd("ObelusEdits off")
  T.eq(cfg.perms_level(), "read-only", "edits off = read-only")
  vim.cmd("ObelusEdits on")
  T.eq(cfg.perms_level(), "project-edit", "edits on = the default edit level")
  cfg.ui.perms = nil
end)

T.it("flags.resume as a function owns the argv placement (subcommand-style resume)", function()
  setup_cli({
    cmd = { "codex", "exec" },
    flags = {
      stream = {},
      resume = function(cmd, id)
        return vim.list_extend(vim.deepcopy(cmd), { "resume", id })
      end,
    },
  })
  local cmd = cli._base_cmd("sess-7", "gpt-5.3-codex")
  T.eq(cmd, { "codex", "exec", "--model", "gpt-5.3-codex", "resume", "sess-7" })
end)

-- ── the wider preset catalog ────────────────────────────────────────────────

T.it("preset 'codex': subcommand resume after exec, native sandbox (no wrap), plan → read-only", function()
  config.setup({ transport = { cli = { preset = "codex" } } })
  local c = config.options.transport.cli
  T.eq(c.permissions.enabled, false, "codex's native sandbox is the enforcement layer")
  local cmd = cli._base_cmd("thread-1", "gpt-5.4-mini")
  local sysopts = {}
  cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.eq(cmd, {
    "codex",
    "exec",
    "resume",
    "thread-1",
    "--skip-git-repo-check",
    "--color",
    "never",
    "--sandbox",
    "workspace-write",
    "--model",
    "gpt-5.4-mini",
    "--json",
    "PROMPT",
  })
  config.ui.perms = "read-only"
  local ro = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.eq(ro, { "codex", "exec", "--skip-git-repo-check", "--color", "never", "--sandbox", "read-only" })
  -- events mapper: thread id + message-granular blocks
  local col = require("obelus.stream").jsonl_collector(nil, c.events)
  col.feed('{"type":"thread.started","thread_id":"t-9"}\n')
  col.feed('{"type":"item.completed","item":{"type":"agent_message","text":"first"}}\n')
  col.feed('{"type":"item.completed","item":{"type":"reasoning","text":"skip me"}}\n')
  col.feed('{"type":"item.completed","item":{"type":"agent_message","text":"second"}}\n')
  T.eq(col.text(), "first\n\nsecond")
  T.eq(col.session(), "t-9")
end)

T.it("preset 'opencode': --format json events, --session resume, plan agent swap", function()
  config.setup({ transport = { cli = { preset = "opencode" } } })
  local c = config.options.transport.cli
  local cmd = cli._base_cmd("ses_abc", "anthropic/claude-haiku-4-5")
  local sysopts = {}
  cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.eq(cmd, {
    "opencode",
    "run",
    "--model",
    "anthropic/claude-haiku-4-5",
    "--session",
    "ses_abc",
    "--format",
    "json",
    "PROMPT",
  })
  config.ui.perms = "read-only"
  local ro = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.eq(ro, { "opencode", "run", "--agent", "plan" })
  local col = require("obelus.stream").jsonl_collector(nil, c.events)
  col.feed('{"type":"step_start","sessionID":"ses_xyz","part":{"type":"step-start"}}\n')
  col.feed('{"type":"text","sessionID":"ses_xyz","part":{"type":"text","text":"the reply"}}\n')
  T.eq(col.text(), "the reply")
  T.eq(col.session(), "ses_xyz")
end)

T.it("preset 'pi': --mode json token deltas, session event id, read-only tool allowlist", function()
  config.setup({ transport = { cli = { preset = "pi" } } })
  local c = config.options.transport.cli
  local cmd = cli._base_cmd("019f-aa", nil)
  local sysopts = {}
  cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.eq(cmd, { "pi", "-p", "--no-approve", "--session", "019f-aa", "--mode", "json", "PROMPT" })
  config.ui.perms = "read-only"
  local ro = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.eq(ro, { "pi", "-p", "--no-approve", "--tools", "read,grep,find,ls" })
  local col = require("obelus.stream").jsonl_collector(nil, c.events)
  col.feed('{"type":"session","version":3,"id":"019f8cc5-a0b2"}\n')
  col.feed('{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"hmm"}}\n')
  col.feed('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"kum"}}\n')
  col.feed('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"quat"}}\n')
  T.eq(col.text(), "kumquat", "thinking deltas are ignored, text deltas accumulate")
  T.eq(col.session(), "019f8cc5-a0b2")
end)

T.it("preset 'crush': plain-text run, post-run session command capture, {root} state", function()
  config.setup({ transport = { cli = { preset = "crush" } } })
  local c = config.options.transport.cli
  local cmd = cli._base_cmd("e666f22f-d245", nil)
  local sysopts = {}
  local logfile = cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.is_nil(logfile, "command-mode session capture uses no temp log")
  T.eq(cmd, { "crush", "run", "-q", "--session", "e666f22f-d245", "PROMPT" })
  T.ok(vim.tbl_contains(c.permissions.state, "{root}/.crush"), "project .crush stays writable")
  -- session.command extraction: fake the CLI with echo
  local sess = cli._captured_session(
    require("obelus.stream").text_collector(nil),
    vim.tbl_deep_extend("force", vim.deepcopy(c), {
      session = { command = { "printf", '[{"id":"ab78","uuid":"96c633ad-7da6-4cfa"}]' } },
    }),
    nil,
    vim.fn.getcwd()
  )
  T.eq(sess, "96c633ad-7da6-4cfa")
end)

T.it("preset 'gemini' and 'aider': argv shapes", function()
  config.setup({ transport = { cli = { preset = "gemini" } } })
  local c = config.options.transport.cli
  local cmd = cli._base_cmd("uuid-1", "gemini-2.5-flash")
  local sysopts = {}
  cli._finish_cmd(cmd, c, "PROMPT", sysopts)
  T.eq(cmd, {
    "gemini",
    "--skip-trust",
    "--approval-mode",
    "auto_edit",
    "--model",
    "gemini-2.5-flash",
    "--resume",
    "uuid-1",
    "-o",
    "stream-json",
    "--prompt",
    "PROMPT",
  })
  local col = require("obelus.stream").jsonl_collector(nil, c.events)
  col.feed('{"type":"init","session_id":"g-1"}\n{"type":"message","role":"assistant","content":"hi","delta":true}\n')
  T.eq(col.text(), "hi")
  T.eq(col.session(), "g-1")

  config.setup({ transport = { cli = { preset = "aider" } } })
  local a = config.options.transport.cli
  T.eq(a.flags.resume, false, "aider has no id-based sessions")
  T.eq(a.prompt_flag, "--message")
  config.ui.perms = "read-only"
  local ro = cli._base_cmd(nil, nil)
  config.ui.perms = nil
  T.ok(vim.tbl_contains(ro, "--dry-run"), "aider read-only = --dry-run")
  T.ok(vim.tbl_contains(ro, "--no-auto-commits"), "commit safety flags always present")
end)

T.it("preset merge: a user list REPLACES the preset's list, never splices", function()
  config.setup({ transport = { cli = { preset = "codex", cmd = { "my-codex", "exec" }, flags = { stream = {} } } } })
  local c = config.options.transport.cli
  T.eq(c.cmd, { "my-codex", "exec" }, "shorter user cmd wins wholesale")
  T.eq(c.flags.stream, {}, "user stream list wins over the preset's --json")
  T.eq(type(c.events), "function", "non-list preset keys still ride along")
end)
