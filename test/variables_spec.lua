-- Launch-config variable expansion (variables.lua): the `${...}` substitution and the
-- callable dynamic-value form, resolved against a real editor context (a temp file
-- opened in a temp cwd). Drives the expander directly; the end-to-end flow (the adapter
-- actually receiving the expanded path) is covered in e2e_spec.

local dap = require("bemtvi-dap")
local variables = require("bemtvi-dap.variables")

-- Open `fname` inside `dir`, making `dir` the working directory, so the file/workspace
-- variables resolve deterministically. Returns the file path.
local function open_in(t, dir, fname, body)
  local f = dir .. "/" .. fname
  btv.await(btv.fs.write(f, body or "x = 1\n"))
  t:cmd("cd " .. dir)
  t:cmd("edit " .. f)
  return f
end

btv.test.describe("bemtvi-dap.variables expansion", function()
  btv.test.before_each(function()
    dap.setup({})
  end)

  btv.test.it("expands the file-derived variables against the current buffer", function(t)
    local dir = btv.test.tempdir()
    local f = open_in(t, dir, "main.py")
    local abs = dap.signs.abspath(f)
    local out = variables.expand({
      program = "${file}",
      base = "${fileBasename}",
      noext = "${fileBasenameNoExtension}",
      dirn = "${fileDirname}",
      ext = "${fileExtname}",
      rel = "${relativeFile}",
    })
    btv.test.expect(out.program).to_be(abs)
    btv.test.expect(out.base).to_be("main.py")
    btv.test.expect(out.noext).to_be("main")
    btv.test.expect(out.ext).to_be("py")
    btv.test.expect(out.dirn).to_be(vim.fn.fnamemodify(abs, ":h"))
    btv.test.expect(out.rel).to_be("main.py") -- file is under the cwd we cd'd into
  end)

  btv.test.it("expands the workspace / cwd variables", function(t)
    local dir = btv.test.tempdir()
    open_in(t, dir, "a.py")
    local cwd = vim.fn.getcwd()
    local out = variables.expand({
      wsf = "${workspaceFolder}",
      wsfb = "${workspaceFolderBasename}",
      cwd = "${cwd}",
    })
    btv.test.expect(out.wsf).to_be(cwd)
    btv.test.expect(out.cwd).to_be(cwd)
    btv.test.expect(out.wsfb).to_be(vim.fn.fnamemodify(cwd, ":t"))
  end)

  btv.test.it("expands ${env:NAME} (and empties an unset one)", function(t)
    open_in(t, btv.test.tempdir(), "a.py")
    local out = variables.expand({
      p = "${env:PATH}",
      missing = "${env:BEMTVI_DAP_DEFINITELY_UNSET}",
    })
    btv.test.expect(out.p).to_be(os.getenv("PATH"))
    btv.test.expect(out.missing).to_be("")
  end)

  btv.test.it("leaves an unrecognised ${...} untouched and reports it", function(t)
    open_in(t, btv.test.tempdir(), "a.py")
    local out, unknown = variables.expand({ weird = "before-${nope}-after" })
    btv.test.expect(out.weird).to_be("before-${nope}-after")
    local found = false
    for _, n in ipairs(unknown) do
      if n == "nope" then
        found = true
      end
    end
    btv.test.expect(found).to_be(true)
  end)

  btv.test.it("recurses into args lists and nested tables", function(t)
    local dir = btv.test.tempdir()
    local f = open_in(t, dir, "main.py")
    local abs = dap.signs.abspath(f)
    local out = variables.expand({
      args = { "--file", "${file}", "${fileBasename}" },
      env = { ROOT = "${workspaceFolder}" },
      n = 5,
    })
    btv.test.expect(out.args[2]).to_be(abs)
    btv.test.expect(out.args[3]).to_be("main.py")
    btv.test.expect(out.env.ROOT).to_be(vim.fn.getcwd())
    btv.test.expect(out.n).to_be(5) -- non-strings pass through untouched
  end)

  btv.test.it("calls a dynamic-value function and expands its result", function(t)
    local dir = btv.test.tempdir()
    local f = open_in(t, dir, "main.py")
    local abs = dap.signs.abspath(f)
    local out = variables.expand({
      program = function()
        return "${file}"
      end, -- returns a ${...} string → expanded in turn
      literal = function()
        return "/computed/path"
      end,
      args = {
        function()
          return "${fileBasename}"
        end,
      },
    })
    btv.test.expect(out.program).to_be(abs)
    btv.test.expect(out.literal).to_be("/computed/path")
    btv.test.expect(out.args[1]).to_be("main.py")
  end)

  btv.test.it("fails loud when a dynamic-value function errors", function(t)
    open_in(t, btv.test.tempdir(), "a.py")
    local ok, err = pcall(variables.expand, {
      program = function()
        error("boom")
      end,
    })
    btv.test.expect(ok).to_be(false)
    btv.test.expect(tostring(err):find("boom", 1, true)).never.to_be_nil()
  end)

  btv.test.it("flags an ${input:…}/${command:…} as dynamic, leaving it for resolve", function(t)
    open_in(t, btv.test.tempdir(), "a.py")
    local out, _unknown, has_dynamic = variables.expand({ program = "${input:p}", x = "${file}" })
    btv.test.expect(has_dynamic).to_be(true)
    btv.test.expect(out.program).to_be("${input:p}") -- left intact for the async pass
  end)
end)

