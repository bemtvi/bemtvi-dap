-- The sidebar's cross-cutting behavior against a fake session: which frame the rest of
-- the plugin evaluates in, and how the panels react when nothing is running. (The live
-- rendering — watches, exception rows — is covered end-to-end in e2e_spec.)

local dap = require("bemtvi-dap")
local ui = require("bemtvi-dap.ui")
local repl = require("bemtvi-dap.repl")

-- A session stand-in: enough surface for the sidebar to render and evaluate against.
local function fake_session()
  return {
    initialized = true,
    terminated = false,
    capabilities = {},
    current_frame = nil,
    stopped_thread_id = 1,
    frame_scopes = function(_, _id, cb)
      cb({})
    end,
    evaluate = function(_, expr, _frame, _ctx, cb)
      cb(nil, { result = expr .. " => ok", variablesReference = 0 })
    end,
  }
end

btv.test.describe("bemtvi-dap sidebar", function()
  btv.test.before_each(function()
    dap.setup({})
    dap._sessions, dap._session = {}, nil
    ui.clear_watches()
    ui.close()
  end)

  -- Selecting a frame in the STACK FRAMES section retargets the whole session, not just
  -- the sidebar: `:DapEval` / the `dap>` prompt / hover all evaluate in the frame the
  -- session points at. Leaving it on the top frame silently evaluated the wrong scope.
  btv.test.it("focusing a stack frame retargets the session for evaluation", function(t)
    local s = fake_session()
    ui.set_session(s)
    repl.set_session(s)
    local frames = {
      { id = 1000, name = "inner", line = 1 },
      { id = 1001, name = "outer", line = 9 },
    }
    ui.show_stopped({ frames = frames, threadId = 1 })
    t:sleep(40)
    btv.test.expect(s.current_frame.id).to_be(1000) -- the top frame by default

    ui._on_select({ kind = "frame", frame = frames[2] })
    t:sleep(40)
    btv.test.expect(s.current_frame.id).to_be(1001)

    ui.close()
  end)

  -- Watches are evaluated against the FOCUSED frame too, and a stale evaluation from a
  -- superseded frame must never overwrite a newer one (the generation guard).
  btv.test.it("re-evaluates watches against the focused frame", function(t)
    local s = fake_session()
    local seen = {}
    s.evaluate = function(_, expr, frame_id, _ctx, cb)
      seen[#seen + 1] = frame_id
      cb(nil, { result = expr .. "@" .. tostring(frame_id), variablesReference = 0 })
    end
    ui.set_session(s)
    ui.show_stopped({
      frames = { { id = 1, name = "a", line = 1 }, { id = 2, name = "b", line = 2 } },
      threadId = 1,
    })
    ui.add_watch("x")
    t:sleep(40)

    ui._on_select({ kind = "frame", frame = { id = 2, name = "b", line = 2 } })
    t:sleep(40)
    btv.test.expect(seen[#seen]).to_be(2)

    local text = table.concat(btv.buf.lines(ui.bufnr(), 0, -1, false), "\n")
    btv.test.expect(text:find("x = x@2", 1, true)).never.to_be_nil()

    ui.clear_watches()
    ui.close()
  end)
end)

btv.test.describe("bemtvi-dap session commands with nothing running", function()
  btv.test.before_each(function()
    dap.setup({})
    dap._sessions, dap._session = {}, nil
    repl._reset()
  end)

  -- `:DapTerminate` with nothing running used to run the whole teardown path — writing
  -- a "─ session terminated ─" line into the console for a session that never existed.
  -- It must report instead.
  btv.test.it("terminate reports rather than faking a termination", function(t)
    repl.open()
    dap.terminate()
    t:sleep(40)
    for _, line in ipairs(btv.buf.lines(repl.bufnr(), 0, -1, false)) do
      btv.test.expect(line:find("terminated", 1, true)).never.to_be_truthy()
    end
  end)

  btv.test.it("terminate_all reports rather than faking a termination", function(t)
    repl.open()
    dap.terminate_all()
    t:sleep(40)
    for _, line in ipairs(btv.buf.lines(repl.bufnr(), 0, -1, false)) do
      btv.test.expect(line:find("terminated", 1, true)).never.to_be_truthy()
    end
  end)
end)
