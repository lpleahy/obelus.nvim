# Guard mutations

These runs show that the harness is sensitive. `make ui-mutations`
(`tests/ui/mutations.sh`) copies `lua/` and `tests/` to a private temp dir. It first
checks that the unmodified copy passes; if not, it reports an invalid environment
and stops with exit 2. It then applies one mutation at a time and runs the harness.
A mutation counts as **caught** only when the run reaches comparison and reports a
baseline mismatch with no harness error. A harness error under a mutation counts as
**invalid**. The real tree is never modified.

Behaviour mutations (`spec_mutate`) are judged by NAME: each lists the
regression(s) that must fail. If any other test fails too, a paired pristine
control runs right away; if that control also fails, the mutation is INVALID
(an unrelated or flaky failure), otherwise the extra failures are recorded as
collateral. Every failing test name is printed. Self-test mutations name the
self-test case that must fail. `OBELUS_MUT_ONLY=name,…` runs a subset.

Last run: 2026-11-09 (finished before 10:57 AM PT), Neovim v0.12.6, 53 baselines (41 + 12
from `obelus.api`). Result: **56 caught (18 visual or setup, 1 harness, 7
containment, 2 real-UI behaviour, 28 behaviour specs, each failing its named
regression), 0 missed, 0 invalid** under `nice -n 10`; 17 behaviour mutations had
collateral failures, all with a clean pristine control. The per-row counts below for the first 18
rows are from the 41-baseline run; the `api_*` baselines add to some of them.

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
| api-cli-fallthrough (behaviour) | `transport/init.lua`: the `obelus.api` route in `submit()` is skipped | caught: 16 `[api]` specs |
| api-cli-guard-removed (behaviour) | `transport/cli.lua`: the CLI transport's own eligibility refusal is removed | caught: 2 `[api]` specs (a spawn is attempted) |
| api-eligibility-ignores-claims (behaviour) | `store.lua`: `agent_eligible` no longer consults the claimed schemes | caught: 7 `[api]` specs (restart, unloaded, @thread/briefing, claim_schemes, …) |
| claims-corrupt-fails-open (behaviour) | `claims.lua`: unclassifiable claims no longer block `scheme://` records | caught: 1 `[api]` spec |
| claims-not-persisted (behaviour) | `claims.lua`: the exclusive per-scheme create never happens | caught: 5 `[api]` specs (incl. the real-restart and two-editor subprocesses) |
| claims-malformed-fails-open (behaviour) | `claims.lua`: an entry that is not a regular file named after a valid scheme is ignored | caught: 1 `[api]` spec |
| claims-stat-error-fails-open (behaviour) | `claims.lua`: any stat error is taken as "no claims" | caught: 1 `[api]` spec |
| approve-headless-falls-through (behaviour) | `approve.lua`: no-UI check removed, so a headless prompt opens instead of denying | caught: 2 `[api]` specs |
| approve-no-unarmed-phase (behaviour) | `approve.lua`: focusing arms at once | caught: 3 `[api]` specs |
| approve-no-drain (behaviour) | `approve.lua`: each `getchar(0)` in the drain reports "nothing queued" | caught: 5 `[api]` specs (queued input with a blocked loop, …) |
| approve-cap-exhaustion-arms (behaviour) | `approve.lua`: running out of the drain cap reports "empty" and the prompt arms | caught: 4 `[api]` specs (between-drains 15001 keys, overflow, sustained input) |
| approve-no-drain-ui (real-UI snapshot) | the same mutation, judged by the harness | caught: 2 (`api_approve_queued_typeahead`, both sizes) |
| api-turn-id-not-reused (behaviour) | `api.lua`: every send gets a fresh `turn_id` | caught: 3 `[api]` specs (retry after answer failure, cancel, lost ack) |
| api-refresh-no-revalidation (behaviour) | `api.lua`: refresh trusts a `list()` result after `list()` replaced the registration | caught: 1 `[api]` spec |
| api-generation-check-removed (behaviour) | `api.lua`: a send callback no longer checks it owns its record and job | caught: 1 `[api]` spec |
| api-replace-keeps-old-sends (behaviour) | `api.lua`: unregister/replace no longer cancels the old registration's sends | caught: 2 `[api]` specs |
| api-thread-saved-to-jsonl (behaviour) | `store.lua`: backend threads are no longer skipped by `save()` | caught: 2 `[api]` specs |
| xdg-guard-lua-removed (containment) | `tests/xdg_guard.lua` returns at once | caught: 2 `xdg-guard` self-test failures (a direct `nvim … run.lua` with HOME at the decoy writes into its store) |
| xdg-guard-specs-sh-removed (containment) | `tests/specs.sh` no longer checks before starting nvim | caught: 1 `xdg-guard` self-test failure (nvim's startup log lands in the decoy) |
| claims-mkdir-eexist-fails (behaviour) | `claims.lua`: a competitor's EEXIST is not re-checked | named: "a competing creator's EEXIST" |
| claims-sync-not-verified (behaviour) | `claims.lua`: an existing marker counts as durable without a sync | named: "a claim whose sync fails is not reported durable" |
| approve-enter-unarmed-ignored (behaviour) | `approve.lua`: Enter back on the armed-only path | named: "approve: Enter while still unarmed denies at once" |
| approve-enter-unarmed-ignored-ui (real-UI snapshot) | the same | caught: 2 (`api_approve_enter_unarmed`) |
| approve-handle-focus-not-scoped (behaviour) | `approve.lua`: a handle's `focus()` acts on the open prompt | named: "approve handle: A open, B queued" |
| api-edit-keeps-turn-id (behaviour) | `store.lua`: an edited draft keeps its old turn id | named: "turn_id: fail → edit → refresh → dispatch" |
| api-create-result-relabelled (behaviour) | `api.lua`: a `create()` result is adopted after its registration was replaced | named: "re-entrant create(): a replacement with a colliding id" |
| api-match-stale-owner (behaviour) | `api.lua`: a `match()` answer is trusted after it removed/replaced its registration | named: "re-entrant match()" |
| api-cancel-reason-always-user (behaviour) | `api.lua`: every cancel is reported as "user" | named: "cancel reasons: an explicit user cancel" |
| review-cancel-without-user-reason (behaviour) | `review.lua`: the explicit cancel passes no reason | named: "cancel reasons: an explicit user cancel" |
| xdg-guard-sh-defaults-by-spelling (containment) | `tests/xdg_guard.sh`: the defaults are matched by spelling only | named self-test: "xdg-guard: private.sh, alias root" |
| xdg-guard-lua-defaults-by-spelling (containment) | `tests/xdg_guard.lua`: the same on the nvim side | named self-test: "xdg-guard: direct nvim run.lua, alias root" |
| xdg-guard-log-symlink-allowed (containment) | `tests/xdg_guard.sh`: a symlinked `NVIM_LOG_FILE` passes | named self-test: "xdg-guard: private.sh, log file is a symlink" |
| api-late-cancel-loses-reason (behaviour) | `api.lua`: a cancel function returned after the send ended is called with no reason (and after done/error too) | named: "terminated INSIDE send()" |
| claims-chain-skips-an-ancestor (behaviour) | `claims.lua`: the sync chain skips every other ancestor directory | named: "every claim syncs its marker, claims/ and every ancestor" (+ the any-depth restart spec) |
| approve-hint-allows-format-controls (behaviour) | `approve.lua`: bidi embeddings/overrides and line/paragraph separators pass | named: "approve: focus_hint rejects bidi, format and C1 controls" |
| xdg-guard-sh-relative-allowed (containment) | `tests/xdg_guard.sh`: relative values are accepted | named self-test: "xdg-guard: private.sh, relative XDG values" |
| launcher-unsafe-tmpdir-base (containment) | `tests/private.sh`: the inherited TMPDIR is used unchecked | named self-test: "xdg-guard: private.sh, inherited TMPDIR in a home's .local" |
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

## Margin view mutations

Run by hand on 2026-11-13 (12:38 to 12:42 PM PT), Neovim v0.12.6, in a scratch
detached worktree of `dc44ce1`, not by `mutations.sh`. Each mutation was applied
alone, then `OBELUS_UI_ONLY=margin_ make ui-snapshots` and `make specs` ran, and
the file was restored. A pristine control first passed: 14 margin snapshots and
533 specs. As above, a snapshot counts as caught only on a baseline mismatch with
no harness error; every run below had 0 errors, and every failing spec was a
`[margin_layout]` case. Result: **9 caught, 0 missed, 0 invalid.**

| Mutation | Change in the copy | Result |
| --- | --- | --- |
| margin-pane-width | `margin.lua`: pane width `* 0.43` → `* 0.44` | caught: 6 (every 80x24 margin snapshot that keeps the pane open; at 160x45 the pane is capped at 62) |
| margin-active-border | `margin.lua`: the active card's border uses `ObelusMarginBorder`, not `ObelusMarginActive` | caught: 12 |
| margin-indicator-label | `margin.lua`: top indicator label `above/packed` → `above` | caught: 12 |
| margin-close-keeps-anchors | `margin.lua`: `M.close` no longer clears the source buffer's anchor namespace | caught: 2 (`margin_closed_again`, both sizes) |
| margin-close-keeps-autocmds | `margin.lua`: `M.close` no longer deletes the margin's augroup | caught: 2 (`margin_closed_again`, both sizes) |
| layout-default-gap | `margin_layout.lua`: `opts.gap or 1` → `or 0` | caught: 3 snapshots and 6 `[margin_layout]` specs |
| layout-no-backward-pass | `margin_layout.lua`: `stack_down`'s backward pass keeps each top as it is | caught: 2 `[margin_layout]` specs (no snapshot changes: the fixtures never need the pass) |
| layout-stack-up-mirror | `margin_layout.lua`: `stack_up` mirrors on `lo + hi + 1` | caught: 2 snapshots (`margin_stacked_cards`) and 2 specs |
| layout-order-reversed | `margin_layout.lua`: cards sort by `order` descending | caught: 8 snapshots and 8 specs |

## API turn-event mutations

Run by hand on 2026-11-13 (1:07 to 1:15 PM PT), Neovim v0.12.6, in a scratch
detached worktree of `90573e8`, not by `mutations.sh`. Each mutation was applied
alone, then `make specs` and `OBELUS_UI_ONLY=api_ make ui-snapshots` (the 26
`api_*` snapshots) ran, and the file was restored. A pristine control first
passed: 542 specs and 26 snapshots. Every snapshot run had 0 errors; every
failing spec was a `[api] turn events:` case. Result: **10 caught, 0 missed,
0 invalid.**

| Mutation | Change in the copy | Result |
| --- | --- | --- |
| meta-stored | `api.lua`: a tool or notice line is also appended to the reply (`stream_update`), so it is stored as turn text | caught: 2 specs, 10 snapshots |
| meta-sent-back | `api.lua`: the next send appends the last reply's tool and notice lines to `req.text` | caught: 1 spec ("the next send carries only the user's text") |
| no-opt-in-gate | `api.lua`: "thinking", "tool" and "notice" are handled without `turn_events` | caught: 1 spec (without the opt-in, rows and notification equal a plain run) |
| no-neutralize | `api.lua`: format characters are kept (only controls become spaces) | caught: 2 specs |
| field-bound-3000 | `api.lua`: `field_chars` 300 → 3000 | caught: 1 spec |
| no-row-cap | `api.lua`: tool and notice lines are no longer capped at 20 | caught: 1 spec |
| thinking-not-collapsed | `api.lua`: `_meta_of` keeps the thinking after the reply's first text | caught: 1 spec |
| cancel-keeps-rows | `api.lua`: a cancelled turn keeps its rows | caught: 1 spec |
| all-rows-above | `api.lua`: every line sits above the reply | caught: 1 spec, 6 snapshots |
| no-rows-below-reply | `thread.lua`: the lines after the reply's first text are not drawn | caught: 1 spec, 6 snapshots |

A first run, at `b245508`, missed thinking-not-collapsed: `thread.build`
repeated `_meta_of`'s check, so either guard alone was enough. `90573e8` keeps
the one in `_meta_of` and asserts it in the spec.

## History

The first run had 10 mutations. The first attempt at bubble-tint-colour changed
the `or 0.08` fallback in `thread.lua`. That fallback is dead code, because
`config.defaults` always sets `colors.tint`, so the run reported the mutation as
missed. The mutation now targets the config default. The miss came from the
mutation, not from a gap in the harness.
