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
  config.ui.edits = false
  local cmd = cli._base_cmd(nil, nil)
  config.ui.edits = nil
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
  config.ui.edits = false
  local cmd = cli._base_cmd(nil, nil)
  config.ui.edits = nil
  T.eq(cmd, { "agy", "--sandbox", "--mode", "plan" })
end)

T.it("plan as a function owns the whole read-only swap", function()
  setup_cli({
    cmd = { "mycli" },
    plan = function()
      return { "mycli", "--read-only" }
    end,
  })
  config.ui.edits = false
  local cmd = cli._base_cmd(nil, nil)
  config.ui.edits = nil
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
