-- The fallback highlight palette. Defined only when a group is undefined, so a
-- colorscheme that already styles the canonical `Dap*` / `NvimDap*`-style names (or
-- the user's `opts.highlights`) always wins regardless of load order — the same
-- fallback discipline bemtvi-tree uses for `NvimTree*`.

local M = {}

-- group -> spec (btv.hl.define spec: fg/bg/bold/italic/…).
M.defaults = {
  BtvDapBreakpoint = { fg = "#e51400" },
  BtvDapBreakpointCondition = { fg = "#f9a825" },
  BtvDapBreakpointRejected = { fg = "#9e9e9e" },
  BtvDapLogPoint = { fg = "#2196f3" },
  BtvDapStopped = { fg = "#ffd54f" },
  BtvDapStoppedLine = { bg = "#3a3000" },
  -- Sidebar / REPL.
  BtvDapUIScope = { fg = "#7aa2f7", bold = true },
  BtvDapUIThread = { fg = "#9ece6a", bold = true },
  BtvDapUIFrame = { fg = "#bb9af7" },
  BtvDapUIFrameCurrent = { fg = "#ffd54f", bold = true },
  BtvDapUIVarName = { fg = "#7dcfff" },
  BtvDapUIVarType = { fg = "#565f89", italic = true },
  BtvDapUIValue = { fg = "#c0caf5" },
  BtvDapUIDecoration = { fg = "#565f89" },
  BtvDapReplPrompt = { fg = "#9ece6a", bold = true },
  BtvDapReplError = { fg = "#e51400" },
}

-- Apply the palette: an override always defines; a default only fills a group the
-- colorscheme left undefined.
function M.apply(overrides)
  overrides = overrides or {}
  for name, spec in pairs(M.defaults) do
    if overrides[name] then
      btv.hl.define(0, name, overrides[name])
    elseif not btv.hl.exists(name) then
      btv.hl.define(0, name, spec)
    end
  end
  for name, spec in pairs(overrides) do
    if not M.defaults[name] then
      btv.hl.define(0, name, spec)
    end
  end
end

return M