btv.test.describe("bemtvi-dap.variables dynamic (input/command) resolution", function()
  local function open(t)
    local dir = btv.test.tempdir()
    btv.await(btv.fs.write(dir .. "/a.py", "x = 1\n"))
    t:cmd("edit " .. dir .. "/a.py")
  end

  btv.test.it("resolves ${command:id} from the command registry", function(t)
    open(t)
    local resolved
    variables
      .resolve_dynamic({ program = "${command:pickProg}" }, {
        commands = {
          pickProg = function()
            return "/built/app"
          end,
        },
      })
      :next(function(c)
        resolved = c
      end)
    t:wait_for(function()
      return resolved
    end, { tries = 100, interval = 20, message = "command did not resolve" })
    btv.test.expect(resolved.program).to_be("/built/app")
  end)

  btv.test.it("awaits a ${command:id} that returns a promise", function(t)
    open(t)
    local resolved
    variables
      .resolve_dynamic({ program = "${command:async}" }, {
        commands = {
          async = function()
            return btv.promise.new(function(resolve)
              btv.on_next_tick(function()
                resolve("/deferred")
              end)
            end)
          end,
        },
      })
      :next(function(c)
        resolved = c
      end)
    t:wait_for(function()
      return resolved
    end, { tries = 100, interval = 20, message = "async command did not resolve" })
    btv.test.expect(resolved.program).to_be("/deferred")
  end)

  btv.test.it("prompts for an ${input:id} promptString", function(t)
    open(t)
    local resolved
    variables
      .resolve_dynamic({
        program = "${input:path}",
        inputs = { { id = "path", type = "promptString", description = "Path" } },
      }, {})
      :next(function(c)
        resolved = c
      end)
    t:feed("/typed/path<CR>")
    t:wait_for(function()
      return resolved
    end, { tries = 100, interval = 20, message = "promptString did not resolve" })
    btv.test.expect(resolved.program).to_be("/typed/path")
  end)

  btv.test.it("offers a menu for an ${input:id} pickString", function(t)
    open(t)
    local resolved
    variables
      .resolve_dynamic({
        mode = "${input:m}",
        inputs = {
          { id = "m", type = "pickString", description = "Mode", options = { "debug", "release" } },
        },
      }, {})
      :next(function(c)
        resolved = c
      end)
    t:feed("gg<CR>") -- select the first option
    t:wait_for(function()
      return resolved
    end, { tries = 100, interval = 20, message = "pickString did not resolve" })
    btv.test.expect(resolved.mode).to_be("debug")
  end)

  btv.test.it("resolves a type='command' input through the registry", function(t)
    open(t)
    local resolved
    variables
      .resolve_dynamic({
        program = "${input:prog}",
        inputs = { { id = "prog", type = "command", command = "locate", args = { "x" } } },
      }, {
        commands = {
          locate = function(args)
            return "/found/" .. tostring(args and args[1])
          end,
        },
      })
      :next(function(c)
        resolved = c
      end)
    t:wait_for(function()
      return resolved
    end, { tries = 100, interval = 20, message = "command-input did not resolve" })
    btv.test.expect(resolved.program).to_be("/found/x")
  end)

  btv.test.it("prompts only once for an input referenced twice", function(t)
    open(t)
    local resolved
    variables
      .resolve_dynamic({
        program = "${input:p}",
        args = { "${input:p}" },
        inputs = { { id = "p", type = "promptString" } },
      }, {})
      :next(function(c)
        resolved = c
      end)
    t:feed("X<CR>") -- a single answer feeds both references
    t:wait_for(function()
      return resolved
    end, { tries = 100, interval = 20, message = "cached input did not resolve" })
    btv.test.expect(resolved.program).to_be("X")
    btv.test.expect(resolved.args[1]).to_be("X")
  end)

  btv.test.it("rejects a missing ${input:id} definition", function(t)
    open(t)
    local err
    variables.resolve_dynamic({ program = "${input:missing}" }, {}):next(nil, function(e)
      err = e
    end)
    t:wait_for(function()
      return err
    end, { tries = 100, interval = 20, message = "missing input did not reject" })
    btv.test.expect(tostring(err):find("missing", 1, true)).never.to_be_nil()
  end)

  btv.test.it("rejects a missing ${command:id}", function(t)
    open(t)
    local err
    variables
      .resolve_dynamic({ program = "${command:nope}" }, { commands = {} })
      :next(nil, function(e)
        err = e
      end)
    t:wait_for(function()
      return err
    end, { tries = 100, interval = 20, message = "missing command did not reject" })
    btv.test.expect(tostring(err):find("nope", 1, true)).never.to_be_nil()
  end)
end)
