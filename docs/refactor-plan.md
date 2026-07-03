# obelus — code-review findings & refactor action plan

*2026-07-02. Produced by an 8-dimension multi-agent review (architecture, hacks inventory,
efficiency, readability, robustness, state management, API/config, tests). Every non-trivial
finding was adversarially verified against the code: 88 confirmed, 1 rejected. Where a verifier
judged the finding real but the proposed fix wrong, that fix is listed under "rejected
approaches" — those are as important as the workstreams.*

## Overall assessment

The domain core (store / batch / stream / actions / config) is clean and dependency-light, and
the code is unusually well-commented. The problems concentrate in three places:

1. **panel.lua is a god object** — six subsystems (renderer policy, float geometry, chat
   building, streaming/scroll state, reply-box lifecycle, hover preview) share one module and
   one ~25-field state table, and the hover preview re-implements the modal chat's whole
   fill/fit/seat pipeline.
2. **The positioning/rendering "hacks" are real but trace to four root causes**, not dozens of
   independent problems (§ root causes below). Most flags/self-heals are symptoms.
3. **Three live bugs** exist today (§ quick wins): completed dispatches never clear
   `dispatching` (a Lua `nil`-in-table no-op), a missing `claude` binary permanently wedges a
   thread, and a draft saved mid-stream corrupts the conversation (agent deltas land in the
   "you" turn).

Efficiency-wise the architecture is render-from-scratch on a 100 ms progress-timer heartbeat:
every tick rebuilds the entire conversation (panel + hover preview + bands), and fill()'s
throttle runs *after* the expensive rebuild it's meant to skip. Persistence rewrites the whole
jsonl synchronously on every mutation (~2N times per batch dispatch, for a runtime-only flag).

## The four root causes behind the hacks

1. **Reply box = a float glued over reserved blank buffer rows.** Spawns the over-scroll clamp,
   screenpos math, follow heuristics, pending-reveal, and the reposition machinery.
   *Verification rejected the "make it a real window" redesign* (it breaks `reply_dock="serial"`
   and the pinned float-bubble modes) — so this root cause is mitigated (specs + hygiene), not
   removed. Any future redesign is a separate opt-in experiment gated on the WS1 geometry specs.
2. **The streaming lifecycle has no single owner.** One async gap (send → stream_start) is
   bridged by three flags (`c.dispatching`, panel `state.streaming`, cli `running[]`) and four
   scattered lazy self-heals; error paths can strand each copy independently. → WS3.
3. **Rendering is poll-driven** (100 ms timer), and the coalesce/throttle defenses run after the
   rebuild. → quick win (hoist the time-throttle) + WS6.
4. **markview settles asynchronously**, compensated four different ad-hoc ways (never-shrink
   fit, forced redraw, deferred re-fit, hidden input). *A single deferred settle pass was
   rejected* (it would regress the modal's deterministic single-frame seat) — WS6 only
   parameterizes `fit_rooted` and rationalizes the preview's re-fit.

The healthiest pattern in panel.lua is `reconcile_renderer`'s computed-fresh declarative
want_mv/want_ts model — the refactors extend that style rather than adding flags.

---

## Git / worktree A/B mechanism

Each workstream is one branch off `main`, sequenced (later branches start from the merged state
of their prerequisites). A/B by swapping which checkout the plugin loads from:

```sh
# one-time: a second checkout for the branch under test
git -C ~/code/airev worktree add ~/code/obelus-ab <branch>

# the lazy.nvim spec points at a stable symlink instead of the repo:
ln -sfn ~/code/airev ~/code/obelus-active          # A: main
ln -sfn ~/code/obelus-ab ~/code/obelus-active      # B: the branch
```

and in `dotfiles .../plugins/obelus.lua` change `dir = "/Users/lpleahy/code/airev"` to
`dir = vim.fn.expand("~/code/obelus-active")` once. Flip the symlink, restart nvim, compare.
Remove with `git worktree remove ~/code/obelus-ab` when a branch merges.

**The standard eye-test script** (run on A then B, in the transparent-theme Ghostty):
open a real file → capture 2 comments (one charwise, one linewise) → dispatch one → stream a
long reply containing fenced code + a table + CJK text → hover-preview the other → open sidebar
AND popup chat → type a draft mid-stream and close → cancel a job → resolve/reopen. Watch for:
opaque rectangles (transparent-bg invariant), spinner freezes, divider glyph changes, reply-box
drift under `<C-e>` over-scroll, popup size jitter. `make test` must pass on every branch.

---

## Workstream 0 — quick wins  `chore/quick-wins`

Safe, independent, < 1 h each. The first three are **live bug fixes**; do these first.

1. **`{dispatching = nil}` no-op** — transport/cli.lua run_oneshot exit paths (~149, ~167):
   `store.update(id, { dispatching = nil })` does nothing in Lua (tbl_deep_extend can't carry a
   nil), so every completed batch/one-shot dispatch leaves threads flagged busy until a lazy
   self-heal. Fix: direct `c.dispatching = nil` write (+ persist-gated save) for ALL payload
   members, both exit paths. Do NOT reuse `store.abort` here — it pops the reply turn.
2. **store.save() persists `dispatching`** — strip it alongside extmark_id/bufnr (keep the
   load-time strip as migration for old files).
3. **store.abort() ignores persist.auto** (store.lua ~390) — gate `M.save()` like every other
   mutator; `persist.auto=false` users currently get `.ai/review.jsonl` written by cancels.
4. Delete dead panel state: `composing`, `_settling` (+ always-true guards at ~1634),
   `root.side` writes, stale comments referencing the removed reveal poll and nonexistent
   `M.preview_winleave`/`M.reposition_preview`.
5. Delete M.scroll's unreachable markview re-render block (panel.lua ~892–897; `_mv_attached`
   is permanently false there) and fix the stale lifecycle comment at ~1566. Delete, don't
   re-condition — per-keystroke full re-renders would jank.
