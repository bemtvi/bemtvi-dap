-- Breakpoint toggling in a live editor buffer: the store updates and the gutter
-- signs follow. Drives a real buffer (no debug session needed).

local dap = require("bemtvi-dap")
local breakpoints = require("bemtvi-dap.breakpoints")
local signs = require("bemtvi-dap.signs")

local function bp_marks()
  local ns = btv.ns.create("bemtvi-dap-breakpoints")
  return btv.buf.extmarks(btv.buf.current(), ns, 0, -1)
end

local function open_temp(t, body)
  local dir = btv.test.tempdir()
  local f = dir .. "/src.txt"
  btv.await(btv.fs.write(f, body or "one\ntwo\nthree\nfour\n"))
  t:cmd("edit " .. f)
  return f
end

btv.test.describe("bemtvi-dap breakpoints", function()
  btv.test.before_each(function()
    dap.setup({})
    dap._sessions, dap._session = {}, nil
    breakpoints.clear_all()
  end)

  btv.test.it("toggles a breakpoint at the cursor, with a gutter sign", function(t)
    local f = open_temp(t)
    t:feed("2G")
    dap.toggle_breakpoint()

    local bps = breakpoints.list()[signs.abspath(f)]
    btv.test.expect(bps).never.to_be_nil()
    btv.test.expect(#bps).to_be(1)
    btv.test.expect(bps[1].line).to_be(2)
    btv.test.expect(#bp_marks()).to_be(1)

    -- Toggling the same line again removes it (store + sign).
    dap.toggle_breakpoint()
    btv.test.expect(breakpoints.list()[signs.abspath(f)]).to_be_nil()
    btv.test.expect(#bp_marks()).to_be(0)
  end)

  btv.test.it("keeps breakpoints sorted by line across several toggles", function(t)
    local f = open_temp(t)
    t:feed("3G")
    dap.toggle_breakpoint()
    t:feed("1G")
    dap.toggle_breakpoint()
    t:feed("2G")
    dap.toggle_breakpoint()
    local bps = breakpoints.list()[signs.abspath(f)]
    btv.test.expect(#bps).to_be(3)
    btv.test.expect(bps[1].line .. bps[2].line .. bps[3].line).to_be("123")
    btv.test.expect(#bp_marks()).to_be(3)
  end)

  btv.test.it("upgrades a plain breakpoint to a conditional one", function(t)
    local f = open_temp(t)
    t:feed("2G")
    breakpoints.toggle()
    breakpoints.toggle({ condition = "x > 1" })
    local bps = breakpoints.list()[signs.abspath(f)]
    btv.test.expect(#bps).to_be(1) -- not removed, upgraded
    btv.test.expect(bps[1].condition).to_be("x > 1")
  end)

  -- An upgrade MERGES: adding a condition to a log point must not drop its message
  -- (clearing an attribute is `set_at_cursor`'s job — the edit path).
  btv.test.it("merges an upgrade into the breakpoint's existing attributes", function(t)
    local f = open_temp(t)
    t:feed("2G")
    breakpoints.toggle({ logMessage = "hit {i}" })
    breakpoints.toggle({ condition = "i > 2" })
    local bp = breakpoints.list()[signs.abspath(f)][1]
    btv.test.expect(bp.logMessage).to_be("hit {i}")
    btv.test.expect(bp.condition).to_be("i > 2")
  end)

  btv.test.it("set_at_cursor edits a breakpoint in place (keeps it, never toggles off)", function(t)
    local f = open_temp(t)
    t:feed("2G")
    breakpoints.toggle() -- a plain breakpoint
    -- Edit it: add a condition + hit condition + log message.
    breakpoints.set_at_cursor({ condition = "i == 3", hitCondition = ">5", logMessage = "hi {i}" })
    local bps = breakpoints.list()[signs.abspath(f)]
    btv.test.expect(#bps).to_be(1) -- still one (edited, not removed)
    btv.test.expect(bps[1].condition).to_be("i == 3")
    btv.test.expect(bps[1].hitCondition).to_be(">5")
    btv.test.expect(bps[1].logMessage).to_be("hi {i}")

    -- get_at_cursor reads the breakpoint under the cursor back.
    local cur = breakpoints.get_at_cursor()
    btv.test.expect(cur.condition).to_be("i == 3")

    -- Clearing a field (nil) drops it without removing the breakpoint.
    breakpoints.set_at_cursor({ condition = "i == 3" })
    btv.test.expect(breakpoints.list()[signs.abspath(f)][1].hitCondition).to_be_nil()
    btv.test.expect(#breakpoints.list()[signs.abspath(f)]).to_be(1)
  end)

  btv.test.it("set_at_cursor creates a breakpoint when none exists at the cursor", function(t)
    local f = open_temp(t)
    t:feed("3G")
    breakpoints.set_at_cursor({ condition = "x" })
    local bps = breakpoints.list()[signs.abspath(f)]
    btv.test.expect(#bps).to_be(1)
    btv.test.expect(bps[1].line).to_be(3)
    btv.test.expect(bps[1].condition).to_be("x")
  end)

  btv.test.it("clear_all removes every breakpoint and sign", function(t)
    local f = open_temp(t)
    t:feed("1G")
    dap.toggle_breakpoint()
    t:feed("3G")
    dap.toggle_breakpoint()
    btv.test.expect(#bp_marks()).to_be(2)
    dap.clear_breakpoints()
    btv.test.expect(breakpoints.list()[signs.abspath(f)]).to_be_nil()
    btv.test.expect(#bp_marks()).to_be(0)
  end)

  btv.test.it("notifies and no-ops on a buffer with no file", function(t)
    t:cmd("enew")
    breakpoints.toggle()
    -- Nothing recorded for an unnamed buffer.
    local n = 0
    for _ in pairs(breakpoints.list()) do
      n = n + 1
    end
    btv.test.expect(n).to_be(0)
  end)

  -- A breakpoint belongs to the PROJECT, not to one session: with several sessions live
  -- (a client and a server, say) every one of them must learn about it. Pushing only to
  -- the active session left the others debugging a stale breakpoint set.
  btv.test.it("pushes a breakpoint change to every live session", function(t)
    local f = open_temp(t)
    local pushed = {}
    local function fake(name)
      return {
        name = name,
        initialized = true,
        terminated = false,
        set_breakpoints = function(_, path, bps)
          pushed[name] = { path = path, count = #bps }
        end,
      }
    end
    local a, b = fake("A"), fake("B")
    dap._sessions = { [1] = a, [2] = b }
    dap._session = a

    t:feed("2G")
    dap.toggle_breakpoint()

    btv.test.expect(pushed.A).never.to_be_nil()
    btv.test.expect(pushed.B).never.to_be_nil()
    btv.test.expect(pushed.B.path).to_be(signs.abspath(f))
    btv.test.expect(pushed.B.count).to_be(1)

    -- A session that never finished configuring (or has already ended) is skipped.
    pushed = {}
    b.initialized = false
    a.terminated = true
    dap.toggle_breakpoint()
    btv.test.expect(pushed.A).to_be_nil()
    btv.test.expect(pushed.B).to_be_nil()

    dap._sessions, dap._session = {}, nil
  end)

  -- A breakpoint restored from the shada can point past the end of a file that shrank
  -- since. The store keeps it (the file may grow back, and the adapter decides what is
  -- verifiable) but the gutter can't paint a line that isn't there.
  btv.test.it("skips gutter signs for lines past the end of the buffer", function(t)
    local f = open_temp(t, "one\ntwo\n")
    local path = signs.abspath(f)
    breakpoints.restore({ [path] = { { line = 2 }, { line = 99 } } })
    btv.test.expect(#breakpoints.list()[path]).to_be(2)
    btv.test.expect(#bp_marks()).to_be(1)
  end)

  btv.test.it("restore() seeds the store (sorted) and repaints signs", function(t)
    local f = open_temp(t)
    local path = signs.abspath(f)
    -- The shape persisted to the workspace shada: abspath -> list of breakpoints. Given
    -- out of order, with one carrying a condition, and one bogus (no numeric line).
    breakpoints.restore({
      [path] = {
        { line = 3, condition = "x > 1" },
        { line = 1 },
        { bogus = true },
      },
    })
    local bps = breakpoints.list()[path]
    btv.test.expect(#bps).to_be(2) -- the bogus entry is dropped
    btv.test.expect(bps[1].line).to_be(1) -- sorted by line
    btv.test.expect(bps[2].line).to_be(3)
    btv.test.expect(bps[2].condition).to_be("x > 1")
    -- The open file's gutter shows the restored breakpoints.
    btv.test.expect(#bp_marks()).to_be(2)
  end)

  btv.test.it("restore() tolerates a missing / malformed blob", function()
    -- A fresh store (no key yet) hands back nil; a non-table is ignored — neither errors.
    breakpoints.restore(nil)
    breakpoints.restore("garbage")
    local n = 0
    for _ in pairs(breakpoints.list()) do
      n = n + 1
    end
    btv.test.expect(n).to_be(0)
  end)

  btv.test.it("fires on_commit after each breakpoint mutation", function(t)
    open_temp(t)
    local saved = 0
    breakpoints.on_commit = function()
      saved = saved + 1
    end
    t:feed("2G")
    breakpoints.toggle() -- set
    btv.test.expect(saved).to_be(1)
    breakpoints.set_at_cursor({ condition = "x" }) -- edit
    btv.test.expect(saved).to_be(2)
    breakpoints.toggle() -- remove
    btv.test.expect(saved).to_be(3)
    breakpoints.clear_all() -- clear
    btv.test.expect(saved).to_be(4)
    breakpoints.on_commit = nil
  end)

  btv.test.it("lists every breakpoint as named-list entries", function(t)
    local f = open_temp(t)
    t:feed("3G")
    breakpoints.toggle({ condition = "i == 2" })
    t:feed("1G")
    breakpoints.toggle() -- a plain one, set after but on an earlier line

    -- The entries are one-per-breakpoint, sorted by file then line, each describing the
    -- breakpoint kind — the payload `DapBreakpoints` sends to the named list.
    local items = dap._breakpoint_items()
    btv.test.expect(#items).to_be(2)
    btv.test.expect(items[1].filename).to_be(signs.abspath(f))
    btv.test.expect(items[1].lnum).to_be(1)
    btv.test.expect(items[1].text).to_be("breakpoint")
    btv.test.expect(items[2].lnum).to_be(3)
    btv.test.expect(items[2].text).to_be("cond: i == 2")
  end)

  btv.test.it("opens a breakpoints named list that refreshes on change", function(t)
    local f = open_temp(t)
    local srcwin = btv.win.current()
    t:feed("2G")
    breakpoints.toggle()

    -- Open the list in its own dock tab; it shows the one breakpoint. The named list is
    -- window-independent, so it is NOT bound to `srcwin`.
    dap.list_breakpoints()
    t:sleep(80)
    -- The dock tab is now focused; read its rendered rows (one non-empty line per
    -- breakpoint) straight off the display buffer.
    local listbuf = btv.buf.current()
    local function bp_rows()
      local count = 0
      for _, line in ipairs(btv.buf.lines(listbuf, 0, -1, false)) do
        if line ~= "" then
          count = count + 1
        end
      end
      return count
    end
    btv.test.expect(bp_rows()).to_be(1)

    -- Back in the source buffer, add another breakpoint. The open list repaints in place
    -- (refresh-on-commit) without re-running `:DapBreakpoints`.
    btv.win.set_current(srcwin)
    t:feed("4G")
    breakpoints.toggle()
    t:sleep(80)
    btv.test.expect(bp_rows()).to_be(2)

    -- Clearing every breakpoint repaints the list down to empty too.
    breakpoints.clear_all()
    t:sleep(80)
    btv.test.expect(bp_rows()).to_be(0)
  end)

  btv.test.it("round-trips breakpoints through the plugin shada store", function(t)
    -- Exercise the real persistence path the workspace wiring uses: the same
    -- `btv.shada.plugin()` handle (the bemtvi-dap namespace; in-memory here since the test
    -- session has no shada file), saved on change and reloaded into a "fresh session".
    local f = open_temp(t)
    local path = signs.abspath(f)
    -- A test attributes to no rtp plugin, so the namespace must be passed explicitly
    -- (the dev escape hatch); the real plugin's setup() calls `btv.shada.plugin()` with no
    -- argument and is assigned the `bemtvi-dap` namespace from its install location.
    local store = btv.shada.plugin("bemtvi-dap")
    breakpoints.on_commit = function()
      store:set("breakpoints", breakpoints.list())
    end

    t:feed("2G")
    breakpoints.toggle({ condition = "n == 5" })
    t:feed("4G")
    breakpoints.toggle() -- a plain one too

    -- "Restart": the old session's hook is gone and the live store is empty, just as it
    -- would be at boot, before setup() reloads from the shada.
    breakpoints.on_commit = nil
    breakpoints.restore({})
    btv.test.expect(next(breakpoints.list())).to_be_nil()

    breakpoints.restore(store:get("breakpoints"))
    local bps = breakpoints.list()[path]
    btv.test.expect(#bps).to_be(2)
    btv.test.expect(bps[1].line).to_be(2)
    btv.test.expect(bps[1].condition).to_be("n == 5")
    btv.test.expect(bps[2].line).to_be(4)
  end)
end)

btv.test.describe("bemtvi-dap launch completion", function()
  btv.test.before_each(function()
    dap.setup({
      configurations = {
        cttest = {
          { type = "x", request = "launch", name = "Run file" },
          { type = "x", request = "launch", name = "Attach" },
        },
      },
    })
    dap._session = nil -- no live session, so continue() launches rather than resumes
  end)

  -- Open a buffer whose filetype has the configurations seeded above.
  local function open_cttest(t)
    local f = btv.test.tempdir() .. "/s.txt"
    btv.await(btv.fs.write(f, "x\n"))
    t:cmd("edit " .. f)
    t:cmd("set filetype=cttest")
    return f
  end

  btv.test.it("completes configuration names for the current filetype", function(t)
    open_cttest(t)
    -- The completer the `:DapContinue` command declares: every configuration name for
    -- this filetype (core fuzzy-ranks them against the partial argument).
    local names = dap._configuration_names()
    table.sort(names)
    btv.test.expect(table.concat(names, ",")).to_be("Attach,Run file")
  end)

  btv.test.it("offers no completions for a filetype with no configurations", function(t)
    local f = btv.test.tempdir() .. "/p.txt"
    btv.await(btv.fs.write(f, "x\n"))
    t:cmd("edit " .. f)
    t:cmd("set filetype=noconfigs")
    btv.test.expect(#dap._configuration_names()).to_be(0)
  end)

  btv.test.it("launches a named configuration directly", function(t)
    open_cttest(t)
    local ran
    local orig = dap.run
    dap.run = function(cfg)
      ran = cfg
    end

    dap.continue("Attach") -- the `:DapContinue Attach` argument path
    btv.test.expect(ran).never.to_be_nil()
    btv.test.expect(ran.name).to_be("Attach")

    -- An unknown name launches nothing (reported, not silently the first config).
    ran = nil
    dap.continue("nope")
    btv.test.expect(ran).to_be_nil()

    dap.run = orig
  end)
end)
