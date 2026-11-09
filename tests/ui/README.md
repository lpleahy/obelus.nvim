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

`registration` pins the setup path instead of a screen. It records the editor state
before obelus loads and after `setup()` plus opening a file, then diffs the two:
user commands, keymaps (every mode, global and buffer-local, Neovim's defaults
included), autocmds (every group and ungrouped), highlight groups and namespaces.
Each Lua callback is labelled by its source file plus a fingerprint: a hash of its
source text and of the functions it closes over, three levels deep. The
fingerprint survives line shifts and stays the same across processes, but changes
when the callback body is swapped under an unchanged description. Editing a
comment or the formatting inside a callback also changes it; that is metadata
churn, not rendered drift. It is a source fingerprint, not a full behaviour
identity; see "Known limits" below. User-command callbacks are recorded when the command is
created. So setup adding, changing or removing any of these fails the snapshot. The
full after-setup tables of commands, keymaps and autocmds follow the diff.

Every visual snapshot also diffs the global registry against its state right after
setup. This catches mappings, commands, autocmds and highlights that obelus
installs or overwrites on first use, for example when opening a chat or a
composer.

Scenarios are in `scenarios.lua`. Each runs at 80x24 and 160x45; `registration`
runs once. They use synthetic fixtures and the fake transport (`tests/fake.lua`)
only: no agents and no network.

## Run

```sh
make ui-snapshots          # compare (also part of `make test`, about 2 s)
OBELUS_UI_ONLY=band,chat make ui-snapshots    # only scenarios whose name contains "band" or "chat"
```

`make test` runs the specs first, then the snapshots, even under `make -j`. The
specs report executed and skipped counts separately. With a private XDG setup the
21 markview and render-markdown specs are skipped (458 passed, 21 skipped). They run
only when those plugins are on the runtimepath.

The harness reports two kinds of problem. `FAIL` means a rendering differs from its
baseline. `ERROR` means it could not produce or compare a rendering: a scenario
raised an error, the child stopped responding, a baseline is missing or the Neovim
version differs. After a transport fault the suite stops.

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

## Sensitivity and self-tests

- `make ui-mutations` (`tests/ui/mutations.sh`, about 2 min) first checks that the
  unmodified tree passes. If it doesn't, for example because the Neovim version is
  wrong, the script stops and reports an invalid environment. It then applies 18
  small mutations to a temp copy, covering visuals, extmarks, float stacking and
  setup. A mutation counts as caught only on a baseline mismatch with no harness
  error. See `MUTATIONS.md` for the last results.
- `make ui-selftest` (`tests/ui/selftest.sh`, about 1 min) checks the harness
  itself:
  - a forced RPC timeout, a scenario error, SIGTERM mid-run, SIGKILL of the
    supervisor mid-run and SIGKILL of the supervisor before the parent's Lua
    starts each leave no live child and no temp dir;
  - a TERM that arrives after the parent has exited and been reaped signals
    nothing;
  - an unrelated `nvim --embed`, whose pid is injected into every pid record the
    harness writes, survives all of the above. The self-test itself only
    observes, with `ps` and files.
  - a 2.5 s wall-clock stall between arranging and capturing leaves the
    progress, stream and popup snapshots byte-identical.

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
- Captures never depend on the wall clock. In the child, `vim.uv.new_timer`
  (and so `vim.defer_fn`), `vim.schedule` and `vim.uv.now` run on a virtual clock
  that only the harness moves:
  - `settle()` runs everything runnable at the current virtual time until nothing
    is left;
  - `advance(ms)` moves the clock forward.

  The spinner timer's first tick (frame 1 to frame 2) runs at virtual time 0, so
  every spinner shows `⠙`. The 2 s ✓ clear after a finish stays pending at capture
  however slow the host is. `progress_finish_cleared` advances the clock 2000 ms to
  pin the cleared state. The only real-time limit is the RPC deadlock guard
  (120 s; `OBELUS_UI_GUARD_MS`).

  The virtual clock covers only what today's scenarios use. It is not a full
  event-loop model. Limits:
  - Only `uv.new_timer()` method calls (`start`, `stop`, `close`, `again`, …),
    `vim.defer_fn`, `vim.schedule`/`schedule_wrap` and `uv.now()` are virtual. The
    functional API (`uv.timer_start(t, …)`) errors on a virtual timer. Timers
    created before the child boots stay real. `os.clock()` and `uv.hrtime()` still
    advance.
  - Ordering differs from the real loop in one case. A callback scheduled from a
    timer runs before the next due timer, whereas the real loop runs that timer
    first.
  - Virtual timer callbacks do not run in a fast-event context. A callback that
    would hit E5560 for a missing `schedule_wrap` succeeds here. The behaviour
    specs (`make specs`) still run on real timers and cover that.
