-- The debug sidebar: a read-only `btv.view` mounted in an edge dock showing, for the
-- active session, the stopped thread's stack frames, the selected frame's scopes /
-- variables, a list of WATCH expressions, the adapter's EXCEPTION breakpoint filters,
-- and (when more than one session is live) a SESSIONS switcher. The view OWNS its
-- lines (no buffer mutation); each rendered row carries opaque userdata so `<CR>`
-- (and the buffer-local action keys) know what they hit.
--
-- `<CR>` is overloaded per-row: expand a structured variable, jump to + focus a stack
-- frame, toggle an exception filter, or switch the active session. The action keys —
-- installed buffer-local on the view (defaults `e` edit, `a` add-watch, `x` remove,
-- `r` refresh) — read the cursor row's userdata out of `state.data`.

local M = {}

local view, ns, cfg
local session -- the active session to query
local keymaps_installed = false
local state = {
  frames = {}, -- the stopped thread's stack
  scopes = {}, -- the current frame's scopes, each with a resolved `variables`
  expanded = {}, -- variablesReference -> true
  children = {}, -- variablesReference -> resolved child list (lazy)
  current = nil, -- the focused frame
  watches = {}, -- list of watch expression strings (persist across sessions)
  watch_items = {}, -- parallel to `watches`: the resolved { name, value, … } per expr
  watch_gen = 0, -- generation guard so a stale watch eval can't clobber a newer one
  data = {}, -- the rendered userdata list (parallel to lines), for keymap lookup
}

-- Hooks init.lua installs (it owns cross-session state the sidebar reflects):
--   on_jump(path, line)             focus the editor on a frame's source
--   is_exception_selected(filter)   is this exception filter currently enabled?
--   on_toggle_exception(filter)     toggle an exception filter
--   sessions_provider() -> list, active   the live sessions + the active one
--   on_select_session(session)      make a session active
M.on_jump = nil
M.is_exception_selected = nil
M.on_toggle_exception = nil
M.sessions_provider = nil
M.on_select_session = nil

local function ensure_view()
  if view then
    return
  end
  view = btv.view.create({ name = "bemtvi-dap-ui", filetype = "btvdap-ui" })
  ns = btv.ns.create("bemtvi-dap-ui")
  view:on_select(function(_line, data)
    M._on_select(data)
  end)
  -- The view's backing buffer lands a tick after create; install the action keys then.
  btv.on_next_tick(function()
    M._install_keymaps()
  end)
end

-- Install the buffer-local action keys on the view buffer (once). `<CR>` (and its mouse
-- form, a double-click) are the view's built-in select; these add edit / add-watch /
-- remove / refresh on top.
--
-- The view's backing buffer lands a tick after create, so this waits for it — through
-- `btv.wait_for`, which polls BETWEEN ticks with a bounded try count. Re-arming
-- `on_next_tick` by hand would spin forever if the buffer never materialized.
function M._install_keymaps()
  if keymaps_installed or not view then
    return
  end
  if not view:bufnr() then
    btv
      .wait_for(function()
        return view and view:bufnr()
      end, { tries = 50, message = "bemtvi-dap: the sidebar buffer never materialized" })
      :next(function()
        M._install_keymaps()
      end, function(err)
        btv.notify(tostring(err and err.message or err), 4)
      end)
    return
  end
  local buf = view:bufnr()
  local maps = (cfg and cfg.sidebar.mappings) or {}
  local actions = {
    edit = M.edit_value,
    add_watch = M.prompt_add_watch,
    remove = M.remove_under_cursor,
    refresh = M.refresh,
  }
  for action, lhs in pairs(maps) do
    if lhs and actions[action] then
      btv.keymap.set("n", lhs, actions[action], { buffer = buf, desc = "bemtvi-dap: " .. action })
    end
  end
  keymaps_installed = true
end

function M.setup(config)
  cfg = config
end

function M.set_session(s)
  session = s
end

function M.is_open()
  return view ~= nil and view:winid() ~= nil
end

-- The sidebar's backing buffer number (or nil before it exists). For tests / advanced
-- callers that want to read the rendered content.
function M.bufnr()
  return view and view:bufnr()
end

function M.open()
  ensure_view()
  if not M.is_open() then
    view:mount({ dock = cfg.sidebar.position, size = cfg.sidebar.width })
  end
  M.render()
end

function M.close()
  if view and M.is_open() then
    view:unmount()
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Reset the per-stop state (frames / scopes / focused frame). WATCHES persist across
-- sessions, so they are kept — only their resolved values are re-evaluated on the next
-- stop (or cleared to "not available" while nothing is stopped).
function M.clear()
  state.frames = {}
  state.scopes = {}
  state.expanded = {}
  state.children = {}
  state.current = nil
  state.watch_items = {}
  if view then
    M._eval_watches()
  end
