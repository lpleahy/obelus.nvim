.PHONY: test specs ui-snapshots ui-snapshots-update lint fmt

# Run the headless specs, then the UI snapshot harness.
test: specs ui-snapshots

# The behaviour specs. Set OBELUS_TEST_RTP to also run the markview specs, e.g.
#   OBELUS_TEST_RTP=/path/to/markview.nvim:/path/to/nvim-treesitter make test
specs:
	@nvim --headless -u NONE -i NONE -c "luafile tests/run.lua"

# Byte-identical UI snapshots (screen grid + extmarks + highlights) at 80x24 and
# 160x45 — see tests/ui/README.md. ~5s; part of `make test`.
ui-snapshots:
	@sh tests/ui/run.sh

# Re-record every baseline (review the diff before committing!).
ui-snapshots-update:
	@OBELUS_UI_UPDATE=1 sh tests/ui/run.sh

# Check formatting (StyLua) without writing.
lint:
	@stylua --check lua/ tests/

# Apply formatting.
fmt:
	@stylua lua/ tests/
