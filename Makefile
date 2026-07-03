.PHONY: test lint fmt

# Run the headless test suite. Set OBELUS_TEST_RTP to also run the markview specs, e.g.
#   OBELUS_TEST_RTP=/path/to/markview.nvim:/path/to/nvim-treesitter make test
test:
	@nvim --headless -u NONE -i NONE -c "luafile tests/run.lua"

# Check formatting (StyLua) without writing.
lint:
	@stylua --check lua/ tests/

# Apply formatting.
fmt:
	@stylua lua/ tests/