end

-- Repaint at the end of this convergence rather than per callback. One stop lands a
-- scopes reply plus one reply per watch, each arriving separately; rendering on each
-- would repaint the entire sidebar N times for a single stop.
local render_queued = false
local function render_soon()
  if render_queued or not view then
    return
  end
  render_queued = true
  btv.schedule(function()
    render_queued = false
    M.render()
  end)
end

-- The view's backing buffer lands a tick after create, and `:set_decor` is a no-op
-- until it exists, so the paint that follows `open()` in the same tick would come out
-- with no highlights at all. Wait for the buffer (once, bounded) and lay the
-- decorations down then — the lines themselves already queued through `:set_lines`.
local awaiting_buf = false
local function decor_when_ready(pending_marks)
  if awaiting_buf then
    return
  end
  awaiting_buf = true
  btv
    .wait_for(function()
      return view and view:bufnr()
    end, { tries = 50, message = "bemtvi-dap: the sidebar buffer never materialized" })
    :next(function()
      awaiting_buf = false
      if view and view:bufnr() then
        view:set_decor(ns, pending_marks)
      end
    end, function(err)
      awaiting_buf = false
      btv.notify(tostring(err and err.message or err), 4)
    end)
end

-- A new stopped snapshot arrived: store the frames, focus the top frame, and load
-- its scopes + watches, then render.
function M.show_stopped(snapshot)
  state.frames = snapshot.frames or {}
  state.scopes = {}
  state.expanded = {}
  state.children = {}
  local top = state.frames[1]
  if cfg.sidebar.open_on_stopped then
    M.open()
  end
  if top and session then
    M.focus_frame(top)
  else
    state.current = nil
    M._eval_watches()
  end
end

-- Make `frame` the active frame: load its scopes (one level of variables), re-evaluate
-- the watches against it, and render.
--
-- The frame is pushed onto the SESSION too, not just the sidebar: `session.current_frame`
-- is what `:DapEval` / the `dap>` prompt / hover evaluate in. Leaving it pinned to the
-- top frame silently evaluated every expression in the wrong scope after you selected a
-- caller in the stack.
function M.focus_frame(frame)
  state.current = frame
  state.expanded = {}
  state.children = {}
  if not session then
    M.render()
    return
  end
  session.current_frame = frame
  session:frame_scopes(frame.id, function(scopes)
    state.scopes = scopes
    render_soon()
  end)
  M._eval_watches()
end

-- Re-evaluate every watch expression against the current frame (or mark them
-- unavailable when nothing is stopped), then render. A generation guard drops the
-- results of a superseded evaluation.
function M._eval_watches()
  state.watch_gen = state.watch_gen + 1
  local gen = state.watch_gen
  local exprs = state.watches
  state.watch_items = {}
  if #exprs == 0 then
    M.render()
    return
  end
  local frame = state.current
  if not session or not frame then
    for i, expr in ipairs(exprs) do
      state.watch_items[i] = { name = expr, value = "(not available)", variablesReference = 0 }
    end
    M.render()
    return
  end
  for i, expr in ipairs(exprs) do
    session:evaluate(expr, frame.id, "watch", function(err, body)
      if gen ~= state.watch_gen then
        return -- a newer evaluation has started; this result is stale
      end
      if err then
        state.watch_items[i] = {
          name = expr,
          value = "⚠ " .. tostring(err.message or "error"),
          variablesReference = 0,
          error = true,
        }
      else
        body = body or {}
        state.watch_items[i] = {
          name = expr,
          value = body.result or "",
          type = body.type,
          variablesReference = body.variablesReference or 0,
          evaluateName = expr,
        }
      end
      render_soon()
    end)
  end
end

-- ----- watches: public mutators ----------------------------------------------

