# Guard mutations

These runs show that the harness is sensitive. `make ui-mutations`
(`tests/ui/mutations.sh`) copies `lua/` and `tests/` to a private temp dir. It first
checks that the unmodified copy passes; if not, it reports an invalid environment
and stops with exit 2. It then applies one mutation at a time and runs the harness.
A mutation counts as **caught** only when the run reaches comparison and reports a
baseline mismatch with no harness error. A harness error under a mutation counts as
**invalid**. The real tree is never modified.

Last run: 2026-11-08, Neovim v0.12.6, 41 baselines. Result: **18 caught, 0 missed,
0 invalid**, 89 s under `nice -n 10`.

| Mutation | Change in the copy | Result |
| --- | --- | --- |
| band-highlight-group | `render.lua`: linewise band `line_hl_group` `ObelusThreadBg` → `ObelusThreadBar` | caught: 38 snapshots |
| virt-text-column | `config.lua`: eol preview prefix `"  ▌ "` → `"   ▌ "` (virt_text shifts one column) | caught: 2 |
| spinner-frame | `progress.lua`: spinner frame 2 `⠙` → `⠚` | caught: 8 |
| panel-width | `panel.lua`: sidebar width `columns * 0.42` → `* 0.43` | caught: 4 |
| markdown-bold-conceal | `thread.lua`: `**bold**` keeps its markers (no conceal) | caught: 26 |
| band-hint-string | `render.lua`: band hint `K up · J down` → `K up \| J down` | caught: 2 |
| composer-footer-label | `render.lua`: composer footer `save` → `store` | caught: 2 |
| bubble-tint-colour | `config.lua`: `colors.tint` 0.08 → 0.09 (colours only) | caught: 41 |
| spinner-priority-extmark-only | `progress.lua`: inline spinner extmark priority 4500 → 4400 (invisible on screen) | caught: 8 |
| keymap-desc | `init.lua`: `<prefix>?` keymap desc text | caught: 1 (registration) |
| setup-overwrites-default-Y | `setup()` maps `Y` to `dd`, overwriting Neovim's default | caught: 1 (registration) |
| setup-ungrouped-autocmd | `setup()` adds an ungrouped `BufEnter` autocmd | caught: 1 (registration) |
| setup-new-namespace | `setup()` creates namespace `obelus_api_review` | caught: 1 (registration) |
| chat-float-zindex | `config.lua`: `z.CHAT` 50 → 51 | caught: 6 |
| setup-overwrites-highlight | `setup()` re-links `Search` to `IncSearch` | caught: 1 (registration) |
| keymap-callback-swap-same-desc | `<prefix>?` callback calls `M.toggle_mode()` instead of `M.toggle_hints()`; description unchanged | caught: 1 (registration) |
| command-callback-swap-same-desc | `:ObelusEdit` callback calls `M.delete()`; description unchanged | caught: 1 (registration) |
| first-use-overwrites-default-Y | `quick_reply()` maps `Y` to `dd` the first time it runs | caught: 2 (both `compose_quick_reply_hints` sizes) |

The setup and zindex mutations come from the first independent review. Before the
B3 fix, the setup-time `Y` overwrite and the ungrouped autocmd passed the whole
suite. The last three come from the re-review, and all three passed before the
R2-B2 fix.

## Harness failure modes (`make ui-selftest`)

| Check | Result |
| --- | --- |
| Forced RPC timeout (`OBELUS_UI_GUARD_MS=1500`, child stuck in `while true do end`) | reported as a transport fault (`ERROR`), exit 1. `rpc.lua` reaps the child without the wrapper's fallback. No live child, no temp dir. |
| Scenario raises an error | `ERROR … deliberate scenario failure`, exit 1. No live child, no temp dir. |
| SIGTERM to `run.sh` mid-run, child wedged | exit 143. The parent is stopped, then its own children and the parent are killed. No temp dir. |
| SIGKILL to `run.sh` mid-run, child wedged (1.5 s guard) | the orphaned parent notices, its RPC guard fires, it reaps the child and removes the run dir. No live child, no temp dir. |
| An unrelated `nvim --embed` (started by the self-test, not the harness) runs through all of the above | never signalled; still alive at the end |
| 2.5 s wall-clock stall before each capture (progress, stream and popup scenarios) | 18/18 byte-identical to the baselines |

A full 41-snapshot run with a 2.5 s stall before every capture was byte-identical
to an undelayed run.

Negative control for the stall check: in a temp copy with the virtual clock turned
off (timers real, `settle` back to counted `vim.wait` turns),
`progress_finish_ok` passes without a stall. With the 2.5 s stall both of its
sizes fail: the `✓ fake` mark has cleared. This is the review's B2 reproduction.
The check really does depend on the virtual clock.

Wrong environment: with `baselines/NVIM_VERSION` set to `NVIM v0.0.0` in a temp
copy, `mutations.sh` prints `INVALID ENVIRONMENT` and exits 2. It no longer reports
"10 caught", as it did in the review.

## History

The first run had 10 mutations. The first attempt at bubble-tint-colour changed
the `or 0.08` fallback in `thread.lua`. That fallback is dead code, because
`config.defaults` always sets `colors.tint`, so the run reported the mutation as
missed. The mutation now targets the config default. The miss came from the
mutation, not from a gap in the harness.
