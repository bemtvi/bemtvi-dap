-- The fallback highlight palette. Each group goes in through `btv.hl.fallback`, so a
-- colorscheme that already styles the canonical `Dap*` / `NvimDap*`-style names (or
-- the user's `opts.highlights`) always wins regardless of load order — the same
-- fallback discipline bemtvi-tree uses for `NvimTree*`.
--
-- The colours are DERIVED from the active theme via `btv.hl.palette()`, so the
-- breakpoints, the sidebar and the REPL read as part of whatever colorscheme is loaded
-- (bemtvi's own by default, a light flavour as well as a dark one). `defaults()` is a
-- function re-evaluated on every apply, and bemtvi-dap re-applies on `ColorScheme`. The
-- stopped line's `bg` is the stop colour faded into the theme's background
-- (`btv.hl.blend`), so it tints the row without drowning the text.

local M = {}

-- defaults() -> group -> spec (btv.hl.define spec: fg/bg/bold/italic/…) for the active
-- theme.
function M.defaults()
  local p = btv.hl.palette()
  return {
    BtvDapBreakpoint = { fg = p.red },
    BtvDapBreakpointCondition = { fg = p.orange },
    BtvDapBreakpointRejected = { fg = p.muted },
    BtvDapLogPoint = { fg = p.blue },
    BtvDapStopped = { fg = p.yellow },
    BtvDapStoppedLine = { bg = btv.hl.blend(p.yellow, p.bg, 0.2) },
    -- Sidebar / REPL.
    BtvDapUIScope = { fg = p.blue, bold = true },
    BtvDapUIThread = { fg = p.green, bold = true },
    BtvDapUIFrame = { fg = p.purple },
    BtvDapUIFrameCurrent = { fg = p.yellow, bold = true },
    BtvDapUIVarName = { fg = p.cyan },
    BtvDapUIVarType = { fg = p.muted, italic = true },
    BtvDapUIValue = { fg = p.fg },
    BtvDapUIDecoration = { fg = p.muted },
    BtvDapReplPrompt = { fg = p.green, bold = true },
    BtvDapReplError = { fg = p.red },
  }
end

-- Apply the palette: an override always defines; a default only fills a group the
-- colorscheme left undefined (or that still holds the default derived from the last
-- theme). Safe to re-run on `ColorScheme`.
function M.apply(overrides)
  overrides = overrides or {}
  local defaults = M.defaults()
  for name, spec in pairs(defaults) do
    if overrides[name] then
      btv.hl.define(0, name, overrides[name])
    else
      btv.hl.fallback(name, spec)
    end
  end
  for name, spec in pairs(overrides) do
    if not defaults[name] then
      btv.hl.define(0, name, spec)
    end
  end
end

return M
