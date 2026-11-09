# Guard mutations

These mutations show that the harness is sensitive. `sh tests/ui/mutations.sh`
copies `lua/` and `tests/` to a private temp dir, applies one small mutation at a
time to the copy and runs the harness there. Every mutation must make the harness
fail. The real tree is never modified.

Last run: 2026-11-08, Neovim v0.12.6, baselines at this branch's HEAD.

| Mutation | Change in the copy | Result |
| --- | --- | --- |
| band-highlight-group | `render.lua`: linewise band `line_hl_group` `ObelusThreadBg` → `ObelusThreadBar` | caught: 36 snapshots |
| virt-text-column | `config.lua`: eol preview prefix `"  ▌ "` → `"   ▌ "` (virt_text shifts one column) | caught: 2 snapshots |
| spinner-frame | `progress.lua`: spinner frame 2 `⠙` → `⠚` | caught: 8 snapshots |
| panel-width | `panel.lua`: sidebar width `columns * 0.42` → `* 0.43` | caught: 4 snapshots |
| markdown-bold-conceal | `thread.lua`: `**bold**` keeps its markers (no conceal) | caught: 24 snapshots |
| band-hint-string | `render.lua`: band hint `K up · J down` → `K up \| J down` | caught: 2 snapshots |
| composer-footer-label | `render.lua`: composer footer `save` → `store` | caught: 2 snapshots |
| bubble-tint-colour | `config.lua`: `colors.tint` 0.08 → 0.09 (colours only, no layout change) | caught: 39 snapshots |
| spinner-priority-extmark-only | `progress.lua`: inline spinner extmark priority 4500 → 4400 (invisible on screen) | caught: 8 snapshots |
| keymap-desc | `init.lua`: `<prefix>?` keymap desc text | caught: 1 snapshot (registration) |

Result: 10 caught, 0 missed. The suite took 53 s under `nice -n 10`.

The first attempt at bubble-tint-colour changed the `or 0.08` fallback in
`thread.lua`. That fallback is dead code, because `config.defaults` always sets
`colors.tint`, so the run reported the mutation as missed. The mutation now targets
the config default. The miss came from the mutation, not from a gap in the harness.
