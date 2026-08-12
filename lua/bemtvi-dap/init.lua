-- bemtvi-dap — a Debug Adapter Protocol client for bemtvi, built entirely on the
-- native `btv.*` plugin API (ADR 0002). It is the bemtvi sibling of nvim-dap: the same
-- two-table model (`adapters` = how to reach a debug adapter, `configurations` = what
-- to debug per filetype), the same launch/attach flow, breakpoints (conditional / hit /
-- log + exception filters), stepping and restart, multiple concurrent sessions, a
-- scopes/variables/watches sidebar with inline value editing, and a REPL — re-expressed
-- in bemtvi's idiom.
--
-- The keystone is `btv.process` (the duplex child transport): a debug adapter speaks
-- Content-Length-framed JSON over stdio exactly like a language server, which neither
-- `btv.run` nor `btv.run_stream` can carry (they close stdin and line-split stdout).
--
-- Module map:
--   config.lua       defaults + adapter/configuration validation
--   variables.lua    ${file}/${workspaceFolder}/… + callable expansion of a config
--   rpc.lua          the Content-Length wire codec
--   session.lua      the DAP protocol state machine over an injected transport
--   breakpoints.lua  the breakpoint store + cursor toggle
--   signs.lua        gutter signs + the stopped-line highlight (real buffers)
--   ui.lua           the stack/scopes/variables/watches/exceptions sidebar (btv.view)
--   repl.lua         the debug console (output + evaluate)
--   highlights.lua   the fallback highlight palette
--
-- Quick start (init.lua):
--   local dap = require("bemtvi-dap")
--   dap.setup({})
--   dap.adapters.python = { command = "python", args = { "-m", "debugpy.adapter" } }
--   dap.configurations.python = {
--     { type = "python", request = "launch", name = "file", program = "${file}" },
--   }
--   -- then <F5> / :DapContinue starts it, <leader>db toggles a breakpoint.

local config_mod = require("bemtvi-dap.config")
local variables = require("bemtvi-dap.variables")
local session_mod = require("bemtvi-dap.session")
local breakpoints = require("bemtvi-dap.breakpoints")
local signs = require("bemtvi-dap.signs")
local ui = require("bemtvi-dap.ui")
local repl = require("bemtvi-dap.repl")
local highlights = require("bemtvi-dap.highlights")

local M = {}

M.config = config_mod.defaults()
-- The public registries (nvim-dap parity): users assign into these directly.
M.adapters = {}
M.configurations = {}
-- Command handlers for `${command:id}` config tokens: id -> function(args, config) that
-- returns a string (or a promise of one). Populate via `dap.register_command`.
M.commands = {}

-- Multiple concurrent sessions: `M._sessions` is the registry (id -> session) and
-- `M._session` is the ACTIVE one — the session the UI mirrors and the commands target.
-- A session becomes active when it starts and, again, when it stops (so the panels
-- follow execution); on termination the active slot falls to another live session.
M._sessions = {}
M._session = nil
-- The chosen exception-breakpoint filters: filter-id -> true. nil means "use the
-- adapter's own defaults" (the faithful default until the user picks). Persisted across
-- sessions and restarts so a toggled set sticks.
M.exception_filters = nil

local session_seq = 0
local autocmds_wired = false
-- The lhs keys the last setup() installed, so a re-run can drop them before binding the
-- new set (setup is a full reconfigure, not an additive one).
local installed_maps = {}
-- The workspace breakpoints are restored once, on the first setup() in a workspace
-- session — re-running setup() must not clobber live breakpoints with the saved set.
local bp_restored = false

-- ----- session lifecycle -----------------------------------------------------

-- Open the file at `path` in the MAIN editor and put the cursor on `line` (1-based).
-- The cursor set defers a tick so the buffer/window have settled after the open.
local function jump(path, line)
  btv.open(path, { where = "main" })
  btv.on_next_tick(function()
    btv.cursor.set({ line, 0 })
  end)
end

