-- Built-in transport.cli presets: `transport.cli.preset = "claude"|"antigravity"`
-- fills the per-CLI protocol knobs (cmd, flags, plan, session, …) and the
-- permission state dirs; anything the user sets alongside `preset` overrides
-- the preset's value (defaults < preset < user — resolved in config.setup).
-- Presets carry NO models — model names are account/user choices.
local M = {}

M.claude = {
  -- acceptEdits auto-approves project-confined edits and still gates
  -- destructive shell; obelus's read-only swap (`plan`) uses the default
  -- --permission-mode recipe. Everything else IS obelus's defaults.
  cmd = { "claude", "-p", "--permission-mode", "acceptEdits" },
  permissions = {
    -- claude's own state (oauth/config/session transcripts) must stay
    -- writable even in read-only mode
    state = { "~/.claude", "~/.claude.json", "~/.claude.json.backup" },
  },
}

M.antigravity = {
  -- Google Antigravity CLI (brew install --cask antigravity-cli; binary agy).
  -- Print-mode facts (verified against agy 1.1.5):
  --   • streams PLAIN TEXT (no JSON events) → output = "text"
  --   • the prompt is -p's VALUE, never a positional → prompt_flag
  --   • headless auto-denies tool confirmations it can't prompt for (even with
  --     settings.json allow-rules) → edits need --dangerously-skip-permissions;
  --     obelus's OS sandbox is what actually confines those writes to the
  --     project, and --sandbox keeps agy's terminal restrictions on
  --   • the conversation id only appears in agy's log → --log-file capture
  --   • agy operates on ITS OWN workspace, not the cwd → --add-dir per spawn
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
  before_spawn = function(cwd, cmd)
    vim.list_extend(cmd, { "--add-dir", cwd })
  end,
  permissions = {
    state = { "~/.gemini" },
  },
}

return M
