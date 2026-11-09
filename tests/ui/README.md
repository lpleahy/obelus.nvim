# UI snapshot harness

Byte-identical regression tests for obelus's visual surfaces. Each scenario renders
in a fresh child Neovim with a real UI attached, then the harness compares the result
with a committed baseline. A baseline holds:

- the composed screen grid (floats included);
- a per-cell attribute map, with a legend giving each attribute's resolved colours and
  the highlight-group chain that produced it;
- the cursor and mode;
- every window: position, size, float config (border, title and footer chunks,
  zindex) and the window options that affect drawing;
- every extmark in every displayed buffer: namespace name, position, and full
  details (virt_text and virt_lines chunks, highlight groups, signs, conceal);
- `vim.notify` messages;
- the resolved attributes and link of every highlight group referenced above.

`registration` pins the setup path instead of a screen: the commands, global keymaps,
autocmds, `Obelus*` highlight groups and namespaces that `setup()` registers.

Scenarios are in `scenarios.lua`. Each runs at 80x24 and 160x45; `registration`
runs once. They use synthetic fixtures and the fake transport (`tests/fake.lua`)
only: no agents and no network.

## Run

```sh
make ui-snapshots          # compare (also part of `make test`, about 5 s)
OBELUS_UI_ONLY=band make ui-snapshots    # only scenarios whose name contains "band"
```

On a mismatch the harness prints the first differing line, writes the new rendering
to `tests/ui/actual/<scenario>@<WxH>.snap` (gitignored) and exits non-zero. Review it
with:

```sh
diff -u tests/ui/baselines/chat_popup@80x24.snap tests/ui/actual/chat_popup@80x24.snap
```

## Update

Only when a visual change is intended:

```sh
make ui-snapshots-update   # or OBELUS_UI_UPDATE=1 sh tests/ui/run.sh
git diff tests/ui/baselines
```

Review the baseline diff like code. The screen block shows layout and text. The
attrs block and legend show colours. The extmarks block shows decorations. An
unexpected change anywhere is a regression.

Baselines are tied to the Neovim version in `baselines/NVIM_VERSION`, because the
grid, the bundled treesitter parsers and the default colorscheme ship with Neovim.
With a different version the harness refuses to compare. Re-record and review the
diff.

## Hermeticity and determinism

- `run.sh` creates one private temp dir for the XDG config, data, state, cache and
  runtime dirs and for `TMPDIR`. It removes the dir afterwards. It also fixes `TZ`
  and the locale.
- Every process runs `nvim -n -i NONE -u NONE --noplugin`: no user config, plugins,
  shada or swap files. The colorscheme is `default` with `background=dark`, and
  `termguicolors` is on.
- The child stubs `os.time` and `os.date` to 2026-01-01T00:00:00Z, records
  `vim.notify` instead of drawing it, and replaces the project root and `TMPDIR`
  paths with `<ROOT>` and `<TMP>`.
- No wall-clock waits. `panel._timing` is pinned to 0. `progress._timing.tick` is
  set to about 11 days, so the spinner timer fires once immediately (frame 1 to
  frame 2) and never again: every spinner shows the frozen frame `⠙`. Deferred
  work is drained by counted event-loop turns. The only timeout is a deadlock
  guard.

## How it works

`run.lua`, the parent, talks msgpack-RPC to `nvim --embed` over pipes
(`rpc.lua`) and attaches an rgb `ext_linegrid` + `ext_hlstate` UI. With a UI
attached the child composes floats into the grid. `screenstring()` and
`screenattr()` (`child.lua`) then return exactly what a terminal would show. The
parent resolves attr ids using the UI's `hl_attr_define` events. A parent
`jobstart({ rpc = true })` channel can't be used here: Neovim closes it on the
child's `redraw` notifications.

Not covered: the `margin` module exists only in a local preview copy, not on
`main`. Markview and render-markdown renderers are not covered either: they are
third-party plugins and are kept out of the hermetic run. The builtin renderer is
covered.
