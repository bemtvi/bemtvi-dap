-- Auto-loaded when the plugin is on the runtimepath (sourced from `plugin/` like a
-- neovim plugin). Registers the :Dap* commands + default keymaps with defaults so it
-- works out of the box; setup() is a full reconfigure, so a user calling
-- require("bemtvi-dap").setup({...}) from their init.lua just re-applies options.
--
-- Adapters / configurations are NOT seeded here (there's no universal debugger): add
-- them via `require("bemtvi-dap").adapters` / `.configurations` or `setup{ adapters=,
-- configurations= }` — see the README.
require("bemtvi-dap").setup({})
