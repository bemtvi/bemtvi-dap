-- The default colours come from the active theme (btv.hl.palette, and the stopped
-- line's tint blended into its background) and follow a theme switch; a theme's own
-- groups and the user's overrides win.
local dap = require("bemtvi-dap")

local function hex(group, attr)
  local d = btv.hl.get(0, { name = group, link = false })
  return d[attr] and string.format("#%06x", d[attr]) or nil
end

-- A minimal theme: the groups the palette reads, and nothing of the debugger's own.
local function theme(t, colors)
  t:cmd("hi clear")
  btv.hl.define(0, "Normal", { fg = colors.fg, bg = colors.bg })
  btv.hl.define(0, "Added", { fg = colors.green })
  btv.hl.define(0, "DiagnosticError", { fg = colors.red })
  btv.hl.define(0, "Type", { fg = colors.yellow })
  btv.hl.define(0, "Function", { fg = colors.blue })
  btv.hl.define(0, "Comment", { fg = colors.muted })
  t:cmd("doautocmd ColorScheme")
end

local DARK = {
  fg = "#dddddd",
  bg = "#101010",
  green = "#00c000",
  red = "#c00000",
  yellow = "#c0c000",
  blue = "#0000c0",
  muted = "#808080",
}
local LIGHT = {
  fg = "#202020",
  bg = "#f0f0f0",
  green = "#008000",
  red = "#800000",
  yellow = "#808000",
  blue = "#000080",
  muted = "#606060",
}

btv.test.describe("bemtvi-dap highlights", function()
  btv.test.it("derives its defaults from the active theme", function(t)
    theme(t, DARK)
    dap.setup({})
    local p = btv.hl.palette()
    btv.test.expect(hex("BtvDapBreakpoint", "fg")).to_be(p.red)
    btv.test.expect(hex("BtvDapBreakpointRejected", "fg")).to_be(p.muted)
    btv.test.expect(hex("BtvDapStopped", "fg")).to_be(p.yellow)
    btv.test.expect(hex("BtvDapUIScope", "fg")).to_be(p.blue)
    btv.test.expect(hex("BtvDapReplPrompt", "fg")).to_be(p.green)
    btv.test.expect(hex("BtvDapUIValue", "fg")).to_be(p.fg)
    -- The stopped line is the stop colour faded into the theme's background.
    btv.test.expect(hex("BtvDapStoppedLine", "bg")).to_be(btv.hl.blend(p.yellow, p.bg, 0.2))
  end)

  btv.test.it("follows a theme switch, light flavour included", function(t)
    theme(t, DARK)
    dap.setup({})
    theme(t, LIGHT)
    local p = btv.hl.palette()
    btv.test.expect(hex("BtvDapBreakpoint", "fg")).to_be(LIGHT.red)
    btv.test.expect(hex("BtvDapStoppedLine", "bg")).to_be(btv.hl.blend(p.yellow, p.bg, 0.2))
  end)

  btv.test.it("leaves a theme's own group alone", function(t)
    theme(t, DARK)
    btv.hl.define(0, "BtvDapBreakpoint", { fg = "#123456" })
    dap.setup({})
    btv.test.expect(hex("BtvDapBreakpoint", "fg")).to_be("#123456")
  end)

  btv.test.it("lets the user's override win, across a theme switch", function(t)
    theme(t, DARK)
    dap.setup({ highlights = { BtvDapBreakpoint = { fg = "#abcdef" } } })
    theme(t, LIGHT)
    btv.test.expect(hex("BtvDapBreakpoint", "fg")).to_be("#abcdef")
  end)
end)
