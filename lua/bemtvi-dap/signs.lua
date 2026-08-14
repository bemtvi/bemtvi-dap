-- Gutter signs + the stopped-line highlight, painted into REAL editor buffers via
-- extmarks (not a view). Two namespaces keep the concerns independent: breakpoint
-- signs persist across stops, while the single stopped marker moves with execution.
--
-- The stopped line is a sign PLUS a `line_hl_group` mark — the core's full-width
-- line-background layer, painted under the text the way `'cursorline'` is. It used to
-- be drawn as a ranged `hl_group` spanning the line's text, on the belief that
-- `line_hl_group` was stored-but-unpainted; it is not, and the range form was worse in
-- three ways: it had to READ the line to compute an `end_col`, it stopped at the end of
-- the text instead of running to the window edge, and — being a char-range span — it
-- entered the winner-takes-cell resolution and LOST every cell a syntax span covered,
-- so the stopped line was tinted only in its uncoloured gaps.

local M = {}

local bp_ns, stopped_ns
local cfg
-- session_id -> { path, line }: every session's current stopped location. Multiple
-- concurrent sessions can each be stopped at once, so the stopped marker is keyed by
-- session and the whole set is repainted on any change (the stopped namespace is
-- cleared across all buffers, then each location re-marked).
local stopped_locs = {}

function M.setup(config)
  cfg = config
  bp_ns = bp_ns or btv.ns.create("bemtvi-dap-breakpoints")
  stopped_ns = stopped_ns or btv.ns.create("bemtvi-dap-stopped")
end

-- Absolute, symlink-naive normalization so a breakpoint path and a buffer name
-- compare equal regardless of how either was spelled.
local function abspath(p)
  if not p or p == "" then
    return p
  end
  return vim.fn.fnamemodify(p, ":p")
end
M.abspath = abspath

-- abspath -> bufnr for every named buffer. One pass over the buffer list, so a caller
-- repainting SEVERAL files (`render_all`, `render_stopped`) resolves them all for the
-- cost of one scan instead of re-walking every buffer per path.
function M.buf_index()
  local index = {}
  for _, b in ipairs(btv.buf.list()) do
    local name = btv.buf.name(b)
    if name and name ~= "" then
      index[abspath(name)] = b
    end
  end
  return index
end

-- The loaded buffer for `path`, or nil if the file isn't open (then it carries no
-- signs — they appear when it's next opened and breakpoints re-sync).
function M.path_bufnr(path)
  return M.buf_index()[abspath(path)]
end

local function variant(bp)
  if bp.logMessage then
    return cfg.log_point
  elseif bp.condition or bp.hitCondition then
    return cfg.breakpoint_condition
  elseif bp.rejected then
    return cfg.breakpoint_rejected
  end
  return cfg.breakpoint
end

-- Repaint every breakpoint sign for `path` (clears the file's breakpoint namespace
-- first). `bps` is the list of `{ line, condition?, logMessage?, rejected? }`; `bufnr`
-- is the file's buffer when the caller already resolved it (skipping the lookup).
--
-- A breakpoint past the end of the buffer (restored from the shada for a file that has
-- since shrunk) is KEPT in the store — the file may grow back, and the adapter decides
-- what it can verify — but there is no line to hang a sign on, so it paints nothing.
function M.render_breakpoints(path, bps, bufnr)
  bufnr = bufnr or M.path_bufnr(path)
  if not bufnr then
    return
  end
  btv.buf.clear_namespace(bufnr, bp_ns, 0, -1)
  local last = btv.buf.line_count(bufnr)
  for _, bp in ipairs(bps) do
    if bp.line >= 1 and bp.line <= last then
      local v = variant(bp)
      btv.buf.set_extmark(bufnr, bp_ns, bp.line - 1, 0, {
        sign_text = v.text,
        sign_hl_group = v.hl,
        priority = 20,
      })
    end
  end
end

-- Clear breakpoint signs on a single file (used when its last breakpoint is removed).
function M.clear_breakpoints(path)
  local bufnr = M.path_bufnr(path)
  if bufnr then
    btv.buf.clear_namespace(bufnr, bp_ns, 0, -1)
  end
end

-- Mark session `sid`'s stopped line: a `▶` sign + a full-width line background.
-- 1-based `line`. Replaces that session's previous marker and repaints
-- every session's markers.
function M.set_stopped(sid, path, line)
  stopped_locs[sid] = { path = path, line = line }
  M.render_stopped()
end

-- Clear the stopped marker(s): for one session (`sid` given) or all (`sid` nil), then
-- repaint whatever remains.
function M.clear_stopped(sid)
  if sid == nil then
    stopped_locs = {}
  else
    stopped_locs[sid] = nil
  end
  M.render_stopped()
end

-- Repaint every session's stopped marker: drop the marks we painted last time, then
-- re-mark each live location. Stepping repaints on every stop, so the sweep is kept to
-- the buffers actually carrying a marker (`marked`) rather than every open buffer — a
-- clear-all would cost one call per open buffer per step.
local marked = {} -- bufnr -> true: the buffers currently carrying a stopped marker

function M.render_stopped()
  for bufnr in pairs(marked) do
    -- The buffer may have been wiped since it was marked (`:bd` on the stopped file).
    if btv.buf.is_valid(bufnr) then
      btv.buf.clear_namespace(bufnr, stopped_ns, 0, -1)
    end
  end
  marked = {}
  if next(stopped_locs) == nil then
    return
  end
  local s = cfg.stopped
  local index = M.buf_index()
  for _, loc in pairs(stopped_locs) do
    local bufnr = index[abspath(loc.path)]
    if bufnr and loc.line >= 1 and loc.line <= btv.buf.line_count(bufnr) then
      btv.buf.set_extmark(bufnr, stopped_ns, loc.line - 1, 0, {
        sign_text = s.text,
        sign_hl_group = s.hl,
        line_hl_group = s.line_hl,
        priority = 30,
      })
      marked[bufnr] = true
    end
  end
end

return M
