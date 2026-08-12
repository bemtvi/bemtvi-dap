-- The config surface: the merge semantics and the validation that fails LOUD on a
-- transport / shape bemtvi-dap can't honor (no silent stubs). Pure logic.

local config = require("bemtvi-dap.config")

btv.test.describe("bemtvi-dap.config merge", function()
  btv.test.it("overrides scalars and recurses tables, replacing lists wholesale", function()
    local base = config.defaults()
    local merged = config.merge(base, {
      sidebar = { width = 60 },
      mappings = { continue = "<F9>" },
    })
    btv.test.expect(merged.sidebar.width).to_be(60)
    btv.test.expect(merged.sidebar.position).to_be("right") -- untouched default kept
    btv.test.expect(merged.mappings.continue).to_be("<F9>")
    -- sibling default kept (now a list of the plain key + its Shift variant)
    btv.test.expect(merged.mappings.step_over[1]).to_be("<F10>")
    btv.test.expect(merged.mappings.step_over[2]).to_be("<S-F10>")
  end)

  btv.test.it("a list value replaces rather than positionally merging", function()
    local merged = config.merge({ args = { "a", "b", "c" } }, { args = { "x" } })
    btv.test.expect(#merged.args).to_be(1)
    btv.test.expect(merged.args[1]).to_be("x")
  end)
end)

btv.test.describe("bemtvi-dap.config validation", function()
  btv.test.it("accepts an executable adapter", function()
    btv.test
      .expect(function()
        config.validate_adapter({ type = "executable", command = "debugpy" }, "python")
      end).never
      .to_error()
  end)

  btv.test.it("defaults a bare adapter to executable", function()
    btv.test
      .expect(function()
        config.validate_adapter({ command = "lldb-vscode" }, "cpp")
      end).never
      .to_error()
  end)

  btv.test.it("accepts a server (TCP) adapter with a port", function()
    btv.test
      .expect(function()
        config.validate_adapter({ type = "server", host = "127.0.0.1", port = 5678 }, "go")
      end).never
      .to_error()
  end)

  btv.test.it("accepts a server adapter that launches an executable", function()
    btv.test
      .expect(function()
        config.validate_adapter(
          { type = "server", port = 5678, executable = { command = "dlv", args = { "dap" } } },
          "go"
        )
      end).never
      .to_error()
  end)

  btv.test.it("rejects a server adapter with no port", function()
    btv.test
      .expect(function()
        config.validate_adapter({ type = "server", host = "127.0.0.1" }, "go")
      end)
      .to_error("port")
  end)

  btv.test.it("rejects an unknown adapter type loud", function()
    btv.test
      .expect(function()
        config.validate_adapter({ type = "pipe" }, "x")
      end)
      .to_error("unknown type")
  end)

  btv.test.it("rejects an executable adapter with no command", function()
    btv.test
      .expect(function()
        config.validate_adapter({ type = "executable" }, "x")
      end)
      .to_error("command")
  end)

  btv.test.it("accepts a resolver function (validated when it produces an adapter)", function()
    btv.test
      .expect(function()
        config.validate_adapter(function() end, "dyn")
      end).never
      .to_error()
  end)

  btv.test.it("requires type/request/name on a configuration", function()
    btv.test
      .expect(function()
        config.validate_configuration({ request = "launch", name = "x" })
      end)
      .to_error("type")
    btv.test
      .expect(function()
        config.validate_configuration({ type = "python", name = "x" })
      end)
      .to_error("launch")
    btv.test
      .expect(function()
        config.validate_configuration({ type = "python", request = "run", name = "x" })
      end)
      .to_error("launch")
  end)

  btv.test.it("accepts a valid launch configuration", function()
    local cfg =
      config.validate_configuration({ type = "python", request = "launch", name = "file" })
    btv.test.expect(cfg.name).to_be("file")
  end)
end)