- Process hygiene: no code path signals a pid number taken from a record, a
  shell variable or `ps`.
  - `run.sh` execs into `supervise.pl`. It forks the parent nvim into a new
    process group, which the parent's embedded children share, and it is the
    only thing that signals that group. It does so only while the group leader
    is its own unreaped child: an unreaped child, running or zombie, pins the
    group id, so it can't belong to anyone else.
  - Signals are blocked outside `sigsuspend`, so a leader that has exited is
    always reaped and noted before a handler can act. After that the supervisor
    signals nothing.
  - On INT or TERM the supervisor sends TERM to the group, waits a grace second,
    sends KILL, reaps, and removes the run dir by exact path.
  - `rpc.lua` ends each embedded child through the libuv handle it holds:
    `:qall!`, then SIGTERM, then SIGKILL, each awaited. libuv reaps only while
    its loop runs, so a child not yet reported as exited is still unreaped when
    it is signalled. `rpc.lua` errors if the child can't be reaped.
  - SIGKILL of the supervisor runs no handler. Before every capture the parent
    compares its parent pid with the supervisor pid it was given at launch, so
    this also works when the supervisor died before the parent's Lua started.
    Once orphaned, it stops (its current child is still reaped through the
    handle) and removes the run's dir by exact path. Until the current scenario
    ends, including a pending RPC guard, the parent and that child stay alive.

## Known limits

- Callback fingerprints:
  - callbacks without a readable source file (C functions, `loadstring` chunks
    with a fixed chunk name, missing files) all collapse to `#C` or `#nosrc`;
  - closures made by one factory and differing only in captured non-function
    data (strings, tables) share a fingerprint.

  Inside one process, replacing a pre-existing callback is still caught by
  identity. If such forms enter the protected API, give them explicit labels or
  behaviour tests.
- Window-targeted autocmds (e.g. `WinClosed`) are keyed by the target window's
  role (its buffer label and float or split), not its id. Two windows with the
  same role are indistinguishable.
- Process containment covers the parent nvim and its direct embedded children,
  i.e. the supervisor's process group. A descendant that double-forks and calls
  `setsid()` leaves the group and is not cleaned up. Today's synthetic scenarios
  spawn no such jobs: the fake transport runs no subprocess, and provider jobs
  are out of scope.

## How it works

`run.lua`, the parent, talks msgpack-RPC to `nvim --embed` over pipes
(`rpc.lua`) and attaches an rgb `ext_linegrid` + `ext_hlstate` UI. With a UI
attached the child composes floats into the grid. `screenstring()` and
`screenattr()` (`child.lua`) then return exactly what a terminal would show. The
parent resolves attr ids using the UI's `hl_attr_define` events. A parent
`jobstart({ rpc = true })` channel can't be used here: Neovim closes it on the
child's `redraw` notifications.

## Not covered

The following are excluded from the gate, not passing coverage. Add scenarios
before changing code on these paths:

- the `margin` module (only in a local preview copy, not on `main`);
- the markview and render-markdown renderers: third-party plugins kept out of the
  hermetic run. Only the builtin renderer is covered.
- light backgrounds and other colorschemes; only `default` dark is pinned;
- treesitter or syntax highlighting of the source buffer (fixtures have no filetype);
- `:ObelusJobs`, the review list and quickfix view, and the batch and tag
  meta-thread views;
- the sidebar thread list has one representative snapshot per size, not
  exhaustive coverage;
- future `obelus.api` surfaces (non-file backends, approve/deny). P1 must add
  their own behaviour tests and scenarios.