-- Every live session, newest first (a stable order for the picker / sidebar).
function M.sessions()
  local list = {}
  for _, s in pairs(M._sessions) do
    list[#list + 1] = s
  end
  table.sort(list, function(a, b)
    return (a.id or 0) > (b.id or 0)
  end)
  return list
end

-- Make `session` the active one: point the UI / REPL at it and repaint.
function M._set_active(session)
  M._session = session
  ui.set_session(session)
  repl.set_session(session)
  ui.render()
end

-- Every live session that has finished configuring — the set a breakpoint / exception
-- filter change must reach. A breakpoint belongs to the PROJECT, not to whichever
-- session happens to be active, so a change is pushed to all of them.
function M._live_sessions()
  local live = {}
  for _, s in ipairs(M.sessions()) do
    if s.initialized and not s.terminated then
      live[#live + 1] = s
    end
  end
  return live
end

-- Pick a successor active session after the active one ends: prefer one that is stopped
-- (so the panels show something actionable), else any live one, else nil. `M.sessions()`
-- (newest first) drives the scan, so the choice is stable rather than hash order.
local function pick_successor()
  local fallback
  for _, s in ipairs(M.sessions()) do
    if not s.terminated then
      fallback = fallback or s
      if s.stopped_thread_id then
        return s
      end
    end
  end
  return fallback
end

-- Drop `session` from the registry (with its stopped marker) and, when it held the
-- active slot, fold that slot onto a successor — or empty the panels when it was the
-- last one. The shared tail of "this session is gone", however it went.
local function retire(session)
  if session.id then
    M._sessions[session.id] = nil
    signs.clear_stopped(session.id)
  end
  if M._session ~= session then
    return
  end
  local successor = pick_successor()
  if successor then
    M._set_active(successor)
    M._refresh_active_view()
  else
    M._session = nil
    ui.clear()
    ui.set_session(nil)
    repl.set_session(nil)
  end
end

-- A session ended: retire it, announce it on the console, and — if it asked to restart
-- — relaunch its config.
function M._on_session_terminated(session, body)
  local restart_cfg = session._restart_with
    or (body and body.restart ~= nil and body.restart ~= false and session.config)
  retire(session)
  repl.flush()
  local exit = body and body.exitCode
  repl.info(
    "─ "
      .. (session.name or "session")
      .. " terminated"
      .. (exit ~= nil and (" (exit " .. tostring(exit) .. ")") or "")
      .. " ─"
  )

  if restart_cfg then
    btv.on_next_tick(function()
      M.run(restart_cfg)
    end)
  end
end

-- Build the protocol handler table for one session (capturing `get_id`, which resolves
-- the session's assigned id once `run` has set it).
local function make_handlers(get_id)
  return {
    get_breakpoints = breakpoints.list,
    get_exception_filters = function(caps)
      return M._exception_filter_list(caps)
    end,
    notify = function(msg, lvl)
      btv.notify(msg, lvl)
    end,
    on_output = function(category, text)
      repl.append_output(category, text)
    end,
    on_stopped = function(_body, snapshot)
      local id = get_id()
      local session = id and M._sessions[id]
      -- A stop pulls focus to its session (the panels follow execution).
      if session and M._session ~= session then
        M._set_active(session)
      end
      local frame = snapshot.frames and snapshot.frames[1]
      if frame and frame.source and frame.source.path then
        signs.set_stopped(id, frame.source.path, frame.line)
        if M.config.jump_to_stopped then
          jump(frame.source.path, frame.line)
        end
      end
      ui.show_stopped(snapshot)
    end,
    on_continued = function()
      signs.clear_stopped(get_id())
    end,
    on_terminated = function(body)
      local id = get_id()
      M._on_session_terminated(id and M._sessions[id] or { id = id }, body)
    end,
    on_state = function(_st) end,
  }
end

-- Start a concrete launch/attach `config` (resolving its adapter by `config.type`) as a
-- NEW concurrent session, made active. Prior sessions keep running.
--
-- Configuration values are expanded first (see variables.lua): `${file}` /
-- `${workspaceFolder}` / … and callable field values resolve synchronously; the
-- interactive `${input:…}` / `${command:…}` forms then resolve in an async pass (which
-- may prompt) before the session is spawned. The synchronous case (no prompts) starts the
-- session immediately and returns it; the interactive case returns nil and starts once the
-- prompts are answered.
function M.run(config)
  config = config_mod.validate_configuration(config)
  local ok, expanded, unknown, has_dynamic = pcall(variables.expand, config)
  if not ok then
    btv.notify(tostring(expanded), 4) -- a callable field value errored
    return
  end
  if #unknown > 0 then
    btv.notify(
      "bemtvi-dap: unrecognised config variable(s) left as-is: ${"
        .. table.concat(unknown, "}, ${")
        .. "}",
      3
    )
  end
  if not has_dynamic then
    return M._start(expanded) -- no prompts: start synchronously
  end
  -- Interactive `${input:…}` / `${command:…}`: prompt, then start. A rejection (a missing
  -- definition, an unsupported type, or a cancelled prompt) aborts the launch loud.
  variables.resolve_dynamic(expanded, { commands = M.commands }):next(function(final)
    M._start(final)
  end, function(err)
    btv.notify("bemtvi-dap: " .. tostring(err and err.message or err), 4)
  end)
end

-- Spawn the session for a fully-expanded `config` (the shared tail of both M.run paths).
function M._start(config)
  config.inputs = nil -- a UI-only field; never sent to the adapter
  local adapter = M.adapters[config.type]
  if not adapter then
    btv.notify(("bemtvi-dap: no adapter registered for type %q"):format(config.type), 4)
    return
  end

  local first = next(M._sessions) == nil
  if first then
    -- A fresh debugging run: start the console clean. Concurrent runs share the
    -- console (so output interleaves) rather than wiping a live session's scrollback.
    repl.clear()
  end
  if M.config.repl.open_on_start then
    repl.open()
  end
  repl.info("─ starting " .. config.name .. " ─")

  session_seq = session_seq + 1
  local id = session_seq
  local session = session_mod.spawn(
    adapter,
    config,
    make_handlers(function()
      return id
    end)
  )
  session.id = id
  session.name = config.name
  M._sessions[id] = session
  ui.clear()
  M._set_active(session)
  return session
end

-- Register a `${command:id}` handler. `fn(args, config)` is called when a configuration
-- references `${command:id}`; it returns the substituted string (or a promise of one).
-- `args` is the optional `args` of a `type = "command"` input, `config` the launch config.
function M.register_command(id, fn)
  if type(id) ~= "string" or type(fn) ~= "function" then
    btv.notify("bemtvi-dap: register_command(id, fn) needs a string id and a function", 4)
    return
  end
  M.commands[id] = fn
end

-- Restart the active session: in place via the adapter's `restart` request when it is
-- supported, otherwise by terminating and relaunching the same configuration as a new
-- session.
function M.restart()
  local s = M._session
  if not s or s.terminated then
    btv.notify("bemtvi-dap: no active session to restart", 3)
    return
  end
  local config = s.config
  if s.capabilities.supportsRestartRequest then
    s:restart(config, function(err)
      if err then
        btv.notify("bemtvi-dap: restart failed: " .. tostring(err.message), 4)
      else
        repl.info("─ restarted " .. (s.name or "session") .. " ─")
      end
    end)
  else
    -- No restart request: terminate, and relaunch the config once it is gone.
    s._restart_with = config
    s:disconnect({ terminate = true })
  end
end

-- Make `session` the active one (the sidebar's session switcher), repainting the UI to
-- reflect its frames / scopes (re-fetched lazily as the user focuses a frame).
function M.set_active_session(session)
  if not session then
    return
  end
  M._set_active(session)
  M._refresh_active_view()
end

-- Start debugging, or resume if a session is already stopped. With no running
-- session, pick a configuration for the current buffer's filetype.
-- The names of the launch configurations available for the current buffer's filetype —
-- the candidate set `:DapContinue <Tab>` completes against.
function M._configuration_names()
  local ft = vim.bo[btv.buf.current()].filetype
  local names = {}
  for _, c in ipairs(M.configurations[ft] or {}) do
    if c.name and c.name ~= "" then
      names[#names + 1] = c.name
    end
  end
  return names
end

-- Start (or resume) debugging. With an explicit `name` (the optional `:DapContinue`
-- argument, completed from `_configuration_names`), launch that named configuration for
-- the current filetype directly instead of prompting; an unknown name is reported rather
-- than silently ignored. Without one, resume a live session or pick a configuration as
-- before.
function M.continue(name)
  if M._session and not M._session.terminated then
    M._session:continue()
    return
  end
  local ft = vim.bo[btv.buf.current()].filetype
  local cfgs = M.configurations[ft]
  if not cfgs or #cfgs == 0 then
    btv.notify(("bemtvi-dap: no debug configuration for filetype %q"):format(tostring(ft)), 3)
    return
  end
  if name and name ~= "" then
    for _, c in ipairs(cfgs) do
      if c.name == name then
        M.run(c)
        return
      end
    end
    btv.notify(("bemtvi-dap: no configuration %q for filetype %q"):format(name, tostring(ft)), 3)
    return
  end
  if #cfgs == 1 then
    M.run(cfgs[1])
  else
    btv.ui
      .select(cfgs, {
        prompt = "Debug configuration",
        format_item = function(c)
          return c.name
        end,
      })
      :next(function(choice)
        -- btv.ui.select resolves the chosen item (or its index — tolerate both).
        local cfg = type(choice) == "number" and cfgs[choice] or choice
        if cfg then
          M.run(cfg)
        end
      end)
  end
end

local function require_session()
  if not M._session or M._session.terminated then
    btv.notify("bemtvi-dap: no active session", 3)
    return nil
  end
  return M._session
end

function M.step_over()
  local s = require_session()
  if s then
    s:step_over()
  end
end
function M.step_into()
  local s = require_session()
  if s then
    s:step_into()
  end
end
function M.step_out()
  local s = require_session()
  if s then
    s:step_out()
  end
end
function M.pause()
  local s = require_session()
  if s then
    s:pause()
  end
end

-- Stop the active session. With nothing running this REPORTS rather than running the
-- teardown for a session that never existed (which announced a phantom "terminated" on
-- the console); a session the registry still holds but that has already ended is simply
-- retired — its termination was announced when it happened.
function M.terminate()
  local s = M._session
  if not s then
    btv.notify("bemtvi-dap: no active session", 3)
    return
  end
  if s.terminated then
    retire(s)
    return
  end
  s:disconnect({ terminate = true })
end

-- Terminate every live session (the global stop).
function M.terminate_all()
  local any = false
  for _, s in ipairs(M.sessions()) do
    if s.terminated then
      retire(s)
    else
      any = true
      s:disconnect({ terminate = true })
    end
  end
  if not any then
    btv.notify("bemtvi-dap: no debug session is running", 3)
  end
end

function M.session()
  return M._session
end

-- Re-populate the sidebar from the active session's last stop (used when the active
-- session changes — a manual switch or a successor after a termination).
function M._refresh_active_view()
  local s = M._session
  if s and not s.terminated and s.stopped_thread_id and s.last_snapshot then
    ui.show_stopped(s.last_snapshot)
  else
    ui.clear()
  end
end

-- Open the session switcher (only meaningful with more than one). Picks the active one.
function M.pick_session()
  local list = M.sessions()
  if #list == 0 then
    btv.notify("bemtvi-dap: no sessions", 3)
    return
  end
  if #list == 1 then
    M.set_active_session(list[1])
    return
  end
  btv.ui
    .select(list, {
      prompt = "Active session",
      format_item = function(s)
        local status = s.terminated and "ended" or (s.stopped_thread_id and "stopped" or "running")
        return (s.name or ("session " .. tostring(s.id))) .. " (" .. status .. ")"
      end,
    })
    :next(function(choice)
      if choice then
        M.set_active_session(choice)
      end
    end)
end

-- ----- exception breakpoints -------------------------------------------------

-- The filter-id list to enable, given the adapter's advertised `caps`. Returns nil when
-- the user hasn't picked any (the session then falls back to the adapter defaults).
function M._exception_filter_list(caps)
  if M.exception_filters == nil then
    return nil
  end
  local list = {}
  for _, f in ipairs(caps or {}) do
    if M.exception_filters[f.filter] then
      list[#list + 1] = f.filter
    end
  end
  return list
end

-- Is exception filter `id` currently enabled? Before the user picks, the adapter's
-- own `default` filters read as enabled (so the sidebar mirrors the live state).
function M.is_exception_selected(id)
  if M.exception_filters ~= nil then
    return M.exception_filters[id] == true
  end
  local caps = M._session and M._session.capabilities.exceptionBreakpointFilters
  for _, f in ipairs(caps or {}) do
    if f.filter == id then
      return f.default == true
    end
  end
  return false
end

-- Toggle exception filter `id` and push the new set to the active session.
function M.toggle_exception_filter(id)
  -- Materialize the selection set from the current state on first toggle.
  if M.exception_filters == nil then
    M.exception_filters = {}
    local caps = M._session and M._session.capabilities.exceptionBreakpointFilters
    for _, f in ipairs(caps or {}) do
      if f.default then
        M.exception_filters[f.filter] = true
      end
    end
  end
  M.exception_filters[id] = not M.exception_filters[id] or nil
  -- The selection is plugin-wide, so push it to every live session (each mapped
  -- through its OWN advertised filters — adapters don't share filter ids).
  for _, s in ipairs(M._live_sessions()) do
    local caps = s.capabilities.exceptionBreakpointFilters
    if caps then
      s:set_exception_breakpoints(M._exception_filter_list(caps) or {})
    end
  end
  ui.render()
end

-- Pick exception filters (the active session's advertised set). Opens the sidebar where
-- each filter is a `[x]`/`[ ]` row toggled with `<CR>`.
function M.set_exception_breakpoints()
  local s = M._session
  if not s or not s.capabilities.exceptionBreakpointFilters then
    btv.notify("bemtvi-dap: the active adapter has no exception breakpoint filters", 3)
    return
  end
  ui.open()
end

-- ----- watches ---------------------------------------------------------------

function M.add_watch(expr)
  if expr and expr ~= "" then
    ui.add_watch(expr)
  else
    ui.prompt_add_watch()
  end
end

function M.clear_watches()
  ui.clear_watches()
end

-- ----- breakpoints -----------------------------------------------------------

function M.toggle_breakpoint()
  breakpoints.toggle()
end

function M.set_breakpoint_condition()
  btv.ui.input({ prompt = "Breakpoint condition: " }):next(function(cond)
    if cond and cond ~= "" then
      breakpoints.toggle({ condition = cond })
    end
  end)
end

function M.set_log_point()
  btv.ui.input({ prompt = "Log point message: " }):next(function(msg)
    if msg and msg ~= "" then
      breakpoints.toggle({ logMessage = msg })
    end
  end)
end

-- Edit the full attribute set of the breakpoint at the cursor (creating one if absent):
-- condition, then hit condition, then log message — each prompt pre-filled with the
-- current value, an empty answer clearing that attribute. The breakpoint is kept (this
-- is "edit", not "toggle").
function M.edit_breakpoint()
  local existing = breakpoints.get_at_cursor() or {}
  btv.ui
    .input({ prompt = "Condition: ", default = existing.condition or "" })
    :next(function(condition)
      if condition == nil then
        return
      end
      btv.ui
        .input({ prompt = "Hit condition: ", default = existing.hitCondition or "" })
        :next(function(hit)
          if hit == nil then
            return
          end
          btv.ui
            .input({ prompt = "Log message: ", default = existing.logMessage or "" })
            :next(function(log)
              if log == nil then
                return
              end
              breakpoints.set_at_cursor({
                condition = condition ~= "" and condition or nil,
                hitCondition = hit ~= "" and hit or nil,
                logMessage = log ~= "" and log or nil,
              })
            end)
        end)
    end)
end

function M.clear_breakpoints()
  breakpoints.clear_all()
end

-- A one-line label for a breakpoint in the list: the kind plus any condition / hit /
-- log attribute, so the location list reads at a glance.
local function describe_breakpoint(bp)
  local parts = {}
  if bp.logMessage and bp.logMessage ~= "" then
    parts[#parts + 1] = "log: " .. bp.logMessage
  end
  if bp.condition and bp.condition ~= "" then
    parts[#parts + 1] = "cond: " .. bp.condition
  end
  if bp.hitCondition and bp.hitCondition ~= "" then
    parts[#parts + 1] = "hit: " .. bp.hitCondition
  end
  if #parts == 0 then
    return "breakpoint"
  end
  return table.concat(parts, "  ")
end

-- Build the named-list entries for every set breakpoint: one entry per breakpoint,
-- `{ filename, lnum, col, text }`, sorted by file then line. Factored out so it can be
-- tested without driving the (async, server-side) list.
function M._breakpoint_items()
  local items = {}
  for path, bps in pairs(breakpoints.list()) do
    for _, bp in ipairs(bps) do
      items[#items + 1] = {
        filename = path,
        lnum = bp.line,
        col = 1,
        text = describe_breakpoint(bp),
      }
    end
  end
  table.sort(items, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    return a.lnum < b.lnum
  end)
  return items
end

-- The named list backing `:DapBreakpoints`. Unlike a per-window location list, a named
-- list lives on the editor and is addressed by name, so it survives closing the window
-- it was opened from (reopen by name re-renders) and never collides with the quickfix.
-- `M._breakpoint_items` is pushed into it after every breakpoint mutation, so an open
-- tab repaints live instead of showing a stale snapshot.
local BP_LIST = "bemtvi-dap-breakpoints"

-- Rewrite the breakpoint named list from the current breakpoint set, repainting its tab
-- in place when open. Called after every breakpoint mutation so an open list stays
-- current; harmless before the list has ever been shown (it just updates the stored
-- contents — no window).
function M._refresh_breakpoint_list()
  btv.qf.list(BP_LIST, M._breakpoint_items(), { title = "Breakpoints" })
end

-- List every breakpoint in a named list (so selecting one jumps to that file/line),
-- shown in its own bottom-dock tab. Adding/removing a breakpoint while it's open updates
-- it live (refresh-on-commit). A no-op (with a notice) when no breakpoint is set, so the
-- user isn't dropped into an empty window.
function M.list_breakpoints()
  if #M._breakpoint_items() == 0 then
    btv.notify("bemtvi-dap: no breakpoints set", 2)
    return
  end
  M._refresh_breakpoint_list()
  btv.qf.show(BP_LIST)
end

-- ----- UI surfaces -----------------------------------------------------------

function M.repl_toggle()
  repl.toggle()
end
function M.sidebar_toggle()
  ui.toggle()
end
function M.eval(expr)
  repl.open()
  if expr and expr ~= "" then
    repl.eval(expr)
  else
    repl.prompt()
  end
end

-- ----- setup -----------------------------------------------------------------

local COMMANDS = {
  { "DapStepOver", "step_over", "Step over" },
  { "DapStepInto", "step_into", "Step into" },
  { "DapStepOut", "step_out", "Step out" },
  { "DapPause", "pause", "Pause execution" },
  { "DapRestart", "restart", "Restart the active session" },
  { "DapTerminate", "terminate", "Terminate the active debug session" },
  { "DapTerminateAll", "terminate_all", "Terminate every debug session" },
  { "DapSessions", "pick_session", "Switch the active session" },
  { "DapToggleBreakpoint", "toggle_breakpoint", "Toggle a breakpoint at the cursor" },
  { "DapBreakpointCondition", "set_breakpoint_condition", "Set a conditional breakpoint" },
  { "DapLogPoint", "set_log_point", "Set a log point" },
  { "DapEditBreakpoint", "edit_breakpoint", "Edit the breakpoint at the cursor" },
  { "DapBreakpoints", "list_breakpoints", "List all breakpoints in a named list" },
  { "DapClearBreakpoints", "clear_breakpoints", "Remove every breakpoint" },
  { "DapExceptionBreakpoints", "set_exception_breakpoints", "Pick exception breakpoint filters" },
  { "DapWatchClear", "clear_watches", "Remove every watch expression" },
  { "DapReplToggle", "repl_toggle", "Toggle the debug REPL" },
  { "DapSidebarToggle", "sidebar_toggle", "Toggle the scopes/stack sidebar" },
}

local MAP_ACTIONS = {
  continue = M.continue,
  step_over = M.step_over,
  step_into = M.step_into,
  step_out = M.step_out,
  restart = M.restart,
  toggle_breakpoint = M.toggle_breakpoint,
  toggle_breakpoint_condition = M.set_breakpoint_condition,
  edit_breakpoint = M.edit_breakpoint,
  repl_toggle = M.repl_toggle,
  sidebar_toggle = M.sidebar_toggle,
  terminate = M.terminate,
}

-- setup() is re-runnable: a full reconfigure merged fresh from the defaults.
function M.setup(opts)
  M.config = config_mod.merge(config_mod.defaults(), opts or {})

  -- Seed registries from opts (and keep the live tables for direct assignment).
  for k, v in pairs(M.config.adapters or {}) do
    M.adapters[k] = v
  end
  for k, v in pairs(M.config.configurations or {}) do
    M.configurations[k] = v
  end

  -- Re-applied on every setup() (it IS a full reconfigure, so a changed `highlights`
  -- must take effect). Re-applying is safe: a default only fills a group the
  -- colorscheme left undefined, so this never overrides a theme.
  highlights.apply(M.config.highlights)

  signs.setup(M.config.signs)
  ui.setup(M.config)
  repl.setup(M.config)

  -- Push breakpoint changes to every live, configured session — not just the active
  -- one, which would leave the others debugging a stale breakpoint set.
  breakpoints.on_change = function(path, bps)
    for _, s in ipairs(M._live_sessions()) do
      s:set_breakpoints(path, bps)
    end
  end

  -- React to a settled breakpoint change: persist it (workspace only) and repaint an
  -- open breakpoints list. Persistence is gated to a `--workspace` launch — breakpoints
  -- are project state, and the shared global store would mix every project's together
  -- (and never know which to restore). The plugin shada is loaded before init.lua runs,
  -- so the saved set is already in hand here — restore it once (a re-run of setup() must
  -- not wipe live breakpoints). The list refresh runs regardless of workspace.
  local store = btv.workspace.active() and btv.shada.plugin() or nil
  if store and not bp_restored then
    breakpoints.restore(store:get("breakpoints"))
    bp_restored = true
  end
  breakpoints.on_commit = function()
    if store then
      store:set("breakpoints", breakpoints.list())
    end
    M._refresh_breakpoint_list()
  end

  -- Wire the sidebar's callbacks into the cross-session state init.lua owns: source
  -- jumps, the exception-filter selection, and the session switcher.
  ui.on_jump = jump
  ui.is_exception_selected = M.is_exception_selected
  ui.on_toggle_exception = M.toggle_exception_filter
  ui.sessions_provider = function()
    return M.sessions(), M._session
  end
  ui.on_select_session = M.set_active_session

  for _, c in ipairs(COMMANDS) do
    local name, fn_name, desc = c[1], c[2], c[3]
    btv.command(name, function()
      M[fn_name]()
    end, { desc = desc })
  end
  -- `:DapContinue [config]` — the launch command takes an optional configuration name,
  -- completed from the current filetype's configurations, so `<Tab>` lists them.
  btv.command("DapContinue", function(ev)
    M.continue(ev and ev.args)
  end, {
    usage = "[config]",
    desc = "Start or resume debugging. [config] launches a named configuration "
      .. "(<Tab>-completes the current filetype's); no arg resumes a stopped session "
      .. "or picks from the available configs.",
    complete = function()
      return M._configuration_names()
    end,
  })
  btv.command("DapEval", function(ev)
    M.eval(ev and ev.args)
  end, {
    usage = "[expr]",
    desc = "Evaluate [expr] in the stopped frame. No arg opens the REPL prompt instead.",
  })
  btv.command("DapWatch", function(ev)
    M.add_watch(ev and ev.args)
  end, {
    usage = "[expr]",
    desc = "Add a watch for [expr]. No arg prompts for one.",
  })

  -- Default keymaps (any false entry, or `mappings = false`, disables it). An entry's
  -- value is a single lhs string, or a list of lhs strings that all fire the action
  -- (so an F-key action can also bind its Shift variant — <F5> and <S-F5>).
  --
  -- setup() is a full reconfigure, so the keys installed by a PREVIOUS setup are
  -- dropped first: re-running it with a different (or disabled) `mappings` must not
  -- leave the old bindings behind.
  for _, key in ipairs(installed_maps) do
    pcall(btv.keymap.del, "n", key)
  end
  installed_maps = {}
  if M.config.mappings ~= false then
    for action, lhs in pairs(M.config.mappings) do
      if lhs and MAP_ACTIONS[action] then
        local keys = type(lhs) == "table" and lhs or { lhs }
        for _, key in ipairs(keys) do
          btv.keymap.set("n", key, MAP_ACTIONS[action], { desc = "bemtvi-dap: " .. action })
          installed_maps[#installed_maps + 1] = key
        end
      end
    end
  end

  -- Repaint breakpoint signs when a buffer opens (so signs set while it was closed
  -- appear), and on the next tick after setup for already-open buffers. Only the
  -- ENTERED buffer is repainted — a full sweep on every BufEnter would re-mark every
  -- file that has a breakpoint each time you switch buffers.
  if not autocmds_wired then
    local grp = btv.augroup.create("bemtvi-dap", { clear = true })
    btv.autocmd.create("BufEnter", {
      group = grp,
      callback = function(ev)
        breakpoints.render_buf(ev and ev.buf)
      end,
    })
    autocmds_wired = true
  end
  btv.on_next_tick(function()
    breakpoints.render_all()
  end)

  return M
end

-- Expose internals for tests / advanced users.
M.breakpoints = breakpoints
M.signs = signs
M.ui = ui
M.repl = repl
M.variables = variables

return M
