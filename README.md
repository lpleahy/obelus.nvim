# obelus.nvim

Local-first code review for Neovim. Select any region of any file, attach a comment, collect a
batch across files, and send it to an AI agent. No pull request, no diff, no git requirement, no
copy-paste.

Transports: `sidekick` (a running CLI agent), `cli` (headless, e.g. `claude -p` or `codex exec`),
`file`, and `quickfix`. Early stage: capturing, annotating, curating, and submitting a batch works
today.

Reply inputs support `@` file mentions: with blink.cmp or nvim-cmp installed, typing `@` completes
project files through its own menu (auto-detected — blink first, then cmp); otherwise `@` opens a
file picker (fzf-lua if installed, a built-in fallback otherwise) and inserts the picked file's
project-relative path.

## Install

lazy.nvim:

```lua
{ "lpleahy/obelus.nvim", main = "obelus", opts = {} }
```

Local checkout:

```lua
{ dir = "~/code/obelus", main = "obelus", opts = {} }
```

## Keymaps

Prefix `<leader>o` (change `keys.prefix`, or set `keys = false` to skip the maps). Each mapping
also has an `:Obelus*` command.

| Key | Action |
| --- | --- |
| `oc` | Comment the current line (or visual selection) |
| `ol` / `oq` | Open the review list (buffer / quickfix) |
| `op` | Toggle the threads sidebar |
| `oo` | Open the thread at the cursor as a chat |
| `oa` | Open/create the project thread |
| `oA` | Open/create the active tag's meta/batch thread |
| `or` / `of` | Reply to the thread (docked box / quick float) |
| `oR` / `oh` | Toggle resolved / show-hide resolved |
| `od` | Delete the comment at cursor |
| `os` / `oS` | Submit or continue the batch / force a new batch |
| `oD` / `oC` | Dispatch one thread in the background / cancel |
| `oj` | Open the background-job output log |
| `og` / `oG` | Tag the thread / sticky-tag mode |
| `ot` / `oT` | Toggle inline annotations (buffer / global) |
| `ob` / `oB` | Toggle inline bands / band style |
| `oz` | Pin/collapse the band at cursor |
| `oJ` / `oK` | Scroll the thread at cursor down / up |
| `om` | Toggle inline ↔ sidebar |
| `o?` | Toggle keybind hint footers |
| `ox` | Clear all threads |
| `<A-d>` / `<A-u>` | Scroll a long inline band in place (global default; `keys.band_scroll`) |

Chat rendering: `:ObelusRenderer markview|builtin|treesitter` (no argument cycles through them).
Skip specific default mappings with `keys.disabled = { "x", "T" }` (a list of suffixes);
`keys = false` skips all of them.

In the reply box (or the quick-reply composer), `@` in insert mode mentions a project file — via
blink.cmp/nvim-cmp when one is installed, else the picker. Set `input.mention = false` to disable
it entirely, or `input.mention = { completion = "blink" | "cmp" | false }` to force/disable which
completion engine it uses (`picker = false` disables the picker fallback). Mentions that name a
real file highlight in the input and in the rendered chat — the color doubles as live validation.
What a mention MEANS to the agent is `input.mention.send`: `"reference"` (default) appends one
note telling it the `@paths` are project-relative files to read itself; `"inline"` embeds each
mentioned file's contents in the outgoing prompt (capped per file and in total).

`<C-y>` (`keys.chat.paste_image`) grabs whatever image is on the system clipboard into
`.ai/img/` and @-mentions it right there, so the agent can just Read the screenshot you copied.
`:ObelusImgClean` / `obelus.img_clean()` deletes any `.ai/img` file no stored comment/reply
mentions anymore.

`oa` / `:ObelusProject` opens the project thread: one meta-level chat with context over every
other thread, not just one file/range. Its first message is briefed with every open thread in
full and every resolved one as a one-line summary; `@thread:<id>` mentions (in any chat) pull a
thread's full history back in, and the agent can reply/resolve/ask individual threads from there
via the same write-back protocol a batch dispatch uses.

A tag is ONE agent conversation: `oA` / `:ObelusTagThread` opens it directly, and replying to any
tagged thread (`or`) or running a batch round (`os`/`oS`, `<M-s>`) all resume that SAME session,
scoped to just what changed since the last message. Untagging a thread forks it onto its own
fresh session, so its history stays out of a tag it no longer belongs to.

