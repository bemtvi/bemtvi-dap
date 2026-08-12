-- The REPL console cursor: after evaluating an expression (entered through the `dap>`
-- prompt that `<CR>` on the view opens), the cursor must land on the newest line — not
-- wherever it was when <CR> was pressed. Regression test for the "cursor jumps up after
-- pressing enter" bug.

local dap = require("bemtvi-dap")
local repl = require("bemtvi-dap.repl")

btv.test.describe("bemtvi-dap repl", function()
  btv.test.before_each(function()
    dap.setup({})
    repl._reset() -- a fresh view + dock, independent of any prior spec's session
  end)

  btv.test.it("keeps the cursor on the newest line after evaluating", function(t)
    repl.open()
    -- Seed scrollback so "the bottom" is well below the top.
    for i = 1, 8 do
      repl.info("line " .. i)
    end
    -- Focus the repl and move the cursor UP — the cursor position from which the user
    -- presses <CR> to evaluate (the bug left it here instead of moving to the result).
    t:feed("gg")
    btv.test.expect(repl.cursor_line()).to_be(1)

    -- Press <CR> to open the `dap>` prompt (the view's on_select), then answer it —
    -- exactly the user's flow ("in the repl and press enter").
    t:feed("<CR>")
    t:feed("1+1<CR>")
    t:sleep(80)

    -- The eval appended lines (the "> 1+1" echo + the no-session notice).
    local buf = repl.bufnr()
    local n = buf and #btv.buf.lines(buf, 0, -1, false) or 0
    btv.test.expect(n).to_be(10) -- 8 seeded + 2 from the eval
    -- …and the cursor is on the newest line, not still at the top (the bug left it up).
    btv.test.expect(repl.cursor_line()).to_be(n)
  end)

  -- A multi-line eval error (a debugpy traceback) must highlight EVERY line of the
  -- message, not just the first, AND keep the REPL's shadow line count in sync with the
  -- buffer. The old code pushed the whole `err.message` as ONE `lines` entry with a
  -- single mark; `set_lines` then split the embedded newlines into separate buffer
  -- lines, so the mark's `end_col` got clamped to the first row (truncated red
  -- highlight) and `#lines` fell behind the real buffer — leaving `set_cursor(#lines)`
  -- short of the true newest line, so output stopped auto-scrolling.
  btv.test.it("highlights every line of a multi-line eval error and stays synced", function(t)
    local fake = {
      current_frame = { id = 1 },
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb({ message = "Traceback (most recent call last):\n  File x\nNameError: boom" })
      end,
    }
    repl.open()
    repl.set_session(fake)
    t:sleep(40)

    repl.eval("bad")
    t:sleep(60)

    local buf = repl.bufnr()
    local lines = btv.buf.lines(buf, 0, -1, false)
    local marks = btv.buf.extmarks(buf, btv.ns.create("bemtvi-dap-repl"), 0, -1)

    -- Prompt line + 3 message lines, each its own buffer line.
    btv.test.expect(#lines).to_be(4)
    -- A mark on the prompt + one on each of the 3 message rows (the bug left only 2).
    btv.test.expect(#marks).to_be(4)
    -- The cursor tails the real newest line (the bug desynced #lines and landed short).
    btv.test.expect(repl.cursor_line()).to_be(#lines)
  end)

  -- The `dap>` prompt stays open like a real REPL: each `<CR>` evaluates and reopens
  -- the prompt for the next line; only `<Esc>` closes it. The old prompt closed after a
  -- single submission (one expression per `<CR>` on the view).
  btv.test.it("keeps the dap> prompt open across submissions until <Esc>", function(t)
    local fake = {
      current_frame = { id = 1 },
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb(nil, { result = "ok" })
      end,
    }
    repl.open()
    repl.set_session(fake)
    t:sleep(40)

    -- Open the prompt (the view's <CR> select), then submit two expressions in a row —
    -- the second only reaches a prompt if the first didn't close it.
    t:feed("<CR>")
    btv.test.expect(t:mode()).to_be("c") -- the prompt is open (command-line mode)
    t:feed("1+1<CR>")
    t:sleep(40)
    btv.test.expect(t:mode()).to_be("c") -- it reopened for the next line (was "n" before)
    t:feed("2+2<CR>")
    t:sleep(40)

    local lines = btv.buf.lines(repl.bufnr(), 0, -1, false)
    local function has(s)
      for _, l in ipairs(lines) do
        if l == s then
          return true
        end
      end
      return false
    end
    -- Both expressions were echoed → the prompt was still open for the 2nd <CR>.
    btv.test.expect(has("> 1+1")).to_be(true)
    btv.test.expect(has("> 2+2")).to_be(true)

    -- <Esc> ends the loop: back to normal mode, no prompt open.
    t:feed("<Esc>")
    t:sleep(20)
    btv.test.expect(t:mode()).never.to_be("c")
  end)

  btv.test.it("does not steal focus when output arrives while editing elsewhere", function(t)
    repl.open() -- opens + focuses the repl (bottom dock)
    btv.layer.main() -- leave it for the main editor
    t:sleep(40) -- let the focus switch settle into the mirrors

    local replwin = repl.winid()
    local before = btv.win.current()
    btv.test.expect(before).never.to_be(replwin) -- we're in the main area, not the repl

    -- Adapter output arrives while we're editing elsewhere — it must not pull focus.
    repl.append_output("stdout", "async program output\n")
    t:sleep(40)
    btv.test.expect(btv.win.current()).to_be(before)
  end)

  -- debugpy emits DAP `output` events with category `telemetry` at startup (`output:
  -- "ptvsd"` and `"debugpy"`, neither newline-terminated). The DAP spec says clients
  -- must NOT show telemetry to the user, but `append_output` buffered them in `pending`
  -- and concatenated them into a stray `ptvsddebugpy` line, dumped just before the first
  -- real REPL output. Telemetry must be dropped entirely — buffer included.
  btv.test.it("drops telemetry output instead of leaking ptvsddebugpy", function(t)
    repl.open()

    -- The two unterminated telemetry events debugpy sends on attach…
    repl.append_output("telemetry", "ptvsd")
    repl.append_output("telemetry", "debugpy")
    -- …then a real program print.
    repl.append_output("stdout", "hello\n")
    t:sleep(40)

    local lines = btv.buf.lines(repl.bufnr(), 0, -1, false)
    for _, l in ipairs(lines) do
      btv.test.expect(l:find("ptvsd", 1, true)).never.to_be_truthy()
      btv.test.expect(l:find("debugpy", 1, true)).never.to_be_truthy()
    end
    -- The real output is still there, unpolluted by a telemetry prefix.
    btv.test.expect(lines[#lines]).to_be("hello")
  end)

  -- A view's backing buffer only exists a tick after create, and `:set_decor` is a
  -- no-op until then — so the very first paint (the "─ starting … ─" banner, written in
  -- the same tick the console opens) lost its highlight for good: nothing repaints
  -- those lines again. The decorations must land once the buffer arrives.
  btv.test.it("highlights the lines written in the same tick the console opens", function(t)
    repl._reset()
    repl.open()
    repl.info("─ starting demo ─") -- same tick as open(): no buffer yet
    t:sleep(60)

    local buf = repl.bufnr()
    btv.test.expect(buf).never.to_be_nil()
    local marks = btv.buf.extmarks(buf, btv.ns.create("bemtvi-dap-repl"), 0, -1)
    btv.test.expect(#marks).to_be(1)
    btv.test.expect(marks[1][2]).to_be(0) -- { id, row, col } — on the banner line
  end)

  -- A chatty debuggee (a log loop, a test run) streams output events forever. The
  -- scrollback is capped so the console can't grow without bound — and so a repaint,
  -- which ships the whole buffer, stays O(cap) instead of O(everything ever printed).
  btv.test.it("caps the scrollback and keeps the marks aligned after trimming", function(t)
    dap.setup({ repl = { max_lines = 50 } })
    repl._reset()
    repl.open()

    for i = 1, 200 do
      repl.append_output("stdout", "line " .. i .. "\n")
    end
    repl.info("marker") -- a highlighted line, appended after the trim
    t:sleep(60)

    local buf = repl.bufnr()
    local lines = btv.buf.lines(buf, 0, -1, false)
    btv.test.expect(#lines).to_be(50)
    btv.test.expect(lines[#lines]).to_be("marker") -- the newest line survives
    btv.test.expect(lines[#lines - 1]).to_be("line 200")

    -- The one surviving mark still points at the row it was pushed for (a naive trim
    -- leaves every mark pointing `trimmed` rows too far down).
    local marks = btv.buf.extmarks(buf, btv.ns.create("bemtvi-dap-repl"), 0, -1)
    btv.test.expect(#marks).to_be(1)
    btv.test.expect(marks[1][2]).to_be(#lines - 1) -- { id, row, col }

    dap.setup({}) -- restore the default cap for the specs that follow
  end)

  btv.test.it("completes a REPL expression from the adapter, honoring start/length", function(t)
    -- A fake session mirroring how debugpy answers `os.get`: it completes the attribute
    -- after the dot, returning the member name (`getcwd`) with a 0-based replace span
    -- covering the `get` qualifier (start=3 is the `g`, length=3). debugpy emits a
    -- 0-based `start` even though we negotiated columnsStartAt1=true, so the plugin uses
    -- it as-is — a stray `- 1` here would replace `.get` and yield `osgetcwd`.
    local fake = {
      current_frame = { id = 1 },
      completions = function(_, _text, _col, _frame, cb)
        cb(nil, { { label = "getcwd", text = "getcwd", start = 3, length = 3 } })
      end,
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb(nil, { result = "<cwd>" })
      end,
    }
    repl.open()
    repl.set_session(fake)

    -- Open the dap> prompt, type a partial member access, complete it (<Tab> opens the
    -- wildmenu, <Tab> selects the row), and submit — the range replaces only the `get`
    -- qualifier, keeping the `os.`, so the echoed expression is the whole member access.
    t:feed("<CR>")
    t:feed("os.get")
    t:feed("<Tab>")
    t:feed("<Tab>")
    t:feed("<CR>")
    t:sleep(80)

    local buf = repl.bufnr()
    local lines = buf and btv.buf.lines(buf, 0, -1, false) or {}
    local echoed = false
    for _, l in ipairs(lines) do
      if l == "> os.getcwd" then
        echoed = true
      end
    end
    btv.test.expect(echoed).to_be_truthy()
  end)

  btv.test.it("completes after an open paren without eating it", function(t)
    -- Regression: typing `abs(` then completing the argument must keep the `(`. debugpy,
    -- asked to complete at the cursor of `abs(`, returns names with a 0-based insert
    -- point AT the cursor (start=4 — just past the paren — length=0, nothing overwritten).
    -- The old `start - 1` shifted that to offset 3, dropping the completion in front of
    -- the `(` instead of after it. The completion must land after the paren.
    local fake = {
      current_frame = { id = 1 },
      completions = function(_, _text, _col, _frame, cb)
        cb(nil, { { label = "xs", text = "xs", start = 4, length = 0 } })
      end,
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb(nil, { result = "1" })
      end,
    }
    repl.open()
    repl.set_session(fake)

    t:feed("<CR>")
    t:feed("abs(")
    t:feed("<Tab>")
    t:feed("<Tab>")
    t:feed("<CR>")
    t:sleep(80)

    local buf = repl.bufnr()
    local lines = buf and btv.buf.lines(buf, 0, -1, false) or {}
    local echoed = false
    for _, l in ipairs(lines) do
      if l == "> abs(xs" then
        echoed = true
      end
    end
    btv.test.expect(echoed).to_be_truthy()
  end)
end)
