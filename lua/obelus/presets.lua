-- Built-in transport.cli presets: `transport.cli.preset = "<name>"` fills the
-- per-CLI protocol knobs (cmd, prompt, output/events, flags, plan, session,
-- permissions.state); anything the user sets alongside `preset` overrides the
-- preset's value (defaults < preset < user — resolved in config.setup).
-- Presets carry NO models — model names are account/user choices; pass them in
-- transport.cli.models (some CLIs want provider-prefixed ids, noted per
-- preset).
--
-- Verification status (2026-07, macOS): claude / antigravity / crush /
-- opencode / pi were driven live end-to-end; codex's event stream and argv
-- were probed live but unauthenticated; gemini and aider are wired from
-- source/docs probing and marked UNVERIFIED below — expect to confirm the
-- first run.
local M = {}

-- ── Anthropic Claude Code ───────────────────────────────────────────────────
M.claude = {
  -- acceptEdits auto-approves project-confined edits and still gates
  -- destructive shell; obelus's read-only swap uses the default
  -- --permission-mode recipe. Everything else IS obelus's defaults
  -- (stream-json events carry deltas + the session id).
  cmd = { "claude", "-p", "--permission-mode", "acceptEdits" },
  permissions = {
    state = { "~/.claude", "~/.claude.json", "~/.claude.json.backup" },
  },
}

