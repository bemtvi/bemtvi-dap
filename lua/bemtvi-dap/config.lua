-- bemtvi-dap configuration: the defaults, the adapter/configuration registries, and a
-- validated merge. Mirrors nvim-dap's two-table model so a ported debug setup reads
-- the same:
--
--   * `adapters[type]`        — HOW to reach a debug adapter (a process to spawn).
--   * `configurations[ft]`    — WHAT to debug for a filetype (launch/attach specs).
--
-- An adapter is one of:
--   * `{ type = "executable", command, args, env, cwd }` — a duplex child over
--     `btv.process` (the adapter speaks DAP on its own stdio).
--   * `{ type = "server", host, port, executable = { command, args, … } }` — a TCP
--     connection over `btv.socket`; the optional `executable` is launched first (it
--     opens the port) and the client connects to `host:port` (default 127.0.0.1),
--     retrying while it comes up. The nvim-dap "server" adapter.
--   * `function(callback, config)` — a resolver producing one of the above
--     dynamically (nvim-dap's enrich-on-launch hook).

local M = {}

-- The plugin-wide defaults (everything `setup()` understands except the registries,
-- which start empty and are filled by the user / a language extension).
function M.defaults()
  return {
    -- UI / sign appearance.
    signs = {
      breakpoint = { text = "●", hl = "BtvDapBreakpoint" },
      breakpoint_condition = { text = "◆", hl = "BtvDapBreakpointCondition" },
      breakpoint_rejected = { text = "○", hl = "BtvDapBreakpointRejected" },
      log_point = { text = "◇", hl = "BtvDapLogPoint" },
      stopped = { text = "▶", hl = "BtvDapStopped", line_hl = "BtvDapStoppedLine" },
    },
    -- The sidebar dock (threads / stack frames / scopes / variables / watches /
    -- exception filters / sessions).
    sidebar = {
      position = "right", -- "left" | "right"
      width = 40,
      open_on_stopped = true, -- auto-open the sidebar when execution stops
      -- Buffer-local keys inside the sidebar (false on an entry disables it). `<CR>`
      -- is fixed: it expands a variable, jumps to a frame, toggles an exception
      -- filter, or switches the active session, depending on the row.
      mappings = {
        edit = "e", -- set the value of the variable / watch under the cursor
        add_watch = "a", -- add a watch expression
        remove = "x", -- remove the watch under the cursor
        refresh = "r", -- re-evaluate scopes + watches for the current frame
      },
    },
    -- The REPL dock.
    repl = {
      position = "bottom", -- "bottom" | "left" | "right"
      height = 12,
      open_on_start = true, -- auto-open the REPL when a session starts
      -- Scrollback ceiling: the oldest lines are dropped past it, so a debuggee that
      -- logs in a loop can't grow the console (and the cost of repainting it) without
      -- bound. `0` or `false` lifts the cap.
      max_lines = 5000,
    },
    -- Default keymaps (false on any entry, or `mappings = false`, disables it). An
    -- entry can be a single lhs or a list; the F-key actions bind both the plain key
    -- and its Shift variant, since some terminals/keyboards send Shift+Fn.
    mappings = {
      continue = { "<F5>", "<S-F5>" },
      step_over = { "<F10>", "<S-F10>" },
      step_into = { "<F11>", "<S-F11>" },
      step_out = { "<F12>", "<S-F12>" },
      restart = { "<F6>", "<S-F6>" },
      toggle_breakpoint = "<leader>db",
      toggle_breakpoint_condition = "<leader>dB",
      edit_breakpoint = "<leader>de",
      repl_toggle = "<leader>dr",
      sidebar_toggle = "<leader>du",
      terminate = "<leader>dx",
    },
    -- Highlight-group overrides (merged over the fallback palette).
    highlights = {},
    -- Auto-jump the editor to the stopped frame's source line.
    jump_to_stopped = true,
    -- The adapter + configuration registries (filled via setup or the public
    -- `adapters` / `configurations` tables — see init.lua).
    adapters = {},
    configurations = {},
  }
end

-- Deep merge: `over` wins, maps recurse, everything else replaces. Lists
-- (`adapters`/`configurations` entries, `args`) replace wholesale — merging a list
-- positionally is never what a user means. An EMPTY override table counts as a map, so
-- `setup({})` keeps the base rather than wiping it.
--
-- That is exactly `btv.tbl.deep_extend("force", …)`'s rule, so this is a named alias for
-- it rather than a reimplementation.
local function merge(base, over)
  if type(base) ~= "table" or type(over) ~= "table" then
    return over == nil and base or over
  end
  return btv.tbl.deep_extend("force", base, over)
end

M.merge = merge

-- Validate an adapter spec, failing LOUD on anything bemtvi-dap can't honor (the
-- no-silent-stubs discipline — a "server" adapter must error at config time, not
-- silently never connect).
function M.validate_adapter(adapter, type_name)
  if type(adapter) == "function" then
    return -- a resolver: validated when it produces a concrete adapter
  end
  if type(adapter) ~= "table" then
    error(
      ("bemtvi-dap: adapter %q must be a table or function, got %s"):format(type_name, type(adapter))
    )
  end
  local kind = adapter.type or "executable"
  if kind == "executable" then
    if type(adapter.command) ~= "string" or adapter.command == "" then
      error(("bemtvi-dap: executable adapter %q needs a string `command`"):format(type_name))
    end
  elseif kind == "server" then
    if type(adapter.port) ~= "number" then
      error(("bemtvi-dap: server adapter %q needs a numeric `port`"):format(type_name))
    end
    if adapter.executable ~= nil then
      if type(adapter.executable) ~= "table" or type(adapter.executable.command) ~= "string" then
        error(
          ("bemtvi-dap: server adapter %q `executable` needs a string `command`"):format(type_name)
        )
      end
    end
  else
    error(("bemtvi-dap: adapter %q has unknown type=%q"):format(type_name, kind))
  end
end

-- Validate a launch/attach configuration. Returns it (so callers can `cfg =
-- validate_configuration(cfg)`), erroring on a missing required field.
function M.validate_configuration(cfg)
  if type(cfg) ~= "table" then
    error("bemtvi-dap: a configuration must be a table")
  end
  if type(cfg.type) ~= "string" then
    error("bemtvi-dap: a configuration needs a string `type` (the adapter key)")
  end
  if cfg.request ~= "launch" and cfg.request ~= "attach" then
    error(
      ("bemtvi-dap: configuration %q needs request='launch' or 'attach'"):format(
        cfg.name or cfg.type
      )
    )
  end
  if type(cfg.name) ~= "string" then
    error("bemtvi-dap: a configuration needs a string `name`")
  end
  return cfg
end

return M
