-- The DAP session state machine, driven against a FAKE transport (no subprocess):
-- the initialize → launch → configurationDone handshake, request/response
-- correlation by seq, event dispatch, the stopped → threads → stackTrace → scopes
-- drill-down, and execution control. This is the protocol's faithful coverage; the
-- real-`btv.process` path is exercised separately in e2e_spec.

local session = require("bemtvi-dap.session")
local rpc = require("bemtvi-dap.rpc")

-- Decode one captured wire frame back to a table.
local function parse_frame(s)
  local msg
  rpc.decoder(function(m)
    msg = m
  end)(s)
  return msg
end

-- A harness: a session over a capturing transport, plus helpers to drive the adapter
-- side (feed it crafted messages) and inspect what the client sent.
local function harness(handlers)
  local sent = {} -- every decoded frame the client wrote, in order
  local h = handlers or {}
  local s = session.new({
    write = function(data)
      sent[#sent + 1] = parse_frame(data)
    end,
    close = function()
      h._closed = true
    end,
  }, h)
  local api = { session = s, sent = sent, handlers = h }
  -- Feed an adapter→client message into the session.
  function api.adapter(msg)
    s:feed(rpc.encode(msg))
  end
  -- The most recent request frame the client sent for `command`.
  function api.last(command)
    for i = #sent, 1, -1 do
      if sent[i].type == "request" and sent[i].command == command then
        return sent[i]
      end
    end
  end
  -- Respond (adapter side) to the client's request for `command`.
  function api.respond(command, body, success)
    local req = api.last(command)
    api.adapter({
      type = "response",
      request_seq = req.seq,
      success = success ~= false,
      command = command,
      body = body,
    })
  end
  return api
end

btv.test.describe("bemtvi-dap.session handshake", function()
  btv.test.it("opens with an initialize request carrying the adapter id", function()
    local hx = harness()
    hx.session:start({ type = "mock", request = "launch", name = "t", program = "p" })
    local init = hx.last("initialize")
    btv.test.expect(init).never.to_be_nil()
    btv.test.expect(init.arguments.adapterID).to_be("mock")
    btv.test.expect(init.arguments.linesStartAt1).to_be_truthy()
  end)

  btv.test.it("sends launch only after the initialize response", function()
    local hx = harness()
    hx.session:start({ type = "mock", request = "launch", name = "t", program = "p" })
    btv.test.expect(hx.last("launch")).to_be_nil() -- not yet
    hx.respond("initialize", { supportsConfigurationDoneRequest = true })
    local launch = hx.last("launch")
    btv.test.expect(launch).never.to_be_nil()
    btv.test.expect(launch.arguments.program).to_be("p")
  end)

  btv.test.it("configures (breakpoints + configurationDone) on the initialized event", function()
    local bps = { ["/tmp/a.py"] = { { line = 3 }, { line = 7, condition = "x>1" } } }
    local hx = harness({
      get_breakpoints = function()
        return bps
      end,
    })
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", { supportsConfigurationDoneRequest = true })
    hx.adapter({ type = "event", event = "initialized" })
    local sb = hx.last("setBreakpoints")
    btv.test.expect(sb).never.to_be_nil()
    btv.test.expect(sb.arguments.source.path).to_be("/tmp/a.py")
    btv.test.expect(#sb.arguments.breakpoints).to_be(2)
    btv.test.expect(sb.arguments.breakpoints[2].condition).to_be("x>1")
    -- configurationDone is held until the breakpoints are acknowledged (so the
    -- debuggee never resumes before they register), then sent.
    btv.test.expect(hx.last("configurationDone")).to_be_nil()
    hx.respond("setBreakpoints", { breakpoints = { { verified = true }, { verified = true } } })
    btv.test.expect(hx.last("configurationDone")).never.to_be_nil()
  end)

  btv.test.it("flips to running once configurationDone is acknowledged", function()
    local states = {}
    local hx = harness({
      on_state = function(st)
        states[#states + 1] = st
      end,
    })
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", { supportsConfigurationDoneRequest = true })
    hx.adapter({ type = "event", event = "initialized" })
    hx.respond("configurationDone", {})
    btv.test.expect(hx.session.initialized).to_be_truthy()
    btv.test.expect(states[#states]).to_be("running")
  end)
end)

btv.test.describe("bemtvi-dap.session stopped drill-down", function()
  local function running()
    local stopped_args, snapshot
    local hx = harness({
      on_stopped = function(body, snap)
        stopped_args, snapshot = body, snap
      end,
    })
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", { supportsConfigurationDoneRequest = true })
    hx.adapter({ type = "event", event = "initialized" })
    hx.respond("configurationDone", {})
    return hx, function()
      return stopped_args, snapshot
    end
  end

  btv.test.it("walks threads → stackTrace and hands the frames to on_stopped", function()
    local hx, result = running()
    hx.adapter({ type = "event", event = "stopped", body = { reason = "breakpoint", threadId = 1 } })
    -- The session asks for threads first.
    btv.test.expect(hx.last("threads")).never.to_be_nil()
    hx.respond("threads", { threads = { { id = 1, name = "main" } } })
    -- Then the stopped thread's stack.
    local st = hx.last("stackTrace")
    btv.test.expect(st.arguments.threadId).to_be(1)
    hx.respond("stackTrace", {
      stackFrames = {
        { id = 1000, name = "foo", line = 10, source = { path = "/tmp/a.py" } },
        { id = 1001, name = "main", line = 42, source = { path = "/tmp/a.py" } },
      },
    })
    local body, snap = result()
    btv.test.expect(body.reason).to_be("breakpoint")
    btv.test.expect(#snap.frames).to_be(2)
    btv.test.expect(snap.frames[1].name).to_be("foo")
    btv.test.expect(hx.session.current_frame.id).to_be(1000)
    btv.test.expect(hx.session.stopped_thread_id).to_be(1)
  end)

  btv.test.it("resolves scopes with one level of variables", function()
    local hx, result = running()
    hx.adapter({ type = "event", event = "stopped", body = { reason = "step", threadId = 1 } })
    hx.respond("threads", { threads = { { id = 1, name = "main" } } })
    hx.respond("stackTrace", { stackFrames = { { id = 1000, name = "foo", line = 10 } } })
    local _, snap = result()
    local scopes_out
    hx.session:frame_scopes(snap.frames[1].id, function(scopes)
      scopes_out = scopes
    end)
    hx.respond("scopes", { scopes = { { name = "Locals", variablesReference = 5 } } })
    hx.respond("variables", { variables = { { name = "x", value = "1", variablesReference = 0 } } })
    btv.test.expect(#scopes_out).to_be(1)
    btv.test.expect(scopes_out[1].name).to_be("Locals")
    btv.test.expect(scopes_out[1].variables[1].name).to_be("x")
  end)
end)

btv.test.describe("bemtvi-dap.session execution control", function()
  local function stopped_session()
    local continued = false
    local hx = harness({
      on_continued = function()
        continued = true
      end,
    })
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", { supportsConfigurationDoneRequest = true })
    hx.adapter({ type = "event", event = "initialized" })
    hx.respond("configurationDone", {})
    hx.adapter({ type = "event", event = "stopped", body = { reason = "breakpoint", threadId = 1 } })
    hx.respond("threads", { threads = { { id = 1, name = "main" } } })
    hx.respond("stackTrace", { stackFrames = { { id = 1000, name = "foo", line = 10 } } })
    return hx, function()
      return continued
    end
  end

  btv.test.it("step_over sends `next` for the stopped thread and clears stopped state", function()
    local hx, was_continued = stopped_session()
    hx.session:step_over()
    local btvt = hx.last("next")
    btv.test.expect(btvt.arguments.threadId).to_be(1)
    btv.test.expect(hx.session.stopped_thread_id).to_be_nil()
    btv.test.expect(was_continued()).to_be_truthy()
  end)

  btv.test.it("continue sends `continue`", function()
    local hx = stopped_session()
    hx.session:continue()
    btv.test.expect(hx.last("continue")).never.to_be_nil()
  end)

  btv.test.it("evaluate carries the frame id and repl context", function()
    local hx = stopped_session()
    hx.session:evaluate("1+1", 1000, "repl", function() end)
    local ev = hx.last("evaluate")
    btv.test.expect(ev.arguments.expression).to_be("1+1")
    btv.test.expect(ev.arguments.frameId).to_be(1000)
    btv.test.expect(ev.arguments.context).to_be("repl")
  end)

  btv.test.it("a terminated event fires on_terminated once", function()
    local n = 0
    local hx = harness({
      on_terminated = function()
        n = n + 1
      end,
    })
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", {})
    hx.adapter({ type = "event", event = "terminated" })
    hx.adapter({ type = "event", event = "terminated" }) -- idempotent
    btv.test.expect(n).to_be(1)
  end)
end)

btv.test.describe("bemtvi-dap.session teardown", function()
  local function started(handlers)
    local hx = harness(handlers)
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", { supportsConfigurationDoneRequest = true })
    return hx
  end

  -- A `terminated` event ends the DEBUG session, but the adapter process is still
  -- running — it exits when we disconnect. Without this the child leaks for the rest
  -- of the editor session (every debug run leaving another orphan behind).
  btv.test.it("disconnects + closes the transport after a terminated event", function()
    local hx = started()
    hx.adapter({ type = "event", event = "terminated" })
    local dc = hx.last("disconnect")
    btv.test.expect(dc).never.to_be_nil()
    btv.test.expect(hx.handlers._closed).to_be_nil() -- not until the adapter acks
    hx.respond("disconnect", {})
    btv.test.expect(hx.handlers._closed).to_be_truthy()
  end)

  -- Every in-flight request must be settled when the session ends: a callback that is
  -- never called leaks its caller's state forever (a watch stuck at "…", a configure
  -- sequence that never completes).
  btv.test.it("fails every in-flight request when the transport closes", function()
    local hx = started()
    local err = "pending"
    hx.session:request("variables", { variablesReference = 1 }, function(e)
      err = e
    end)
    hx.session:disconnect()
    hx.respond("disconnect", {})
    btv.test.expect(err).never.to_be("pending")
    btv.test.expect(err).never.to_be_nil()
    -- A request issued after the close fails loud instead of writing to a dead pipe.
    local late = "pending"
    hx.session:request("threads", nil, function(e)
      late = e
    end)
    btv.test.expect(late).never.to_be_nil()
    btv.test.expect(hx.last("threads")).to_be_nil()
  end)

  -- DAP `exited` reports the DEBUGGEE's exit code; `terminated` ends the session. An
  -- adapter that outlives its debuggee (a restart-capable one) must not be torn down
  -- on `exited` — but the code is remembered, so the terminated notice can report it.
  btv.test.it("records an exited code without ending the session", function()
    local body
    local hx = started({
      on_terminated = function(b)
        body = b
      end,
    })
    hx.adapter({ type = "event", event = "exited", body = { exitCode = 3 } })
    btv.test.expect(body).to_be_nil()
    btv.test.expect(hx.session.terminated).to_be_falsy()
    hx.adapter({ type = "event", event = "terminated" })
    btv.test.expect(body).never.to_be_nil()
    btv.test.expect(body.exitCode).to_be(3)
  end)
end)

btv.test.describe("bemtvi-dap.session variable + expression editing", function()
  local function configured(handlers)
    local hx = harness(handlers)
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", {
      supportsConfigurationDoneRequest = true,
      supportsSetVariable = true,
      supportsSetExpression = true,
      supportsRestartRequest = true,
    })
    hx.adapter({ type = "event", event = "initialized" })
    hx.respond("configurationDone", {})
    return hx
  end

  btv.test.it("set_variable sends setVariable with the container ref, name, value", function()
    local hx = configured()
    hx.session:set_variable(5, "x", "99", function() end)
    local sv = hx.last("setVariable")
    btv.test.expect(sv).never.to_be_nil()
    btv.test.expect(sv.arguments.variablesReference).to_be(5)
    btv.test.expect(sv.arguments.name).to_be("x")
    btv.test.expect(sv.arguments.value).to_be("99")
  end)

  btv.test.it("set_variable refuses (no request) when the adapter lacks the capability", function()
    local hx = harness()
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", {}) -- no supportsSetVariable
    local err
    hx.session:set_variable(5, "x", "1", function(e)
      err = e
    end)
    btv.test.expect(hx.last("setVariable")).to_be_nil()
    btv.test.expect(err).never.to_be_nil()
  end)

  btv.test.it("set_expression sends setExpression with the l-value, value, frame", function()
    local hx = configured()
    hx.session:set_expression("a.b", "7", 1000, function() end)
    local se = hx.last("setExpression")
    btv.test.expect(se).never.to_be_nil()
    btv.test.expect(se.arguments.expression).to_be("a.b")
    btv.test.expect(se.arguments.value).to_be("7")
    btv.test.expect(se.arguments.frameId).to_be(1000)
  end)

  btv.test.it("restart sends the restart request carrying the configuration", function()
    local hx = configured()
    hx.session:restart({ type = "mock", request = "launch", name = "t", program = "p" })
    local rr = hx.last("restart")
    btv.test.expect(rr).never.to_be_nil()
    btv.test.expect(rr.arguments.arguments.program).to_be("p")
  end)
end)

btv.test.describe("bemtvi-dap.session exception breakpoints", function()
  local CAPS = {
    supportsConfigurationDoneRequest = true,
    exceptionBreakpointFilters = {
      { filter = "raised", label = "Raised", default = false },
      { filter = "uncaught", label = "Uncaught", default = true },
    },
  }

  btv.test.it("seeds the adapter's default filters at configure time", function()
    local hx = harness()
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", CAPS)
    hx.adapter({ type = "event", event = "initialized" })
    local se = hx.last("setExceptionBreakpoints")
    btv.test.expect(se).never.to_be_nil()
    btv.test.expect(#se.arguments.filters).to_be(1)
    btv.test.expect(se.arguments.filters[1]).to_be("uncaught")
  end)

  btv.test.it("honors a get_exception_filters handler override", function()
    local hx = harness({
      get_exception_filters = function()
        return { "raised", "uncaught" }
      end,
    })
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", CAPS)
    hx.adapter({ type = "event", event = "initialized" })
    local se = hx.last("setExceptionBreakpoints")
    btv.test.expect(#se.arguments.filters).to_be(2)
  end)

  btv.test.it("set_exception_breakpoints pushes a new filter set to a live session", function()
    local hx = harness()
    hx.session:start({ type = "mock", request = "launch", name = "t" })
    hx.respond("initialize", CAPS)
    hx.adapter({ type = "event", event = "initialized" })
    hx.session:set_exception_breakpoints({ "raised" }, function() end)
    local se = hx.last("setExceptionBreakpoints")
    btv.test.expect(se.arguments.filters[1]).to_be("raised")
  end)
end)

btv.test.describe("bemtvi-dap.session completions", function()
  btv.test.it("issues a completions request with text/column/frameId", function()
    local hx = harness()
    hx.session.capabilities = { supportsCompletionsRequest = true }
    hx.session:completions("os.get", 7, 11, function() end)
    local req = hx.last("completions")
    btv.test.expect(req).never.to_be_nil()
    btv.test.expect(req.arguments.text).to_be("os.get")
    btv.test.expect(req.arguments.column).to_be(7)
    btv.test.expect(req.arguments.frameId).to_be(11)
  end)

  btv.test.it("delivers the adapter's targets to the callback", function()
    local hx = harness()
    hx.session.capabilities = { supportsCompletionsRequest = true }
    local got
    hx.session:completions("os.", 4, nil, function(_, targets)
      got = targets
    end)
    hx.respond("completions", {
      targets = { { label = "getcwd", text = "getcwd", type = "function" } },
    })
    btv.test.expect(got).never.to_be_nil()
    btv.test.expect(#got).to_be(1)
    btv.test.expect(got[1].label).to_be("getcwd")
  end)

  btv.test.it("reports no completions (not an error) when unsupported", function()
    local hx = harness()
    hx.session.capabilities = {} -- no supportsCompletionsRequest
    local err, targets = "unset", "unset"
    hx.session:completions("x", 2, nil, function(e, t)
      err, targets = e, t
    end)
    -- Resolves immediately with an empty list and no error — no request is sent.
    btv.test.expect(err).to_be_nil()
    btv.test.expect(#targets).to_be(0)
    btv.test.expect(hx.last("completions")).to_be_nil()
  end)
end)