-- ── Google Antigravity CLI (agy) ────────────────────────────────────────────
M.antigravity = {
  -- Verified against agy 1.1.5: plain-text streaming; the prompt is -p's
  -- VALUE; headless auto-denies confirmations (even matching settings.json
  -- allow-rules), so edits need --dangerously-skip-permissions — obelus's OS
  -- sandbox is what actually confines those writes; --sandbox keeps agy's
  -- terminal restrictions on; the conversation id only appears in the log;
  -- agy operates on ITS OWN workspace → --add-dir per spawn.
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

-- ── OpenAI Codex CLI ────────────────────────────────────────────────────────
M.codex = {
  -- Verified against codex 0.144.6 (event stream live, turns unauthed):
  -- `codex exec` never prompts (approval_policy is hard-wired "never") and
  -- runs its NATIVE seatbelt/Landlock sandbox per tool call — workspace-write
  -- confines writes to the workspace + temp, which IS project-edit. That
  -- native sandbox breaks under an outer wrap (nested seatbelt:
  -- "sandbox_apply: Operation not permitted" — verified), so obelus's own
  -- sandbox is DISABLED here and the read-only swap maps to codex's
  -- `--sandbox read-only`. --json emits JSONL: thread.started carries the
  -- session id; agent_message items carry the (message-granular) text.
  -- NOTE: codex reads a piped stdin to EOF even with a positional prompt —
  -- obelus spawns with no stdin, which is the safe shape.
  cmd = { "codex", "exec", "--skip-git-repo-check", "--color", "never", "--sandbox", "workspace-write" },
  output = "jsonl",
  events = function(e)
    if e.type == "thread.started" then
      return { session = e.thread_id }
    end
    if e.type == "item.completed" and e.item and e.item.type == "agent_message" then
      return { block = e.item.text }
    end
    if e.type == "error" and e.message then
      return { block = "[codex error] " .. e.message }
    end
  end,
  flags = {
    stream = { "--json" },
    -- resume is a SUBCOMMAND of exec (`codex exec resume <id> …`), placed
    -- right after "exec"; trailing flags are accepted after it (verified)
    resume = function(cmd, id)
      local out = vim.deepcopy(cmd)
      for i, a in ipairs(out) do
        if a == "exec" then
          table.insert(out, i + 1, "resume")
          table.insert(out, i + 2, id)
          return out
        end
      end
      return vim.list_extend(out, { "resume", id })
    end,
  },
  plan = { strip = { "--sandbox" }, strip_flags = {}, args = { "--sandbox", "read-only" } },
  permissions = {
    enabled = false, -- codex's native sandbox is the enforcement layer here
    state = { "~/.codex" },
  },
}

-- ── sst/opencode ────────────────────────────────────────────────────────────
M.opencode = {
  -- Verified live against opencode 1.18.0: `run --format json` emits JSONL —
  -- every event carries sessionID; "text" events carry message-granular parts
  -- (no token deltas). In-cwd edits are allowed headlessly by the default
  -- build agent; out-of-cwd "ask" permissions are auto-REJECTED (exit stays
  -- 0). Read-only maps to the built-in plan agent. Default model comes from
  -- the user's opencode.json — pass models explicitly ("provider/model").
  -- NOTE: run spawns a private localhost server per invocation — obelus's
  -- sandbox permits loopback (network is left open by design).
  cmd = { "opencode", "run" },
  output = "jsonl",
  events = function(e)
    local ev = { session = e.sessionID }
    if e.type == "text" and e.part and e.part.text and e.part.text ~= "" then
      ev.block = e.part.text
    end
    return ev
  end,
  flags = { resume = "--session", stream = { "--format", "json" } },
  plan = { strip = { "--agent" }, strip_flags = {}, args = { "--agent", "plan" } },
  permissions = {
    state = { "~/.local/share/opencode", "~/.config/opencode", "~/.local/state/opencode", "~/.cache/opencode" },
  },
}

-- ── pi (badlogic/pi-mono) ───────────────────────────────────────────────────
M.pi = {
  -- Verified live against pi 0.80.6: `--mode json` streams true token deltas
  -- (message_update/assistantMessageEvent.text_delta); the first line is the
  -- session event with the id. pi has NO permission system — bash/edit/write
  -- run immediately — so obelus's OS sandbox is the only containment; the
  -- read-only swap uses pi's documented read-only tool allowlist.
  -- --no-approve skips project-local extension trust prompts that would stall
  -- a headless run. NOTE: pi reads a piped stdin to EOF (hangs on an idle
  -- open pipe) — obelus spawns with no stdin, which is the safe shape.
  -- Models are "provider/id" (e.g. "anthropic/claude-haiku-4-5").
  cmd = { "pi", "-p", "--no-approve" },
  output = "jsonl",
  events = function(e)
    if e.type == "session" then
      return { session = e.id }
    end
    local ame = e.type == "message_update" and e.assistantMessageEvent or nil
    if ame and ame.type == "text_delta" and ame.delta then
      return { delta = ame.delta }
    end
  end,
  flags = { resume = "--session", stream = { "--mode", "json" } },
  plan = { strip = { "--tools" }, strip_flags = {}, args = { "--tools", "read,grep,find,ls" } },
  permissions = {
    state = { "~/.pi" },
  },
}

-- ── Charmbracelet Crush ─────────────────────────────────────────────────────
M.crush = {
  -- Verified live against crush v0.79+: `run -q` streams token-granular clean
  -- text. Run mode AUTO-APPROVES every tool (yolo by design, no flag needed)
  -- — obelus's OS sandbox is the only containment, and crush has no plan
  -- mode, so read-only is sandbox-enforced only (the model isn't told; its
  -- writes just fail). The session id is never printed: it's captured
  -- post-run from `crush session list --json` (newest first, run in the
  -- project cwd; -s resume needs the UUID field, not the short id). crush
  -- writes ./.crush (sqlite + logs) INSIDE the project — kept writable in
  -- every mode via the {root} placeholder, and pre-created by before_spawn so
  -- a read-only first run can't fail on it. Models are "provider/model"; nil
  -- uses the user's crush.json defaults.
  cmd = { "crush", "run", "-q" },
  output = "text",
  flags = { resume = "--session", stream = {} },
  plan = { strip = {}, strip_flags = {}, args = {} },
  session = { command = { "crush", "session", "list", "--json" }, pattern = '"uuid":"([%x%-]+)"' },
  before_spawn = function(cwd)
    vim.fn.mkdir(cwd .. "/.crush", "p")
  end,
  permissions = {
    state = { "~/.config/crush", "~/.local/share/crush", "{root}/.crush" },
  },
}

-- ── Google Gemini CLI ───────────────────────────────────────────────────────
M.gemini = {
  -- UNVERIFIED live (wired from the shipped v0.52 bundle source + docs;
  -- confirm the first run). `-o stream-json` is JSONL: init carries
  -- session_id, assistant "message" events carry deltas. --skip-trust avoids
  -- the untrusted-dir exit 55; auto_edit auto-approves edit tools only; the
  -- read-only swap maps to --approval-mode plan; --resume takes the uuid.
  -- ~/.gemini is SHARED with Antigravity — state covers the whole dir.
  cmd = { "gemini", "--skip-trust", "--approval-mode", "auto_edit" },
  prompt_flag = "--prompt",
  output = "jsonl",
  events = function(e)
    if e.type == "init" then
      return { session = e.session_id }
    end
    if e.type == "message" and e.role == "assistant" and e.content and e.content ~= "" then
      return { delta = e.content }
    end
    if e.type == "result" and e.status == "error" and e.error then
      return { block = "[gemini error] " .. (e.error.message or "unknown") }
    end
  end,
  flags = { resume = "--resume", stream = { "-o", "stream-json" } },
  plan = { strip = { "--approval-mode" }, strip_flags = {}, args = { "--approval-mode", "plan" } },
  permissions = {
    state = { "~/.gemini", "~/.npm" },
  },
}

-- ── aider ───────────────────────────────────────────────────────────────────
M.aider = {
  -- UNVERIFIED live (wired from help/docs probing; confirm the first run).
  -- aider EDITS FILES DIRECTLY and, by default, GIT-COMMITS both its edits
  -- and your dirty tree — the cmd disables all of that. Its stdout mixes
  -- prose with edit/commit/cost announcements (no clean framing) and its
  -- exit code is 0 even on hard failure. No session id exists: resume is the
  -- boolean --restore-chat-history over the per-project
  -- .aider.chat.history.md, which doesn't fit obelus's id-based sessions —
  -- flags.resume = false (use transport.batch.mode = "stateless"). Read-only
  -- maps to --dry-run. Models need the litellm provider prefix
  -- ("anthropic/claude-…"). aider writes its history/cache into the project —
  -- kept writable via {root} entries.
  cmd = {
    "aider",
    "--no-check-update",
    "--no-analytics",
    "--no-show-release-notes",
    "--no-pretty",
    "--no-fancy-input",
    "--no-show-model-warnings",
    "--no-gitignore",
    "--yes-always",
    "--no-auto-commits",
    "--no-dirty-commits",
    "--no-suggest-shell-commands",
    "--no-auto-lint",
  },
  prompt_flag = "--message",
  output = "text",
  flags = { resume = false, stream = {} },
  plan = { strip = {}, strip_flags = {}, args = { "--dry-run" } },
  permissions = {
    state = {
      "~/.aider",
      "~/.aider.conf.yml",
      "{root}/.aider.chat.history.md",
      "{root}/.aider.input.history",
      "{root}/.aider.tags.cache.v4",
    },
  },
}

return M