function M.add_watch(expr)
  if not expr or expr == "" then
    return
  end
  state.watches[#state.watches + 1] = expr
  M.open() -- make the watch visible
  M._eval_watches()
end

function M.prompt_add_watch()
  btv.ui.input({ prompt = "Watch expression: " }):next(function(expr)
    if expr and expr ~= "" then
      M.add_watch(expr)
    end
  end)
end

function M.clear_watches()
  state.watches = {}
  M._eval_watches()
end

-- Remove the watch on the cursor row (a no-op + notify on any other row).
function M.remove_under_cursor()
  local line = view and view:line()
  local d = line and state.data[line]
  if d and d.kind == "watch" and d.index then
    table.remove(state.watches, d.index)
    M._eval_watches()
  else
    btv.notify("bemtvi-dap: no watch under the cursor", 3)
  end
end

-- Re-load scopes + watches for the current frame (the `r` key / after an edit).
function M.refresh()
  if state.current then
    M.focus_frame(state.current)
  else
    M._eval_watches()
  end
end

-- ----- variable / watch value editing ----------------------------------------

-- Edit the value of the variable or watch on the cursor row. A scope/child variable is
-- set with `setVariable` against its parent container; a watch (or a variable the
-- adapter only lets us set by expression) goes through `setExpression`.
function M.edit_value()
  if not session or session.terminated then
    return btv.notify("bemtvi-dap: no active session", 3)
  end
  local line = view and view:line()
  local d = line and state.data[line]
  if not d then
    return
  end
  local frame_id = state.current and state.current.id
  if d.kind == "var" then
    local var, parent = d.var, d.parent_ref
    btv.ui
      .input({ prompt = ("Set %s = "):format(var.name), default = var.value or "" })
      :next(function(val)
        if val == nil then
          return
        end
        if parent and parent ~= 0 and session.capabilities.supportsSetVariable then
          session:set_variable(parent, var.name, val, function(err)
            if not err then
              M.refresh()
            end
          end)
        elseif session.capabilities.supportsSetExpression and var.evaluateName then
          session:set_expression(var.evaluateName, val, frame_id, function(err)
            if not err then
              M.refresh()
            end
          end)
        else
          btv.notify("bemtvi-dap: this adapter can't set " .. var.name, 3)
        end
      end)
  elseif d.kind == "watch" then
    local w = d.var
    if not session.capabilities.supportsSetExpression then
      return btv.notify("bemtvi-dap: this adapter does not support setExpression", 3)
    end
    btv.ui
      .input({ prompt = ("Set %s = "):format(w.name), default = w.value or "" })
      :next(function(val)
        if val == nil then
          return
        end
        session:set_expression(w.evaluateName or w.name, val, frame_id, function(err)
          if not err then
            M.refresh()
          end
        end)
      end)
  end
end

-- ----- selection handling ----------------------------------------------------

function M._on_select(data)
  if not data then
    return
  end
  if data.kind == "frame" then
    state.current = data.frame
    if M.on_jump and data.frame.source and data.frame.source.path then
      M.on_jump(data.frame.source.path, data.frame.line)
    end
    M.focus_frame(data.frame)
  elseif data.kind == "var" or data.kind == "watch" then
    local ref = (data.var and data.var.variablesReference) or 0
    if ref == 0 then
      return
    end
    if state.expanded[ref] then
      state.expanded[ref] = nil
      M.render()
    elseif state.children[ref] then
      state.expanded[ref] = true
      M.render()
    elseif session then
      session:variables(ref, function(vars)
        state.children[ref] = vars
        state.expanded[ref] = true
        render_soon()
      end)
    end
  elseif data.kind == "exception" then
    if M.on_toggle_exception then
      M.on_toggle_exception(data.filter.filter)
    end
  elseif data.kind == "session" then
    if M.on_select_session then
      M.on_select_session(data.session)
    end
  end
end

-- ----- rendering -------------------------------------------------------------

-- Append a variable row (recursing into expanded children) to lines/data/marks.
-- `parent_ref` is the container's variablesReference (the `setVariable` target).
local function render_var(var, depth, parent_ref, lines, data, marks)
  local ref = var.variablesReference or 0
  local marker = ref > 0 and (state.expanded[ref] and "▾ " or "▸ ") or "  "
  local indent = string.rep("  ", depth)
  local name_col = #indent + #marker
  local prefix = indent .. marker .. var.name
  local line = prefix .. " = " .. (var.value or "")
  lines[#lines + 1] = line
  data[#data + 1] = { kind = "var", var = var, parent_ref = parent_ref }
  local row = #lines - 1
  marks[#marks + 1] = {
    line = row,
    col = name_col,
    end_row = row,
    end_col = name_col + #var.name,
    hl_group = "BtvDapUIVarName",
  }
  local val_col = #prefix + 3
  marks[#marks + 1] =
    { line = row, col = val_col, end_row = row, end_col = #line, hl_group = "BtvDapUIValue" }
  if state.expanded[ref] and state.children[ref] then
    for _, child in ipairs(state.children[ref]) do
      render_var(child, depth + 1, ref, lines, data, marks)
    end
  end
end

function M.render()
  if not view then
    return
  end
  local lines, data, marks = {}, {}, {}
  local function blank()
    lines[#lines + 1] = ""
    data[#data + 1] = { kind = "header" }
  end
  local function header(text, hl)
    lines[#lines + 1] = text
    data[#data + 1] = { kind = "header" }
    marks[#marks + 1] = {
      line = #lines - 1,
      col = 0,
      end_row = #lines - 1,
      end_col = #text,
      hl_group = hl or "BtvDapUIThread",
    }
  end

  -- WATCHES (always shown, so a watch can be added before a stop).
  header("WATCHES")
  if #state.watches == 0 then
    lines[#lines + 1] = "  (none — press a to add)"
    data[#data + 1] = { kind = "header" }
  else
    for i, expr in ipairs(state.watches) do
      local item = state.watch_items[i] or { name = expr, value = "…", variablesReference = 0 }
      local ref = item.variablesReference or 0
      local marker = ref > 0 and (state.expanded[ref] and "▾ " or "▸ ") or "  "
      local prefix = "  " .. marker .. expr
      lines[#lines + 1] = prefix .. " = " .. (item.value or "")
      data[#data + 1] = { kind = "watch", var = item, index = i }
      local row = #lines - 1
      marks[#marks + 1] = {
        line = row,
        col = 2 + #marker,
        end_row = row,
        end_col = 2 + #marker + #expr,
        hl_group = "BtvDapUIVarName",
      }
      marks[#marks + 1] = {
        line = row,
        col = #prefix + 3,
        end_row = row,
        end_col = #lines[#lines],
        hl_group = item.error and "BtvDapReplError" or "BtvDapUIValue",
      }
      -- An expanded structured watch shows its children (real variables under the
      -- watch result's reference).
      if state.expanded[ref] and state.children[ref] then
        for _, child in ipairs(state.children[ref]) do
          render_var(child, 2, ref, lines, data, marks)
        end
      end
    end
  end

  -- STACK FRAMES + SCOPES of the active session.
  if #state.frames > 0 then
    blank()
    header("STACK FRAMES")
    for _, frame in ipairs(state.frames) do
      local cur = state.current and state.current.id == frame.id
      local loc = ""
      if frame.source and frame.source.path then
        loc = "  "
          .. (frame.source.path:match("[^/]+$") or frame.source.path)
          .. ":"
          .. tostring(frame.line)
      end
      local sigil = cur and "→ " or "  "
      lines[#lines + 1] = " " .. sigil .. frame.name .. loc
      data[#data + 1] = { kind = "frame", frame = frame }
      marks[#marks + 1] = {
        line = #lines - 1,
        col = 0,
        end_row = #lines - 1,
        end_col = #lines[#lines],
        hl_group = cur and "BtvDapUIFrameCurrent" or "BtvDapUIFrame",
      }
    end

    blank()
    header("SCOPES")
    for _, scope in ipairs(state.scopes) do
      header("  " .. scope.name, "BtvDapUIScope")
      for _, var in ipairs(scope.variables or {}) do
        render_var(var, 1, scope.variablesReference, lines, data, marks)
      end
    end
  end

  -- EXCEPTIONS: the active session's advertised filters with their on/off state.
  local filters = session
    and session.capabilities
    and session.capabilities.exceptionBreakpointFilters
  if filters and #filters > 0 then
    blank()
    header("EXCEPTIONS")
    for _, f in ipairs(filters) do
      local on = M.is_exception_selected and M.is_exception_selected(f.filter)
      lines[#lines + 1] = "  " .. (on and "[x] " or "[ ] ") .. (f.label or f.filter)
      data[#data + 1] = { kind = "exception", filter = f }
      marks[#marks + 1] = {
        line = #lines - 1,
        col = 2,
        end_row = #lines - 1,
        end_col = #lines[#lines],
        hl_group = on and "BtvDapUIFrameCurrent" or "BtvDapUIFrame",
      }
    end
  end

  -- SESSIONS: only when more than one is live (the switcher).
  if M.sessions_provider then
    local list, active = M.sessions_provider()
    if list and #list > 1 then
      blank()
      header("SESSIONS")
      for _, s in ipairs(list) do
        local status = s.terminated and "ended" or (s.stopped_thread_id and "stopped" or "running")
        local sigil = (s == active) and "→ " or "  "
        lines[#lines + 1] = " "
          .. sigil
          .. (s.name or ("session " .. tostring(s.id)))
          .. "  ("
          .. status
          .. ")"
        data[#data + 1] = { kind = "session", session = s }
        marks[#marks + 1] = {
          line = #lines - 1,
          col = 0,
          end_row = #lines - 1,
          end_col = #lines[#lines],
          hl_group = (s == active) and "BtvDapUIFrameCurrent" or "BtvDapUIFrame",
        }
      end
    end
  end

  if #state.frames == 0 and #state.watches == 0 and not (filters and #filters > 0) then
    lines[#lines + 1] = ""
    data[#data + 1] = { kind = "header" }
    lines[#lines + 1] = "  no active stop"
    data[#data + 1] = { kind = "header" }
  end

  state.data = data
  view:set_userdata(data)
  view:set_lines(lines)
  if view:bufnr() then
    view:set_decor(ns, marks)
  else
    -- The backing buffer lands a tick after create and `:set_decor` is a no-op until
    -- then, so the first paint after `open()` would come out unhighlighted. Lay this
    -- paint's marks down once the buffer exists.
    decor_when_ready(marks)
  end
end

return M
