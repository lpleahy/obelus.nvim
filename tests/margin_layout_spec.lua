-- margin_layout: the margin's pure placement (M.place, through the private
-- stack_down / stack_up). Table-driven: each case is the items, the options
-- and the exact result M.place returns today. Rows are 1-based screen rows.
T.describe("margin_layout")

local L = require("obelus.margin_layout")

-- the parts of a placement a case pins
local function shape(r)
  return {
    cards = r.cards,
    above = r.above,
    below = r.below,
    lo = r.lo,
    hi = r.hi,
    top_indicator = r.top_indicator,
    bottom_indicator = r.bottom_indicator,
  }
end

local cases = {
  {
    name = "empty input places nothing and shows no indicator",
    items = {},
    opts = { rows = 10 },
    want = { cards = {}, above = {}, below = {}, lo = 1, hi = 10 },
  },
  {
    name = "one active card sits at its row",
    items = { { id = "a", row = 5, h = 3, order = 1 } },
    opts = { rows = 10, active = "a" },
    want = { cards = { a = { top = 5, h = 3 } }, above = {}, below = {}, lo = 1, hi = 10 },
  },
  {
    name = "an active card near the bottom is pulled up to fit",
    items = { { id = "a", row = 9, h = 4, order = 1 } },
    opts = { rows = 10, active = "a" },
    want = { cards = { a = { top = 7, h = 4 } }, above = {}, below = {}, lo = 1, hi = 10 },
  },
  {
    name = "overlap: two cards wanting the same row stack down with the gap",
    items = { { id = "a", row = 3, h = 3, order = 1 }, { id = "b", row = 3, h = 3, order = 2 } },
    opts = { rows = 20 },
    want = { cards = { a = { top = 3, h = 3 }, b = { top = 7, h = 3 } }, above = {}, below = {}, lo = 1, hi = 20 },
  },
  {
    name = "overlap with a wider gap",
    items = { { id = "a", row = 3, h = 3, order = 1 }, { id = "b", row = 3, h = 3, order = 2 } },
    opts = { rows = 20, gap = 2 },
    want = { cards = { a = { top = 3, h = 3 }, b = { top = 8, h = 3 } }, above = {}, below = {}, lo = 1, hi = 20 },
  },
  {
    name = "ordering: cards stack by their order, not by input order",
    items = { { id = "b", row = 3, h = 2, order = 2 }, { id = "a", row = 3, h = 2, order = 1 } },
    opts = { rows = 10 },
    want = { cards = { a = { top = 3, h = 2 }, b = { top = 6, h = 2 } }, above = {}, below = {}, lo = 1, hi = 10 },
  },
  {
    name = "near the bottom, the backward pass shifts the kept cards up to end inside the region",
    items = { { id = "a", row = 8, h = 3, order = 1 }, { id = "b", row = 9, h = 3, order = 2 } },
    opts = { rows = 12 },
    want = { cards = { a = { top = 6, h = 3 }, b = { top = 10, h = 3 } }, above = {}, below = {}, lo = 1, hi = 12 },
  },
  {
    name = "a region too small for all cards keeps the first and counts the rest below",
    items = {
      { id = "a", row = 1, h = 3, order = 1 },
      { id = "b", row = 2, h = 3, order = 2 },
      { id = "c", row = 3, h = 3, order = 3 },
    },
    opts = { rows = 6 },
    want = {
      cards = { a = { top = 1, h = 3 } },
      above = {},
      below = { "b", "c" },
      lo = 1,
      hi = 5,
      bottom_indicator = 6,
    },
  },
  {
    name = "a card taller than the whole region is dropped",
    items = { { id = "a", row = 1, h = 12, order = 1 } },
    opts = { rows = 10 },
    want = { cards = {}, above = {}, below = { "a" }, lo = 1, hi = 9, bottom_indicator = 10 },
  },
  {
    name = "stack_up: cards above an active one stack upward, nearest first",
    items = {
      { id = "a", row = 2, h = 3, order = 1 },
      { id = "b", row = 4, h = 3, order = 2 },
      { id = "c", row = 10, h = 3, order = 3 },
    },
    opts = { rows = 20, active = "c" },
    want = {
      cards = { a = { top = 1, h = 3 }, b = { top = 5, h = 3 }, c = { top = 10, h = 3 } },
      above = {},
      below = {},
      lo = 1,
      hi = 20,
    },
  },
  {
    name = "stack_up drops what does not fit above the active card, nearest kept",
    items = {
      { id = "a", row = 1, h = 3, order = 1 },
      { id = "b", row = 3, h = 3, order = 2 },
      { id = "c", row = 6, h = 3, order = 3 },
    },
    opts = { rows = 12, active = "c" },
    want = {
      cards = { b = { top = 2, h = 3 }, c = { top = 6, h = 3 } },
      above = { "a" },
      below = {},
      lo = 2,
      hi = 12,
      top_indicator = 1,
    },
  },
  {
    name = "stack_down below an active card",
    items = {
      { id = "a", row = 3, h = 3, order = 1 },
      { id = "b", row = 3, h = 3, order = 2 },
      { id = "c", row = 4, h = 3, order = 3 },
    },
    opts = { rows = 20, active = "a" },
    want = {
      cards = { a = { top = 3, h = 3 }, b = { top = 7, h = 3 }, c = { top = 11, h = 3 } },
      above = {},
      below = {},
      lo = 1,
      hi = 20,
    },
  },
  {
    name = "off-screen threads go to the indicators by side, reserving their rows",
    items = {
      { id = "x", side = "above" },
      { id = "z", side = "below" },
      { id = "y", row = 5, h = 2, order = 1 },
    },
    opts = { rows = 10 },
    want = {
      cards = { y = { top = 5, h = 2 } },
      above = { "x" },
      below = { "z" },
      lo = 2,
      hi = 9,
      top_indicator = 1,
      bottom_indicator = 10,
    },
  },
}

for _, c in ipairs(cases) do
  T.it(c.name, function()
    T.eq(shape(L.place(vim.deepcopy(c.items), c.opts)), c.want)
  end)
end