6. Move the module-scope WinScrolled clamp registration (panel.lua ~951) into M.open's
   `obelus_panel` augroup — **pattern-less** (window patterns miss aggregated events) and
   registered BEFORE the follow/reposition handler to preserve execution order.
7. Delete unconsumed `render.range_hl` (config.lua:40) + orphaned `ObelusRangeBand` group
   (verified refactor leftovers; consumer removed in c24213a).
8. progress.lua: derive the inline-spinner row from `t.comment.range.sl` each frame instead of
   the cached line0 (spinner currently strands when edits shift the range mid-job).
9. Memoize file→buf resolution per progress-render frame (render.is_expanded/buf_for_file) —
   kills the O(comments × buffers) fnamemodify storm at 10 Hz. Frame-scoped, no invalidation.
10. panel.lua: nil `bar_maps[buf]` in WinClosed cleanup and hide_preview (table leak keyed by
    wiped bufnrs).
11. Move input_wincfg/reposition_input above fit_rooted; delete the 600-line-away forward
    declaration and the three always-true `if reposition_input then` guards.
12. **Hoist fill()'s 160 ms time-throttle above build_chat** (panel.lua ~663 → before ~637),
    keeping the content signature exactly as-is. Build drops 10x→~6x/sec during streaming;
    zero behavior change (spinner still animates — it's baked into the built lines).
13. tests/thread_spec.lua:40 — replace the +4 wrap slop with the computed bar-gutter allowance;
    add one CJK/emoji wrap case.

## Workstream 1 — regression harness  `test/regression-harness`

**Goal:** the headless suite can catch the actual bug classes (seating/geometry, streaming
lifecycle, band rendering, transparency) before any refactor lands. Every historical bug here
was found by eye; this gives the later A/Bs teeth.

- helpers: teardown per spec, `wait_for(cond, ms)`, named skips; a `panel._timing` seam (read
  at call time, not cached at load) so specs don't sleep past hard-coded throttles.
- A **fake transport** registered via the existing `transport.register`, so the full streaming
  lifecycle (stream_start → deltas → seat_finish → renderer swap) runs end-to-end headless.
- Extract the **stream collector** (byte-identical in two vim.system callbacks, cli.lua ~99 &
  ~259) into stream.lua and spec it. Must preserve: delta-over-result precedence,
  stderr-append-after-exit, silent drop of an unterminated final line (a slip here TRUNCATES
  streamed replies).
- `panel.geom()` read-only introspection (formats debug_geom's existing numbers) so specs stop
  reverse-engineering windows; export `_rows_to_chat` (the pure rows→lines/decos transform).
- New specs: seat-to-bottom geometry (builtin renderer = exact; markview variant = 1-row wobble
  tolerance), over-scroll clamp (**use `<C-e>`, not `<C-y>`**), render.lua bands
  (cap_rows/pagination/sync_positions/at_cursor), rows_to_chat divider/bubble structure,
  transparent-theme invariant (key off `render.transparent`, restore Normal afterwards),
  default-run markview specs (document OBELUS_TEST_RTP in CI or vendor a pin).
- Register new specs in tests/run.lua:26 (hardcoded list). Wait > 160 ms past fill's throttle
  before asserting buffer state. Don't spec panel.lua:892–897 (deleted by quick win 5).

**A/B:** mostly test-only; the four production seams (geom, timing table, collector,
_rows_to_chat) must be behavior-identical — one full manual session on A vs B, chat text /
dividers / streamed reply content byte-identical.

## Workstream 2 — service layer  `refactor/service-layer`  *(after WS1)*

**Goal:** dependency arrows point downward. A new `obelus/review.lua` owns chat/dispatch
semantics (do_respond, busy, submit routing, chat_save/chat_send, resolve/reopen/cancel);
init.lua shrinks to setup + thin re-exports; nav/project helpers absorb the duplicated
jump/root/buf-lookup code; transports stop requiring obelus.render directly (they call
review-layer completion hooks that own the repaint).

Also: collapse init.lua's ten copies of the comment-lookup guard into a `with_comment` wrapper
(keeping the two intentionally-divergent nil-handling sites out of it: open_chat falls back to
the list, chat_send is a silent no-op); rename the local `resolve()` that collides with
`M.resolve`; unify M.jump / M.jump_to (orphan warning stays in M.jump only; float-close stays
out of jump_to).

**Constraints from verification:** keep `reply_here`, `batch_advance`, `busy` public (users
bind them with `keys = false`); keep `M.resolve`'s public name (panel calls it); keep the moved
functions' panel/transport requires lazy (top-level requires would create real load cycles).
**A/B:** pure code motion — anything visually different is a bug. The failure mode is a missed
render_all relocation = STALE UI: after each transport completes, check signs/bands/panel
repaint; check tag/resolve/reopen/delete repaint from both keymaps and panel maps. tests stay
green with zero spec edits beyond requires.

## Workstream 3 — stream lifecycle  `refactor/stream-lifecycle`  *(after WS2)*

**Goal:** "a reply is in flight" has exactly one owner. A store-side stream state machine
(pending → streaming → idle, **set synchronously before async dispatch** — the pre-fill
`state.streaming` bridge exists for popup sizing and must not become an async event), targeting
the streamed turn **by handle** instead of tail position; an `obelus/jobs.lua` registry
(is_running / busy-with-self-heal / cancel) that **records which transport owns each job**
(provenance — a name-routed registry with a no-op default was rejected: it insta-heals live
flags); cli spawn failures (pcall around vim.system) roll back fully; runtime flags never
persist; store saves debounced with a VimLeavePre flush.

Fixes bundled here: draft-save-mid-stream corruption (turn-handle fix — do NOT busy-guard
chat_save, that silently destroys drafts), delete/clear orphaning a live subprocess (kill it;
batch members share one process — consistent with M.cancel semantics), thread.lua's requires on
transport.cli/progress (pure formatter gets `opts.live`/spinner frame from callers via jobs).

**A/B checklist:** (1) send → spinner appears immediately, animates until first delta; (2) popup
must NOT inflate-then-shrink at send; (3) on finish exactly one markview re-render, seated;
(4) typo the cli cmd → clean notify, no wedged "agent is still replying", spinner stops,
comments NOT deleted; (5) draft typed mid-stream survives `q` and `:q`, agent reply lands in
the agent turn; (6) `dd` a dispatching comment kills the subprocess; (7) `persist.auto=false`
writes zero files even on cancel/heal; (8) `:wq` right after a mutation still persists;
(9) file/quickfix/sidekick transports and batch jobs never strand in "pending"; (10) inline
band reply_anchor offset stays in sync with the drawn band (opts.live consistency).

## Workstream 4 — agent write-back  `fix/agent-writeback`  *(after WS3)*

**Goal:** the write-back protocol survives concurrency and garbage. Per-job
`.ai/review-actions-<id>.json` (docs/batch-conversations.md §4b already prescribes this; the id
is per-BATCH, not per-round — resumed sessions remember the round-1 path; batch.lua:136's
hardcoded path + docs move in sync; sweep stale files from crashed runs). Type-validate action
entries with a user-visible notify on decode failure (on bad `a.line`, SKIP the move — don't
clamp to 1; scope comment_id to batch membership but allow `reopen`). Commit batch
round+snapshot only after transport.submit reports success (prefer submit-returns-ok over
exit-callback snapshotting, which bakes in agent-resolved statuses). Batch membership owned
solely by `batch.comment_ids` — drop the write-only, dangling, persisted `c.batch_id`.

Per verification: do NOT collapse `batch.mode`/`batch.prompt` or delete `object` (documented
Phase 2/3 anchors) — add a "not yet implemented" warn for `object` instead.

**A/B (behavioral):** two concurrent dispatches → BOTH threads get their reply/resolve (on main
the loser is clobbered); hand-write garbage JSON → notify appears, thread still renders; fail a
batch continue (missing binary) → the next successful round still conveys replies/resolutions.

## Workstream 5 — structured rows  `refactor/structured-rows`  *(after WS1 + WS3)*

**Goal:** thread.build returns structured rows (`{kind, author, per-chunk role, chunks}`) with
two thin serializers (virt_lines band; panel real-text+decos), killing panel's 35-line
hl-name-sniffing loop — the implicit contract where the divider-corruption bug lived.
thread.lua becomes a pure fast formatter: no transport/progress requires, body_rows/turn_header
extracted from the 180-line build loop, incremental-width wrap() (currently O(len²) with a
vim.fn call per word), bounded per-turn ts_chunks memoization (preserve last-capture-wins
overlap semantics; key per-turn with tail invalidation or streaming leaks; don't cache nil
parser failures).

Per verification: keep markview_harmonize per-render (once-caching races markview's own
ColorScheme lifecycle) — shield it behind WS6's preview throttle instead.

**A/B: HIGHEST visual-regression surface — eyeball hardest.** All three surfaces (inline band,
rooted popup band, chat panel) × all renderers (markview/treesitter/builtin) × streaming vs
settled. Watch: divider glyphs (─ before turn 1, ┄ between turns; trailing rule silently
dropped in read-only bands — preserve the pending_rule carry); you/agent bar colors +
statuscolumn bars; the #tag header chunk stays DROPPED in markview mode (panel.lua:399 today);
code-block token colors; wrap points (cosmetic 1-cell shifts only on combining-char edges);
cap_rows "⋯ N above/below" + reply_anchor offsets (serialize before cap_rows); spinner row
animates during dispatch; transparent theme keeps bgs UNSET. The stream-state helper must
reproduce the exact `id == state.thread` qualifier or hover previews of other threads degrade
during an unrelated stream. Update WS1's thread/rows_to_chat specs deliberately, not loosened.

## Workstream 6 — panel hot path  `perf/panel-hotpath`  *(after WS1 + WS5)*

**Goal:** fill()/fill_preview stop paying full rebuild costs at 10 Hz, and fill() becomes a
readable staged orchestrator. fill_preview gains fill()'s coalesce/throttle + a
cancel-and-reschedule re-fit (the 180 ms defer CANNOT be deleted — no events reach a
non-focusable float; and the preview must still SHRINK for shorter threads — modal
never-shrink stays modal-only; the two fit strategies are opposite on purpose, do NOT unify).
Cache mv_render_cfg (fresh deepcopy per token, not per render). fit_rooted takes the pass kind
as a parameter — it must be `force` (hard OR _forcefill), not bare `hard`, or stream-finish
stops shrinking the float. Keep `scroll_once` ambient (open_thread and `<C-s>` save deliver
fills via render_all with no direct call site). Extract preview/modal shared helpers along
verified seams (title/width formulas, the `74` fallback, seat sequence); consolidate winopts
for BOTH list and chat modes; input keeps conceallevel=0. Name and document the three
follow/seated predicates — do NOT unify them (botline-only regresses
cursor-in-history-stops-autoscroll). Delete debug_geom (superseded by WS1's panel.geom()).
Stretch (L): incremental buffer patch — diff by common prefix, full rebuild on any prefix
change (mid-stream resize rewraps everything; the dispatching flip unhides the draft turn
above), prune bar_maps in the changed suffix.

**Explicitly out of scope (rejected by verification):** the reply-box-as-real-window redesign
and a literal 4-module panel split (the proposed seams cut live data flow) — extract helpers,
leave the module whole.

**A/B under streaming, transparent Ghostty, sidebar AND popup:** spinner keeps animating
pre-delta (the content signature stays — a revision-counter sig freezes it); scroll input
responsive during a 300-line stream; over-scroll re-glues the box; hover preview of a
dispatching comment updates ~6/s without flicker, reopen-after-hide not blank (bufhidden=wipe
invalidates the sig), no bottom gap; popup never jitters (synchronous redraw-before-zb stays);
`<C-s>` still reseats; first-open box position correct; a cursor parked in visible history of a
short thread must NOT teleport on deltas.

## Workstream 7 — config surface  `refactor/config-surface`  *(after WS1; parallel with 2–6)*

**Goal:** config validated, single-sourced, separated from session state. Enum validation with
warnings at setup (path/value/allowed-set, warn once, then default). Merge `render.thread` into
`render.bands` with a migration shim. Resolve or-literal default drift against config.defaults —
this DELIBERATELY changes behavior: `bands = false` actually disables bands (today it silently
keeps them on), band_style fallback aligns to the declared "popup" default, tint drift resolves
to 0.08 (slightly stronger bubbles on opaque themes only). Runtime toggles move to an
override-local `ui_state` **in the config module** (cycle-free; sentinel distinguishes
"explicitly auto" from "never toggled") so re-running setup() never reverts session toggles.
`render.markview` migrates with one `vim.notify_once`; `renderer` wins when both set. Keymaps
driven from a per-action spec table (the x-mode comment map MUST stay a `:<C-u>lua` string rhs —
visual marks; keys=false stays exempt; whichkey keeps live toggle icons; README table gains the
missing oj/oz/oJ/oK/od/<A-d>/<A-u> rows). LuaCATS annotations + a README API section.

Skipped per verification: the full top-level `render` restructure (colors/bar/transparent are
cross-surface, not chat-only). Update tests/panel_spec.lua:16–26 (asserts set_renderer writes
config.options).

**A/B:** typo'd `renderer`/`engage` warns once then defaults; `engage="side"` no longer
produces the sidebar-bands-but-inline-reply chimera; :ObelusRenderer/:ObelusMode/band-style
survive re-setup; render.thread user settings honored via shim; markview=false → one notice +
builtin rendering; normalized false table-options yield all-off (not re-enabled defaults).

---

## Ordering rationale & sizes

Specs first (WS1) so every later branch A/Bs against executable invariants, not just the eye.
Module extraction (WS2) before logic rewrites so WS3 builds jobs.lua/stream-state in their
final home. WS3 before WS4 (agent-writeback edits the same cli exit paths WS3 restructures).
WS5 before WS6 (the fill() split is cleaner once the hl-sniffing splitter is gone). WS7 only
needs WS1 and can run in a second worktree in parallel.

Sizes: WS0 ~1 day of small items · WS1 L (mostly test code) · WS2 M · WS3 L · WS4 M · WS5 L ·
WS6 L · WS7 M.

## Rejected approaches (do not re-litigate without new evidence)

1. Reply-box-as-real-window redesign — breaks reply_dock="serial" + pinned float-bubble modes.
2. Literal 4-module panel split — proposed seams cut live data flow; extract helpers instead.
3. Store-changed event bus — would full-repaint per streamed chunk; WS2's layering discipline
   covers it (transports call review-layer hooks that own the repaint).
4. Revision-counter fill signature — freezes the baked-in thinking spinner; only the throttle
   hoist ships.
5. Single deferred markview settle pass — regresses the modal's deterministic one-frame seat.
6. Follow-predicate unification on botline — regresses cursor-in-history-stops-autoscroll.
7. Name-routed transport registry with no-op default — lacks provenance, insta-heals live
   flags; jobs.lua records the owning transport per job.
8. Top-level config restructure by surface — mislabels cross-surface styling as chat-only.
9. Collapsing batch.mode/prompt, deleting batch.object — documented Phase 2/3 anchors.
10. Caching markview_harmonize once-per-colorscheme — races markview's own ColorScheme
    lifecycle; keep per-render behind the preview throttle.
11. Replacing the pre-fill state.streaming bridge with async registry events — the synchronous
    set exists for popup sizing at send time; WS3 keeps a synchronous "pending" set.

## Locked design decisions (respected throughout)

Detached markview stays (WS5/WS6 only cache/parameterize around it) · transparent-theme bgs
stay unset, now pinned by a spec (WS1) · the reply divider stays a virt_line (structured rows
keep it as a deco, never buffer text) · the WinScrolled clamp mechanism stays (only its
registration scope moves) · streaming renders plain in-house text (the stream state machine
feeds the same predicate).
