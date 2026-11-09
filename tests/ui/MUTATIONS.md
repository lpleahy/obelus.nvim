# Guard mutations

These runs show that the harness is sensitive. `make ui-mutations`
(`tests/ui/mutations.sh`) copies `lua/` and `tests/` to a private temp dir. It first
checks that the unmodified copy passes; if not, it reports an invalid environment
and stops with exit 2. It then applies one mutation at a time and runs the harness.
A mutation counts as **caught** only when the run reaches comparison and reports a
baseline mismatch with no harness error. A harness error under a mutation counts as
**invalid**. The real tree is never modified.

Last run: 2026-11-09, Neovim v0.12.6, 49 baselines (41 + 8 from `obelus.api`).
Result: **29 caught (18 visual or setup, 1 harness, 1 real-UI behaviour, 9
behaviour specs), 0 missed, 0 invalid**, 242 s under `nice -n 10`. The per-row
counts below for the first 18 rows are from the 41-baseline run; the `api_*`
baselines add to some of them (e.g. spinner-frame now 10, bubble-tint-colour 49).

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
| api-cli-fallthrough (behaviour) | `transport/init.lua`: the `obelus.api` route in `submit()` is skipped | caught: 9 `[api]` specs |
| api-cli-guard-removed (behaviour) | `transport/cli.lua`: the CLI transport's own eligibility refusal is removed | caught: 2 `[api]` specs (a spawn is attempted) |
| api-eligibility-ignores-uri (behaviour) | `store.lua`: `agent_eligible` no longer recognises `scheme://` records | caught: 3 `[api]` specs (restart, unloaded, @thread/briefing) |
| approve-headless-falls-through (behaviour) | `approve.lua`: no-UI check removed, so a headless prompt opens instead of denying | caught: 2 `[api]` specs |
| approve-no-unarmed-phase (behaviour) | `approve.lua`: focusing arms at once | caught: 3 `[api]` specs |
| approve-no-drain (behaviour) | `approve.lua`: the `getchar(0)` drain is removed | caught: 1 `[api]` spec (queued input with a blocked loop) |
| approve-no-drain-ui (real-UI snapshot) | the same mutation, judged by the harness | caught: 2 (`api_approve_queued_typeahead`, both sizes) |
| api-generation-check-removed (behaviour) | `api.lua`: a send callback no longer checks it owns its record and job | caught: 1 `[api]` spec |
| api-replace-keeps-old-sends (behaviour) | `api.lua`: unregister/replace no longer cancels the old registration's sends | caught: 2 `[api]` specs |
| api-thread-saved-to-jsonl (behaviour) | `store.lua`: backend threads are no longer skipped by `save()` | caught: 2 `[api]` specs |
| supervisor-skips-member-teardown (harness) | `supervise.pl`: the `teardown();` call is removed, so the group is released while members still run (R4-B1) | caught: 4 self-test failures (`parent-exit`, `parent-exit-harness`: exit 42 with log `reaped` only, straggler still alive) |

The setup and zindex mutations come from the first independent review. Before the
B3 fix, the setup-time `Y` overwrite and the ungrouped autocmd passed the whole
suite. The last three come from the re-review, and all three passed before the
R2-B2 fix.

The harness mutation is judged differently: `mutations.sh` first runs the
`parent-exit` and `parent-exit-harness` self-test cases on the unmodified copy
(they must pass), then on the mutated copy, where one of them must fail by name.
Their stragglers end on their own after 8-10 s, so the mutated run leaks nothing.

## Harness failure modes (`make ui-selftest`)

| Check | Result |
| --- | --- |
| Forced RPC timeout (`OBELUS_UI_GUARD_MS=1500`, child stuck in `while true do end`) | reported as a transport fault (`ERROR`), exit 1. `rpc.lua` reaps the child. No live child, no temp dir. |
| Scenario raises an error | `ERROR … deliberate scenario failure`, exit 1. No live child, no temp dir. |
| SIGTERM to the run mid-scenario, child wedged | exit 143. The supervisor sent TERM to its own group (KILL after grace). No live child, no temp dir. |
| SIGKILL of the supervisor mid-scenario (1.5 s guard) | exit 137. The orphaned parent's guard fires, it reaps the child and removes the run dir. |
| SIGKILL of the supervisor before the parent's Lua starts | the parent notices at its first check, captures nothing and removes the run dir |
| TERM after the parent has exited and the group was released | exit 143. The supervisor log shows `reaped` and no `signal`. Dir removed. |
| Parent exits 42 while a same-group child (ignores TERM, never reads stdin) runs | exit 42. Log: `signal TERM`, `signal KILL`, `reaped`. The child is gone when the supervisor returns (no polling). Dir removed. |
| Real harness: parent nvim exits 42 300 ms into the RPC of a child busy in Lua | exit 42. Log ends with `reaped` after `signal TERM`. Embedded child gone at return; temp dir removed. |
| TERM reaches the supervisor ~0.1 s after such a parent exits | exit 143. Child gone at return; dir removed. |
| `run.sh` with no `perl` on `PATH` | exit 2 with a message; nothing allocated in the temp base |
| An unrelated `nvim --embed` (the decoy), its pid injected into every pid record, running through all of the above | never signalled; alive at the end. The self-test only observes; the decoy is stopped by its own supervisor. |
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
