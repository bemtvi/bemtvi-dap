-- The breakpoint store: the source of truth for where breakpoints are, independent
-- of any running session. Toggling updates the store, repaints that file's signs,
-- and (via the `on_change` hook init.lua installs) pushes the new set to a live
-- session. A session's `_configure` reads the whole store through `M.list` to seed
-- breakpoints at launch.

local signs = require("nxvim-dap.signs")

local M = {}

-- abspath -> list of { line, condition?, logMessage?, hitCondition? }
M.store = {}

-- on_change(path, bps): called after any mutation so init.lua can push the file's
-- breakpoints to an active session. Set by init.lua; a no-op until then.
M.on_change = nil

-- on_commit(): called once per logical mutation (with the store already updated) so
-- init.lua can react to a settled change — save the set to the workspace plugin shada
-- and refresh the breakpoints location list. Set by init.lua; a no-op until then.
M.on_commit = nil

local function fire(path)
  if M.on_change then
    M.on_change(path, M.store[path] or {})
  end
end

-- Signal a settled mutation. Called once per logical change, after the store and signs
-- are settled (unlike `fire`, which is per-affected-file for the live-session push).
local function commit()
  if M.on_commit then
    M.on_commit()
  end
end

-- The current buffer's absolute path + cursor line (1-based), or nil if the buffer
-- has no file.
local function here()
  local bufnr = nx.buf.current()
  local name = nx.buf.name(bufnr)
  if not name or name == "" then
    return nil
  end
  local cur = nx.cursor.get(nx.win.current())
  local line = (cur and (cur.row or cur[1])) or 1
  return signs.abspath(name), line
end

local function index_at(bps, line)
  for i, bp in ipairs(bps) do
    if bp.line == line then
      return i
    end
  end
end

-- Toggle (or set) a breakpoint at the cursor. `opts.condition` / `opts.logMessage` /
-- `opts.hitCondition` set a conditional / log point — passing one when a breakpoint
-- already exists there UPGRADES it (MERGING the given attributes into it) rather than
-- removing it. Only the attributes actually passed are touched, so adding a condition
-- to a log point keeps its message; clearing one is `set_at_cursor`'s job (the edit
-- path, which writes the full attribute set).
function M.toggle(opts)
  opts = opts or {}
  local path, line = here()
  if not path then
    nx.notify("nxvim-dap: no file in the current buffer", 3)
    return
  end
  local bps = M.store[path] or {}
  M.store[path] = bps
  local at = index_at(bps, line)
  if at then
    if opts.condition or opts.logMessage or opts.hitCondition then
      bps[at].condition = opts.condition or bps[at].condition
      bps[at].logMessage = opts.logMessage or bps[at].logMessage
      bps[at].hitCondition = opts.hitCondition or bps[at].hitCondition
    else
      table.remove(bps, at)
    end
  else
    bps[#bps + 1] = {
      line = line,
      condition = opts.condition,
      logMessage = opts.logMessage,
      hitCondition = opts.hitCondition,
    }
    table.sort(bps, function(a, b)
      return a.line < b.line
    end)
  end
  if #bps == 0 then
    M.store[path] = nil
    signs.clear_breakpoints(path)
  else
    signs.render_breakpoints(path, bps)
  end
  fire(path)
  commit()
end

-- The breakpoint at the cursor (its `{ line, condition?, hitCondition?, logMessage? }`),
-- or nil if there is none there. Used to pre-fill the edit prompts.
function M.get_at_cursor()
  local path, line = here()
  if not path then
    return nil
  end
  local bps = M.store[path]
  if not bps then
    return nil
  end
  local at = index_at(bps, line)
  return at and bps[at] or nil
end

-- Set (or create) the breakpoint at the cursor with `fields` (`condition`,
-- `hitCondition`, `logMessage` — a nil clears that attribute). Unlike `toggle`, this
-- never removes the breakpoint: it is the "edit this breakpoint" path. Re-renders the
-- file's signs and pushes the change to a live session.
function M.set_at_cursor(fields)
  fields = fields or {}
  local path, line = here()
  if not path then
    nx.notify("nxvim-dap: no file in the current buffer", 3)
    return
  end
  local bps = M.store[path] or {}
  M.store[path] = bps
  local at = index_at(bps, line)
  local bp
  if at then
    bp = bps[at]
  else
    bp = { line = line }
    bps[#bps + 1] = bp
    table.sort(bps, function(a, b)
      return a.line < b.line
    end)
  end
  bp.condition = fields.condition
  bp.hitCondition = fields.hitCondition
  bp.logMessage = fields.logMessage
  signs.render_breakpoints(path, bps)
  fire(path)
  commit()
end

-- Remove every breakpoint (and its signs), firing a change per affected file so a
-- session clears them too.
function M.clear_all()
  local paths = {}
  for path in pairs(M.store) do
    paths[#paths + 1] = path
  end
  for _, path in ipairs(paths) do
    M.store[path] = nil
    signs.clear_breakpoints(path)
    fire(path)
  end
  commit()
end

-- The whole store (the session's `get_breakpoints`).
function M.list()
  return M.store
end

-- Replace the store with `data` (the shape `M.list` returns: `abspath -> list of
-- { line, condition?, hitCondition?, logMessage? }`) and repaint every file's signs.
-- Used at setup to seed the breakpoints persisted in the workspace shada. Tolerant of a
-- malformed blob (anything not a table is treated as "nothing saved"), and skips entries
-- without a numeric `line` so a corrupt store can't break startup. Does NOT fire
-- `on_commit` — restoring isn't a user mutation, and re-saving here would be a no-op.
function M.restore(data)
  if type(data) ~= "table" then
    return
  end
  M.store = {}
  for path, bps in pairs(data) do
    if type(path) == "string" and type(bps) == "table" then
      local clean = {}
      for _, bp in ipairs(bps) do
        if type(bp) == "table" and type(bp.line) == "number" then
          clean[#clean + 1] = {
            line = bp.line,
            condition = bp.condition,
            hitCondition = bp.hitCondition,
            logMessage = bp.logMessage,
          }
        end
      end
      if #clean > 0 then
        table.sort(clean, function(a, b)
          return a.line < b.line
        end)
        M.store[path] = clean
      end
    end
  end
  M.render_all()
end

-- Repaint signs for every file that has breakpoints (after a restore, or once at
-- startup for the buffers already open). One buffer index is built for the whole sweep
-- rather than re-scanning the buffer list per file.
function M.render_all()
  if next(M.store) == nil then
    return
  end
  local index = signs.buf_index()
  for path, bps in pairs(M.store) do
    local bufnr = index[signs.abspath(path)]
    if bufnr then
      signs.render_breakpoints(path, bps, bufnr)
    end
  end
end

-- Repaint the signs of ONE buffer — the BufEnter path. A buffer that was closed when a
-- breakpoint was set carries no marks until it comes back, and repainting just it costs
-- nothing next to sweeping every file in the store on every buffer switch.
function M.render_buf(bufnr)
  bufnr = bufnr or nx.buf.current()
  if not bufnr or not nx.buf.is_valid(bufnr) then
    return
  end
  local name = nx.buf.name(bufnr)
  if not name or name == "" then
    return
  end
  local path = signs.abspath(name)
  local bps = M.store[path]
  if bps then
    signs.render_breakpoints(path, bps, bufnr)
  end
end

return M
