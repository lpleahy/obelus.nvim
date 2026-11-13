-- Pure geometry for the opt-in margin: active-pivot placement, lanes and glyphs.
-- Coordinates are display cells; emitted highlight spans are UTF-8 byte offsets.
local M = {}
local function extend(out, items)
  for _, item in ipairs(items) do
    out[#out + 1] = item
  end
  return out
end

-- stack_down: items (ordered nearest-pivot first) each { id, d = desired top, h }; region [lo, hi].
-- Keeps the longest prefix that fits tightly packed; places each at >= desired order bound,
-- then a backward pass shifts cards UP (never above lo) so the kept ones end inside hi.
local function stack_down(seq, lo, hi, gap)
  local placed, dropped = {}, {}
  if hi < lo then
    for _, it in ipairs(seq) do
      dropped[#dropped + 1] = it.id
    end
    return placed, dropped
  end
  local used, k = 0, 0
  for i, it in ipairs(seq) do
    local need = used + it.h + (i > 1 and gap or 0)
    if need > hi - lo + 1 then
      break
    end
    used, k = need, i
  end
  for i = k + 1, #seq do
    dropped[#dropped + 1] = seq[i].id
  end
  local tops, bound = {}, lo
  for i = 1, k do
    tops[i] = math.max(seq[i].d, bound)
    bound = tops[i] + seq[i].h + gap
  end
  local limit = hi
  for i = k, 1, -1 do
    tops[i] = math.min(tops[i], limit - seq[i].h + 1)
    limit = tops[i] - gap - 1
  end
  for i = 1, k do
    placed[#placed + 1] = { id = seq[i].id, top = tops[i], h = seq[i].h }
  end
  return placed, dropped
end

-- stack_up: mirror of stack_down (items ordered nearest-pivot first = reverse doc order)
local function stack_up(seq, lo, hi, gap)
  local m = lo + hi
  local mir = {}
  for i, it in ipairs(seq) do
    mir[i] = { id = it.id, d = m - (it.d + it.h - 1), h = it.h }
  end
  local placed, dropped = stack_down(mir, lo, hi, gap)
  for _, p in ipairs(placed) do
    p.top = m - (p.top + p.h - 1)
  end
  return placed, dropped
end

function M.place(items, opts)
  local rows, gap, active = opts.rows, opts.gap or 1, opts.active
  local vis, above, below = {}, {}, {}
  for _, it in ipairs(items) do
    if it.row then
      vis[#vis + 1] = it
    elseif it.side == "above" then
      above[#above + 1] = it.id
    else
      below[#below + 1] = it.id
    end
  end
  table.sort(vis, function(a, b)
    return a.order < b.order
  end)
  local res_top, res_bot = #above > 0, #below > 0
  local result
  for _ = 1, 3 do
    local lo, hi = res_top and 2 or 1, res_bot and rows - 1 or rows
    local cards, drop_up, drop_down = {}, {}, {}
    local ai
    for i, it in ipairs(vis) do
      if it.id == active then
        ai = i
      end
    end
    local function d(it)
      return math.max(lo, math.min(it.row, hi))
    end
    if ai then
      local a = vis[ai]
      local top = math.max(lo, math.min(a.row, hi - a.h + 1))
      cards[#cards + 1] = { id = a.id, top = top, h = a.h }
      local up = {}
      for i = ai - 1, 1, -1 do
        up[#up + 1] = { id = vis[i].id, d = d(vis[i]), h = vis[i].h }
      end
      local pu, du = stack_up(up, lo, top - gap - 1, gap)
      local down = {}
      for i = ai + 1, #vis do
        down[#down + 1] = { id = vis[i].id, d = d(vis[i]), h = vis[i].h }
      end
      local pd, dd = stack_down(down, top + a.h + gap, hi, gap)
      extend(cards, pu)
      extend(cards, pd)
      drop_up, drop_down = du, dd
    else
      local seq = {}
      for _, it in ipairs(vis) do
        seq[#seq + 1] = { id = it.id, d = d(it), h = it.h }
      end
      local pd, dd = stack_down(seq, lo, hi, gap)
      cards, drop_down = pd, dd
    end
    result = {
      cards = {},
      lo = lo,
      hi = hi,
      above = extend(extend({}, above), drop_up),
      below = extend(extend({}, below), drop_down),
    }
    for _, c in ipairs(cards) do
      result.cards[c.id] = { top = c.top, h = c.h }
    end
    local need_top, need_bot = #result.above > 0, #result.below > 0
    if need_top == res_top and need_bot == res_bot then
      break
    end
    res_top, res_bot = res_top or need_top, res_bot or need_bot
  end
  result.top_indicator = #result.above > 0 and 1 or nil
  result.bottom_indicator = #result.below > 0 and rows or nil
  return result
end

-- lanes: conflict-aware. Each connector occupies cells: V (its lane column, rows s..e), HA (anchor
-- row, cols 1..x), HT (card row, cols x..W-1). A lane is valid when none of its cells collide with an
-- already-placed connector's cells, except HA/HA on the same anchor row (a shared "bus").
-- Order: up group by start asc, then down group by end desc (nearest-pivot = outermost).
function M.lanes(items, placement, lane_max)
  local W = lane_max + 2
  local up, down, lanes, shared = {}, {}, {}, false
  for _, it in ipairs(items) do
    local c = it.row and placement.cards[it.id]
    if c and c.top ~= it.row then
      local iv = { id = it.id, a = it.row, t = c.top, s = math.min(it.row, c.top), e = math.max(it.row, c.top) }
      if c.top < it.row then
        up[#up + 1] = iv
      else
        down[#down + 1] = iv
      end
    end
  end
  table.sort(up, function(p, q)
    if p.s ~= q.s then
      return p.s < q.s
    end
    return p.e < q.e
  end)
  table.sort(down, function(p, q)
    if p.e ~= q.e then
      return p.e > q.e
    end
    return p.s > q.s
  end)
  local occ = {} -- occ[r][c] = { kind, row }
  -- straight connectors occupy their whole row as HA (bus-compatible with other anchors on that row)
  for _, it in ipairs(items) do
    local c = it.row and placement.cards[it.id]
    if c and c.top == it.row then
      occ[it.row] = occ[it.row] or {}
      for col = 1, W - 1 do
        occ[it.row][col] = { kind = "HA" }
      end
    end
  end
  local function cells(iv, x)
    local out = {}
    for r = iv.s, iv.e do
      out[#out + 1] = { r, x, (r == iv.a) and "VA" or "V" }
    end -- VA: the corner on its own anchor row
    for col = 1, x - 1 do
      out[#out + 1] = { iv.a, col, "HA" }
    end
    for col = x + 1, W - 1 do
      out[#out + 1] = { iv.t, col, "HT" }
    end
    return out
  end
  -- cost per colliding cell: V on V (two verticals merged = ambiguous) 100, a horizontal riding
  -- another horizontal 10, a plain crossing (V through a horizontal = ┼) 1. HA on HA (bus) = 0.
  local function conflicts(iv, x)
    local n = 0
    for _, cl in ipairs(cells(iv, x)) do
      local o = occ[cl[1]] and occ[cl[1]][cl[2]]
      -- bus: anchors on one row share the ◀ run, and a corner on its own anchor row may sit on that run
      local bus = o and o.kind == "HA" and (cl[3] == "HA" or cl[3] == "VA")
      if cl[3] == "VA" then
        cl[3] = "V"
      end
      if o and not bus then
        if o.kind == "V" and cl[3] == "V" then
          n = n + 100
        elseif o.kind ~= "V" and cl[3] ~= "V" then
          n = n + 10
        else
          n = n + 1
        end
      end
    end
    return n
  end
  local n = 0
  for _, group in ipairs({ up, down }) do
    for _, iv in ipairs(group) do
      local pick, best
      for x = 1, lane_max do
        local k = conflicts(iv, x)
        if k == 0 then
          pick = x
          break
        end
        if not best or k < best.k then
          best = { x = x, k = k }
        end
      end
      if not pick then
        pick, shared = best.x, true
      end
      for _, cl in ipairs(cells(iv, pick)) do
        occ[cl[1]] = occ[cl[1]] or {}
        occ[cl[1]][cl[2]] = occ[cl[1]][cl[2]] or { kind = (cl[3] == "VA") and "V" or cl[3] }
      end
      lanes[iv.id] = pick
      n = math.max(n, pick)
    end
  end
  return lanes, n, shared
end

-- draw: lane area = col 0 (arrow), cols 1..lane_max (lanes), col lane_max+1 (port). Direction-set merge.
local U, D, L, R = 1, 2, 4, 8
local GLYPH = {
  [L + R] = "─",
  [L] = "─",
  [R] = "─",
  [U + D] = "│",
  [U] = "│",
  [D] = "│",
  [D + R] = "┌",
  [D + L] = "┐",
  [U + R] = "└",
  [U + L] = "┘",
  [U + D + R] = "├",
  [U + D + L] = "┤",
  [L + R + D] = "┬",
  [L + R + U] = "┴",
  [U + D + L + R] = "┼",
}
function M.draw(items, placement, lanes, opts)
  local rows, lmax, active = opts.rows, opts.lane_max, opts.active
  local W = lmax + 2
  local cell = {} -- cell[r][c] = { bits, active }
  local function add(r, c, bits, act)
    cell[r] = cell[r] or {}
    local x = cell[r][c] or { bits = 0, active = false }
    x.bits = bit.bor(x.bits, bits)
    x.active = x.active or act
    cell[r][c] = x
  end
  local arrows = {}
  for _, it in ipairs(items) do
    local c = it.row and placement.cards[it.id]
    if c then
      local act = it.id == active
      local a, t = it.row, c.top
      arrows[a] = arrows[a] or { act = false }
      arrows[a].act = arrows[a].act or act
      if a == t then
        for col = 1, W - 1 do
          add(a, col, L + R, act)
        end
      else
        local x = lanes[it.id]
        for col = 1, x - 1 do
          add(a, col, L + R, act)
        end
        add(a, x, L + (t > a and D or U), act)
        for r = math.min(a, t) + 1, math.max(a, t) - 1 do
          add(r, x, U + D, act)
        end
        add(t, x, R + (t > a and U or D), act)
        for col = x + 1, W - 1 do
          add(t, col, L + R, act)
        end
      end
    end
  end
  local out = {}
  for r = 1, rows do
    local parts, spans, off = {}, {}, 0
    for col = 0, W - 1 do
      local ch, act, owned = " ", false, false
      if col == 0 and arrows[r] then
        ch, act, owned = (arrows[r].act and opts.leader_row == r) and "─" or "◀", arrows[r].act, true
      elseif cell[r] and cell[r][col] then
        local x = cell[r][col]
        ch, act, owned = GLYPH[x.bits] or "?", x.active, true
      end
      parts[#parts + 1] = ch
      if owned then
        spans[#spans + 1] = { off, off + #ch, act and "ObelusMarginActive" or "ObelusMarginConnector" }
      end
      off = off + #ch
    end
    out[r] = { text = table.concat(parts), spans = spans }
  end
  return out
end
return M
