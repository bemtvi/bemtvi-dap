# nxvim-dap

A **Debug Adapter Protocol** client for [nxvim](https://github.com/davidrios/nxvim) —
the nxvim sibling of [nvim-dap](https://github.com/mfussenegger/nvim-dap).

It is built entirely on the native `nx.*` plugin API (ADR 0002): no buffer-mutation
hacks, no bespoke rendering loop. A debug adapter is a long-lived child that speaks
[Content-Length-framed JSON](https://microsoft.github.io/debug-adapter-protocol/) over
stdio — exactly like a language server — so nxvim-dap rides nxvim's **duplex process**
primitive `nx.process`, frames the wire itself, paints breakpoint / stopped signs with
extmarks, and renders the scopes/stack sidebar and REPL on read-only `nx.view` docks. The
breakpoints live in real editor buffers; the panels own their own lines. That's the
point: a real debugger front end, written the way a plugin author would write it.

```
  ●  def fib(n):
  ▶      a, b = 0, 1          ← stopped here
         for _ in range(n):

  ┌ SCOPES ───────────────┐
  │ Locals                │
  │   x = 42              │
  └───────────────────────┘
```

Breakpoints (conditional / hit / log + exception filters), stepping and restart, a
scopes/stack/watches sidebar with inline value editing, multiple concurrent sessions, and
a REPL — all on `nx.*`. Two adapter transports: `type = "executable"` (a duplex stdio
child over `nx.process`) and `type = "server"` (a TCP connection over `nx.socket`,
optionally launching the adapter first).

## Install

Declare it with the built-in `:Plugins` manager, then `:PluginSync`:

```lua
nx.plugins({
  {
    "davidrios/nxvim-dap",
    config = function()
      local dap = require("nxvim-dap")
      dap.setup({})

      -- An adapter (HOW to reach a debug adapter) …
      dap.adapters.python = {
        type = "executable",
        command = "python3",
        args = { "-m", "debugpy.adapter" },
      }
      -- … and a configuration per filetype (WHAT to debug).
      dap.configurations.python = {
        { type = "python", request = "launch", name = "Launch file", program = "${file}" },
      }
    end,
  },
})
```

Then press `<F5>` (or `:DapContinue`) in a Python file.

> The REPL prompt and breakpoint conditions need nxvim's `nx.ui.input`; the adapter
> transport needs the native `nx.process` (a desktop/daemon session, not the serverless
> wasm build).

## Documentation

Full docs — `setup()` and every option, the `adapters` / `configurations` model,
variable expansion (incl. `${input:…}` / `${command:…}`), the commands and default
mappings, the sidebar / REPL, the public API, and the highlight groups — live in the help
file. The same source renders both on GitHub and in the editor:

- In editor: `:help nxvim-dap`
- On GitHub: [doc/nxvim-dap.md](./doc/nxvim-dap.md) (the help source)

## Trying it locally

This repo ships a runnable demo with a **self-contained mock adapter** (no debugger
install needed):

```sh
NXVIM_CONFIG=examples nxvim examples/sample/fib.py
```

(run from the repo root). Toggle a breakpoint with `<leader>db`, hit `<F5>`, and watch
the stopped sign, the sidebar, and the REPL.

## Development

A Lua test suite (`test/*_spec.lua`) runs on nxvim's native `nx.test` framework. The
protocol logic (framing, the session handshake, the stopped drill-down, stepping) is
covered against a fake transport; one end-to-end spec drives the whole client against a
**real adapter subprocess** (`test/support/mock_adapter.py`) over `nx.process`:

```sh
nxvim --test-plugin .
```

(The end-to-end spec needs `python3` for the mock adapter; the rest are pure Lua.)

The vimdoc `doc/nxvim-dap.txt` is **generated** from `doc/nxvim-dap.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand.

## License

MIT © David Rios
