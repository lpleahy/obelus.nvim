.PHONY: test specs ui-snapshots ui-snapshots-update ui-selftest ui-mutations lint fmt

# Containment: every test target runs through tests/private.sh, which creates a
# private root (mktemp), points XDG_{CONFIG,DATA,STATE,CACHE}_HOME and TMPDIR into
# it, and removes it by exact path afterwards. The scripts and the nvim side
# (tests/xdg_guard.sh, tests/xdg_guard.lua) refuse to run outside such a root.

# Run the headless specs, then the UI snapshot harness — in that order even under
# `make -j` (the snapshot run is a recipe step, not a parallel prerequisite).
test: specs
	@$(MAKE) --no-print-directory ui-snapshots

# The behaviour specs. Set OBELUS_TEST_RTP to also run the markview specs, e.g.
#   OBELUS_TEST_RTP=/path/to/markview.nvim:/path/to/nvim-treesitter make test
specs:
	@sh tests/private.sh sh tests/specs.sh

# Byte-identical UI snapshots (screen grid + extmarks + highlights) at 80x24 and
# 160x45 — see tests/ui/README.md. ~2s; part of `make test`.
ui-snapshots:
	@sh tests/private.sh sh tests/ui/run.sh

# Re-record every baseline (review the diff before committing!).
ui-snapshots-update:
	@OBELUS_UI_UPDATE=1 sh tests/private.sh sh tests/ui/run.sh

# Harness self-tests: forced RPC timeout, scenario error, SIGTERM/SIGKILL mid-run,
# parent exiting first with a live child (no child or temp dir may survive), no
# perl on PATH, and a 2.5 s injected stall (snapshots must not change). ~1 min.
# The harness needs perl (core POSIX, Time::HiRes) — see tests/ui/README.md.
ui-selftest:
	@sh tests/private.sh sh tests/ui/selftest.sh

# Guard mutations: each one-line visual/setup mutation must fail the harness, and
# removing the supervisor's member teardown must fail the self-tests. ~2.5 min.
ui-mutations:
	@sh tests/private.sh sh tests/ui/mutations.sh

# Check formatting (StyLua) without writing.
lint:
	@stylua --check lua/ tests/

# Apply formatting.
fmt:
	@stylua lua/ tests/
