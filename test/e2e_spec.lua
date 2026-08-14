-- End-to-end: the whole client against a REAL debug adapter subprocess (a scripted
-- DAP server, test/support/mock_adapter.py) spoken over `btv.process` — the same
-- duplex-stdio path a real adapter uses. This proves the integration the fake-
-- transport session_spec can't: framing over a live pipe, the launch handshake,
-- breakpoint sync, the stopped drill-down, stepping, evaluate, and teardown.
--
-- Needs `python3` on PATH (the mock's interpreter). If your environment lacks it,
-- this is the only spec that won't run; the protocol logic is covered hermetically
-- by rpc_spec / session_spec.

local dap = require("bemtvi-dap")

-- The plugin root: the runner puts `<root>/lua/?.lua` first on package.path (the
-- runtimepath drives module search), so the mock adapter resolves beneath it.
-- (debug.getinfo / vim.o.runtimepath are unreliable here — specs are sourced as
-- strings, and the test runtime leaves vim.o.runtimepath nil.)
local ROOT = package.path:match("(.-)/lua/%?%.lua") or "."
local MOCK = ROOT .. "/test/support/mock_adapter.py"

local function setup_session(t, prog)
  dap.setup({ jump_to_stopped = true })
  dap.adapters.mock = { command = "python3", args = { MOCK } }
  dap.configurations.btvdapmock = {
    { type = "mock", request = "launch", name = "mock launch", program = prog },
  }
  dap.run({ type = "mock", request = "launch", name = "mock launch", program = prog })
end

local function wait_stopped(t, line)
  t:wait_for(function()
    local s = dap.session()
    return s
      and s.stopped_thread_id ~= nil
      and s.current_frame ~= nil
      and s.current_frame.line == line
  end, { tries = 300, interval = 20, message = "session did not stop at line " .. tostring(line) })
end

btv.test.describe("bemtvi-dap end-to-end (real adapter over btv.process)", function()
  -- The --test-plugin runner doesn't source `plugin/`, so set the plugin up first
  -- (signs/ui/repl need their config) before any breakpoint toggle.
  btv.test.before_each(function()
    dap.setup({ jump_to_stopped = true })
  end)

  btv.test.it("launches, hits a breakpoint, steps, evaluates, and terminates", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/prog.py"
    btv.await(btv.fs.write(prog, "a = 1\nb = 2\nc = 3\n"))
    t:cmd("edit " .. prog)

    -- Toggle a breakpoint on line 2.
    t:feed("2G")
    dap.toggle_breakpoint()
    btv.test.expect(dap.breakpoints.list()[dap.signs.abspath(prog)]).never.to_be_nil()
    btv.test.expect(dap.breakpoints.list()[dap.signs.abspath(prog)][1].line).to_be(2)

    -- Launch the adapter; it stops at line 2.
    setup_session(t, prog)
    wait_stopped(t, 2)

    local s = dap.session()
    btv.test.expect(s.current_frame.name).to_be("main")
    btv.test.expect(s.capabilities.supportsConfigurationDoneRequest).to_be_truthy()

    -- The stopped marker landed in the source buffer (a sign in its namespace).
    local stopped_ns = btv.ns.create("bemtvi-dap-stopped")
    local marks = btv.buf.extmarks(dap.signs.path_bufnr(prog), stopped_ns, 0, -1)
    btv.test.expect(#marks).never.to_be(0)

    -- ...and it tints the line with a full-width `line_hl_group` background rather than
    -- a char-range span over the text. The distinction is load-bearing, not cosmetic: a
    -- range span joins the winner-takes-cell resolution and so loses every cell a syntax
    -- span covers, which left the stopped line tinted only in its uncoloured gaps.
    local detailed =
      btv.buf.extmarks(dap.signs.path_bufnr(prog), stopped_ns, 0, -1, { details = true })
    local d = detailed[1] and detailed[1][4] or {}
    btv.test.expect(d.line_hl_group).to_be("BtvDapStoppedLine")
    btv.test.expect(d.end_col).to_be_nil()

    -- Evaluate an expression in the stopped frame over the live adapter.
    local evaluated
    s:evaluate("1+1", s.current_frame.id, "repl", function(err, body)
      evaluated = err and ("ERR:" .. tostring(err.message)) or body.result
    end)
    t:wait_for(function()
      return evaluated
    end, { tries = 200, interval = 20, message = "evaluate did not return" })
    btv.test.expect(evaluated).to_be("1+1 => ok")

    -- Step over → the adapter stops again at line 3.
    dap.step_over()
    wait_stopped(t, 3)
    btv.test.expect(dap.session().current_frame.line).to_be(3)

    -- Continue → the adapter terminates; the plugin tears the session down.
    dap.continue()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })

    -- The stopped marker is cleared on teardown.
    local cleared = btv.buf.extmarks(dap.signs.path_bufnr(prog), stopped_ns, 0, -1)
    btv.test.expect(#cleared).to_be(0)
  end)

  btv.test.it("resolves scopes and variables from the live adapter", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/prog2.py"
    btv.await(btv.fs.write(prog, "x = 1\ny = 2\n"))
    t:cmd("edit " .. prog)

    setup_session(t, prog)
    wait_stopped(t, 2)

    local scopes
    dap.session():frame_scopes(dap.session().current_frame.id, function(s)
      scopes = s
    end)
    t:wait_for(function()
      return scopes
    end, { tries = 200, interval = 20, message = "scopes did not resolve" })
    btv.test.expect(#scopes).to_be(1)
    btv.test.expect(scopes[1].name).to_be("Locals")
    btv.test.expect(scopes[1].variables[1].name).to_be("x")
    btv.test.expect(scopes[1].variables[1].value).to_be("42")

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("expands ${file} in the launch configuration before launch", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/expand_me.py"
    btv.await(btv.fs.write(prog, "x = 1\n"))
    t:cmd("edit " .. prog)

    dap.setup({})
    dap.adapters.mock = { command = "python3", args = { MOCK } }
    -- Launch with program = "${file}" — it must reach the adapter as the resolved path.
    dap.run({ type = "mock", request = "launch", name = "expand", program = "${file}" })
    wait_stopped(t, 2)

    local abs = dap.signs.abspath(prog)
    -- The session stored the EXPANDED config (no literal ${file} left).
    btv.test.expect(dap.session().config.program).to_be(abs)
    -- And the adapter received it: the mock echoes `program` as the frame's source path.
    btv.test.expect(dap.session().current_frame.source.path).to_be(abs)

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("prompts for an ${input:…} and launches with the answer", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/in.py"
    btv.await(btv.fs.write(prog, "x = 1\n"))

    dap.setup({})
    dap.adapters.mock = { command = "python3", args = { MOCK } }
    -- `program` references an input; M.run prompts, then launches with the answer.
    dap.run({
      type = "mock",
      request = "launch",
      name = "prompted",
      program = "${input:prog}",
      inputs = { { id = "prog", type = "promptString", description = "Program" } },
    })
    t:feed(prog .. "<CR>") -- answer the prompt with the real path
    wait_stopped(t, 2)

    btv.test.expect(dap.session().config.program).to_be(prog)
    btv.test.expect(dap.session().config.inputs).to_be_nil() -- a UI-only field, stripped
    -- The adapter received the resolved path (echoed as the frame's source).
    btv.test.expect(dap.session().current_frame.source.path).to_be(prog)

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("resolves a ${command:…} from a registered command at launch", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/cmd.py"
    btv.await(btv.fs.write(prog, "x = 1\n"))

    dap.setup({})
    dap.adapters.mock = { command = "python3", args = { MOCK } }
    dap.register_command("pickProgram", function()
      return prog
    end)
    dap.run({
      type = "mock",
      request = "launch",
      name = "via-command",
      program = "${command:pickProgram}",
    })
    wait_stopped(t, 2)
    btv.test.expect(dap.session().config.program).to_be(prog)
    btv.test.expect(dap.session().current_frame.source.path).to_be(prog)

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("sets a variable's value over the live adapter (setVariable)", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/v.py"
    btv.await(btv.fs.write(prog, "x = 1\n"))
    t:cmd("edit " .. prog)

    setup_session(t, prog)
    wait_stopped(t, 2)
    local s = dap.session()
    btv.test.expect(s.capabilities.supportsSetVariable).to_be_truthy()

    local scopes
    s:frame_scopes(s.current_frame.id, function(sc)
      scopes = sc
    end)
    t:wait_for(function()
      return scopes
    end, { tries = 200, interval = 20, message = "scopes did not resolve" })

    -- Set x = 99 in its Locals container; the mock mutates and the re-read reflects it.
    local set_err = "pending"
    s:set_variable(scopes[1].variablesReference, "x", "99", function(e)
      set_err = e
    end)
    t:wait_for(function()
      return set_err ~= "pending"
    end, { tries = 200, interval = 20, message = "setVariable did not reply" })
    btv.test.expect(set_err).to_be_nil()

    local scopes2
    s:frame_scopes(s.current_frame.id, function(sc)
      scopes2 = sc
    end)
    t:wait_for(function()
      return scopes2
    end, { tries = 200, interval = 20, message = "re-read did not resolve" })
    local val
    for _, v in ipairs(scopes2[1].variables) do
      if v.name == "x" then
        val = v.value
      end
    end
    btv.test.expect(val).to_be("99")

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("renders watches + exception filters in the live sidebar", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/w.py"
    btv.await(btv.fs.write(prog, "x = 1\ny = 2\n"))
    t:cmd("edit " .. prog)

    setup_session(t, prog)
    wait_stopped(t, 2)

    dap.sidebar_toggle() -- open the sidebar (installs its buffer-local action keys)
    dap.add_watch("1+1")

    -- The watch is evaluated against the stopped frame (mock: "<expr> => ok"), and the
    -- exception filters render as checkbox rows.
    local function sidebar_text()
      local buf = dap.ui.bufnr()
      if not buf then
        return ""
      end
      return table.concat(btv.buf.lines(buf, 0, -1, false), "\n")
    end
    t:wait_for(function()
      local text = sidebar_text()
      return text:find("1+1 = 1+1 => ok", 1, true) ~= nil
    end, { tries = 300, interval = 20, message = "watch value did not render" })

    local text = sidebar_text()
    btv.test.expect(text:find("WATCHES", 1, true)).never.to_be_nil()
    btv.test.expect(text:find("[x] Uncaught Exceptions", 1, true)).never.to_be_nil()
    btv.test.expect(text:find("[ ] Raised Exceptions", 1, true)).never.to_be_nil()

    dap.clear_watches()
    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("restarts the active session in place (restart request)", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/r.py"
    btv.await(btv.fs.write(prog, "a = 1\nb = 2\nc = 3\n"))
    t:cmd("edit " .. prog)

    setup_session(t, prog)
    wait_stopped(t, 2)
    dap.step_over()
    wait_stopped(t, 3)

    local s = dap.session()
    btv.test.expect(s.capabilities.supportsRestartRequest).to_be_truthy()
    dap.restart()
    -- Same session object, re-stopped back at line 2 (the mock resets on restart).
    t:wait_for(function()
      return dap.session() == s
        and s.stopped_thread_id ~= nil
        and s.current_frame
        and s.current_frame.line == 2
    end, { tries = 400, interval = 20, message = "session did not restart to line 2" })

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it(
    "restarts via terminate + relaunch when the restart request is unsupported",
    function(t)
      local dir = btv.test.tempdir()
      local prog = dir .. "/nr.py"
      btv.await(btv.fs.write(prog, "a = 1\nb = 2\nc = 3\n"))
      t:cmd("edit " .. prog)

      dap.setup({})
      dap.adapters.norestart = { command = "python3", args = { MOCK, "--no-restart" } }
      dap.run({ type = "norestart", request = "launch", name = "no-restart", program = prog })
      wait_stopped(t, 2)
      local first = dap.session()
      btv.test.expect(first.capabilities.supportsRestartRequest).to_be(false)

      dap.restart()
      -- A brand-new session replaces the old one (different object), stopped at line 2.
      t:wait_for(function()
        local s = dap.session()
        return s ~= nil
          and s ~= first
          and s.stopped_thread_id ~= nil
          and s.current_frame
          and s.current_frame.line == 2
      end, { tries = 500, interval = 20, message = "session did not relaunch" })
      btv.test.expect(#dap.sessions()).to_be(1)

      dap.terminate()
      t:wait_for(function()
        return dap.session() == nil
      end, { tries = 300, interval = 20, message = "session did not terminate" })
    end
  )

  btv.test.it("runs two concurrent sessions and switches the active one", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/c.py"
    btv.await(btv.fs.write(prog, "x = 1\ny = 2\n"))
    t:cmd("edit " .. prog)

    dap.setup({})
    dap.adapters.mock = { command = "python3", args = { MOCK } }
    dap.run({ type = "mock", request = "launch", name = "A", program = prog })
    dap.run({ type = "mock", request = "launch", name = "B", program = prog })
    btv.test.expect(#dap.sessions()).to_be(2)

    t:wait_for(function()
      local n = 0
      for _, s in ipairs(dap.sessions()) do
        if s.stopped_thread_id then
          n = n + 1
        end
      end
      return n == 2
    end, { tries = 400, interval = 20, message = "both sessions did not stop" })

    -- The most-recently-stopped session is active; switch to the other.
    local list = dap.sessions()
    dap.set_active_session(list[2])
    btv.test.expect(dap.session()).to_be(list[2])

    dap.terminate_all()
    t:wait_for(function()
      return dap.session() == nil and #dap.sessions() == 0
    end, { tries = 400, interval = 20, message = "sessions did not all terminate" })
  end)

  btv.test.it("reflects + toggles exception breakpoint filters over the live adapter", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/e.py"
    btv.await(btv.fs.write(prog, "x = 1\n"))
    t:cmd("edit " .. prog)

    dap.exception_filters = nil -- start from the adapter defaults
    setup_session(t, prog)
    wait_stopped(t, 2)

    -- The adapter advertises raised (off by default) + uncaught (on by default).
    btv.test.expect(dap.is_exception_selected("uncaught")).to_be(true)
    btv.test.expect(dap.is_exception_selected("raised")).to_be(false)

    -- Toggle raised on; the selection updates and the live set round-trips.
    dap.toggle_exception_filter("raised")
    btv.test.expect(dap.is_exception_selected("raised")).to_be(true)

    local err = "pending"
    dap.session():set_exception_breakpoints({ "raised", "uncaught" }, function(e)
      err = e
    end)
    t:wait_for(function()
      return err ~= "pending"
    end, { tries = 200, interval = 20, message = "setExceptionBreakpoints did not reply" })
    btv.test.expect(err).to_be_nil()

    dap.exception_filters = nil
    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  btv.test.it("connects to a server (TCP) adapter and runs the same flow", function(t)
    local dir = btv.test.tempdir()
    local prog = dir .. "/prog3.py"
    btv.await(btv.fs.write(prog, "x = 1\ny = 2\n"))
    local port_file = dir .. "/port"

    -- Launch the mock in server mode: it binds an ephemeral TCP port and writes it to
    -- port_file. (The test owns the process; the adapter config has no `executable`,
    -- so the plugin just connects.)
    local server = btv.process.open({
      cmd = "python3",
      args = { MOCK, "--listen", "--port-file", port_file },
    })

    -- Poll for the announced port (the file appears once the server is bound).
    local port
    for _ = 1, 200 do
      local ok, data = pcall(function()
        return btv.await(btv.fs.read_text(port_file))
      end)
      if ok and data and tonumber(data) then
        port = tonumber(data)
        break
      end
      btv.await(btv.promise.delay(20))
    end
    btv.test.expect(port).never.to_be_nil()

    t:cmd("edit " .. prog)
    dap.adapters.srv = { type = "server", host = "127.0.0.1", port = port }
    dap.run({ type = "srv", request = "launch", name = "srv launch", program = prog })

    wait_stopped(t, 2)
    btv.test.expect(dap.session().current_frame.name).to_be("main")
    btv.test.expect(dap.session().capabilities.supportsConfigurationDoneRequest).to_be_truthy()

    -- Step + continue work the same over the socket.
    dap.step_over()
    wait_stopped(t, 3)

    dap.continue()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "server session did not terminate" })

    server:kill()
  end)
end)
