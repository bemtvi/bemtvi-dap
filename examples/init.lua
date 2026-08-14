-- ~~~ Runnable demo for bemtvi-dap ~~~
--
-- Run it from the repo root:
--
--     BEMTVI_CONFIG=examples bemtvi examples/sample/fib.py
--
-- It wires a SELF-CONTAINED mock debug adapter (examples/mock_adapter.py — a scripted
-- DAP server, no debugger install needed) so the whole flow is driveable offline.
--
-- TRY IT interactively:
--   <leader>db / :DapToggleBreakpoint   toggle a breakpoint on the cursor line
--   <leader>dB / :DapBreakpointCondition  set a conditional breakpoint
--   <leader>de / :DapEditBreakpoint     edit condition / hit count / log message
--   <F5>       / :DapContinue           start debugging (or resume when stopped)
--   <F6>       / :DapRestart            restart the active session
--   <F10>/<F11>/<F12>                   step over / into / out
--   <leader>dr / :DapReplToggle         toggle the debug REPL (i / <CR> opens the prompt;
--                                       it stays open — <CR> evaluates, <Esc> closes)
--   <leader>du / :DapSidebarToggle      toggle the scopes / stack sidebar
--   <leader>dx / :DapTerminate          end the session
--   :DapWatch <expr>                    add a watch (or press `a` in the sidebar)
--   :DapExceptionBreakpoints            pick exception filters (toggle with <CR>)
--   :DapSessions                        switch the active session (run :DapContinue
--                                       twice for two concurrent mock sessions)
--
-- The mock "stops" at line 2 of the program, single-steps to line 3, and finishes on
-- continue — enough to watch the stopped sign, the sidebar (a `Locals` scope with
-- `x = 42`, a WATCHES section, EXCEPTIONS checkboxes), the REPL (`>` evaluates against
-- the frame), and teardown. In the sidebar: `<CR>` expands a variable / jumps to a
-- frame / toggles an exception filter, `e` edits a value (setVariable), `a` adds a
-- watch, `x` removes one, `r` refreshes.
--
-- A REAL setup would instead register e.g. debugpy (see the commented block below).
-- The leader is space here; set it before anything maps <leader>.
vim.g.mapleader = " "

local here = vim.fn.expand("<sfile>:p:h") -- the examples/ dir

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned).
btv.plugins({
  {
    name = "bemtvi-dap",
    dir = vim.fn.fnamemodify(here, ":h"), -- the repo root (examples/'s parent)
    config = function()
      local dap = require("bemtvi-dap")
      dap.setup({
        -- Auto-open the REPL + sidebar so the playground isn't empty when you stop.
        repl = { open_on_start = true },
        sidebar = { open_on_stopped = true },
      })

      -- The bundled mock adapter: a duplex stdio child, spoken over btv.process.
      dap.adapters.mock = {
        type = "executable",
        command = "python3",
        args = { here .. "/mock_adapter.py" },
      }

      -- One launch configuration for Python files, pointed at the sample program.
      dap.configurations.python_mock = {
        {
          type = "mock",
          request = "launch",
          name = "Debug fib.py (mock)",
          program = here .. "/sample/fib.py",
        },
      }

      -- A real adapter, for reference (uncomment + `pip install debugpy`) ----
      dap.adapters.python = {
        type = "executable",
        command = "python3",
        args = { "-m", "debugpy.adapter" },
      }
      dap.configurations.python = {
        {
          type = "python",
          request = "launch",
          name = "launch file",
          program = "${file}",
          console = "integratedTerminal",
        },
      }
    end,
  },
})