Popup geometry is one knob: `render.preview_matches_chat`. Off (default), the boxes adapt —
every pass re-picks the roomier side of the commented lines and each surface sizes its own
comfortable width. On, the hover preview and the chat popup share ONE geometry (the chat's
width recipe and a per-thread anchor side held once decided), so replying to a hovered thread
just adds the input box — no resize, no jumping across the selection.

## API

The public surface of `require("obelus")` (also see `require("obelus.review")`, which
`obelus.edit`/`obelus.submit`/etc. re-export):

| Function | |
| --- | --- |
| `comment()` / `comment_visual()` | Capture a review comment (normal / visual selection) |
| `toggle(scope?)` | Toggle annotation display (`"global"` or the current buffer) |
| `list(backend?)` | Open the review list (`"buffer"` \| `"quickfix"` \| `"split"`) |
| `panel()` | Toggle the threads sidebar/popup |
| `project()` | Get-or-create the project thread and open it |
| `tag_thread()` | Get-or-create the active tag's meta/batch thread and open it (toggles closed) |
| `open_chat(id?)` | Open the sidebar for a thread (or the navigator list) |
| `reply_here()` | Reply to the thread at cursor in the active modality |
| `quick_reply(id?)` | Reply via the small inline compose float |
| `set_mode(mode)` / `toggle_mode()` | Set/toggle `"inline"` \| `"sidebar"` |
| `set_renderer(mode?)` | Set/cycle the chat markdown renderer |
| `toggle_hints()` | Toggle the keybind hint footers |
| `edit(id?)` / `delete(id?)` | Edit / delete a comment |
| `submit(name?, opts?)` | Submit pending comments (batch or one-shot) |
| `tag(id?, name?)` / `tag_mode(name?)` | Tag/untag a thread / sticky tagging mode |
| `continue_batch(text?)` / `batch_advance(text?)` | Continue the open batch / auto submit-or-continue |
| `dispatch(id?)` / `cancel(id?)` | Background-dispatch a thread / cancel it |
| `resolve(id?)` / `reopen(id?)` / `toggle_resolve(id?)` | Resolve / reopen a thread |
| `busy(id)` | Is this thread mid-dispatch? |
| `respond(id?, text?)` | Respond to a thread (prompts when `text` is nil) |
| `chat_save(id, text)` / `chat_send(id, text, mode?)` | Save a draft / send now |
| `submit_all(id, text)` | SUBMIT-ALL: a tag meta's batch round with member drafts folded in |
| `clear()` | Clear all comments |

## Configuration

Defaults are in [`lua/obelus/config.lua`](lua/obelus/config.lua). Full reference at `:h obelus`
(doc/obelus.txt).

```lua
require("obelus").setup({
  mode = "inline",                              -- "inline" | "sidebar"
  persist = { backend = "data", auto = true },  -- "data" (out-of-repo) | "jsonl" (in-repo file)
  render = {
    hints = false,                               -- keybind hint footers everywhere; <leader>o? toggles
    annotations = { signs = true, preview = true }, -- in-file gutter/eol decorations
  },
  input = { mention = true },                    -- "@" mentions in reply inputs (blink/cmp, else picker)

  transport = {
    default = "sidekick",
    sidekick = { name = "crush" },
    cli = {
      cmd = { "claude", "-p" },                  -- any headless command
      models = { send = nil, fast = nil, batch = nil }, -- per send-mode --model overrides
    },
  },
})
```

A transport is a function; register your own:

```lua
require("obelus.transport").register("my-agent", function(payload)
  -- payload.comments : the batch    payload.markdown : the formatted prompt
  vim.system({ "my-agent", "--apply" }, { stdin = payload.markdown })
end)
-- :ObelusSubmit my-agent
```

## Development

```sh
make test   # headless test suite
make lint   # stylua --check
```

The markview specs are skipped unless markview.nvim and nvim-treesitter are on the runtimepath:

```sh
OBELUS_TEST_RTP=/path/to/markview.nvim:/path/to/nvim-treesitter make test
```

## License

MIT
