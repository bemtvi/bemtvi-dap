-- Launch/attach variable expansion: the `${...}` substitution VSCode and nvim-dap use
-- in debug configurations, resolved against the current editor context the moment a
-- session starts (init.lua calls `M.expand` in `run` before the config is sent to the
-- adapter). Without it, `program = "${file}"` would reach the adapter as the literal
-- 8-character string — so this is what makes the documented nvim-dap-style configs
-- actually run.
--
-- Supported variables (the static nvim-dap core set):
--   ${file}                      the current buffer's absolute path
--   ${fileBasename}              its filename (with extension)
--   ${fileBasenameNoExtension}   its filename without the extension
--   ${fileDirname}               the directory containing it
--   ${fileExtname}               its extension (no dot)
--   ${relativeFile}              the file relative to the working directory
--   ${relativeFileDirname}       the directory of ${relativeFile}
--   ${workspaceFolder}           the working directory (`getcwd`)
--   ${workspaceFolderBasename}   its basename
--   ${cwd}                       the working directory
--   ${env:NAME}                  the NAME environment variable ("" when unset)
--
-- A configuration value may also be a CALLABLE (`function() return "..." end`) — the
-- nvim-dap dynamic-value form, for a path computed at launch (e.g. reading a build
-- output). It is invoked at expansion time and its result is expanded in turn (so a
-- function may itself return a `${...}` string). A function that errors fails loud.
--
-- The interactive VSCode forms are supported too, resolved in a second, ASYNC pass
-- (`resolve_dynamic`, which prompts):
--   ${input:id}    looks up `config.inputs[id]` and prompts by its `type` —
--                  `promptString` (text), `pickString` (a menu over `options`), or
--                  `command` (run a registered command). Each id prompts once per launch.
--   ${command:id}  runs a command registered via `dap.register_command(id, fn)`; `fn`
--                  may return a string or a promise.
-- A missing input/command definition, an unsupported input type, or a cancelled prompt
-- aborts the launch loud. Any OTHER unrecognised `${...}` is left untouched and reported
-- (init.lua warns) — never silently swallowed.

local M = {}

-- The current buffer's absolute file path, or "" when the buffer has no file.
local function current_file()
  local bufnr = btv.buf.current()
  local name = bufnr and btv.buf.name(bufnr)
  if not name or name == "" then
    return ""
  end
  return vim.fn.fnamemodify(name, ":p")
end

-- macOS resolves the firmlinks /var, /tmp, /etc to /private/var, /private/tmp,
-- /private/etc, so `getcwd` (which :cd canonicalizes through the OS) can come back
-- `/private/…`-prefixed while a buffer name keeps its `/var/…` spelling. Normalize
-- both spellings to the short form so the relativize prefix test still recognises a
-- file as living under cwd. A no-op off macOS (and on any non-firmlink path).
local FIRMLINKS = { var = true, tmp = true, etc = true }
local function unfirmlink(p)
  local root, rest = p:match("^/private/([^/]+)(.*)$")
  if root and FIRMLINKS[root] then
    return "/" .. root .. rest
  end
  return p
end

-- The file path made relative to `cwd` (a leading `cwd/` stripped), or `file` unchanged
-- when it isn't under `cwd`. The prefix test runs on firmlink-normalized spellings so a
-- canonicalized cwd and a symlink-naive file path still match (see `unfirmlink`).
local function relativize(file, cwd)
  if file == "" or cwd == "" then
    return file
  end
  local nfile = unfirmlink(file)
  local prefix = unfirmlink(cwd):gsub("/+$", "") .. "/"
  if nfile:sub(1, #prefix) == prefix then
    return nfile:sub(#prefix + 1)
  end
  return file
end

-- Build the variable table for the current context (file + working directory). All
-- file-derived entries are "" when no file is open, so `${file}`-style tokens expand to
-- empty rather than to a bogus path.
function M.context()
  local file = current_file()
  local cwd = vim.fn.getcwd() or ""
  local rel = relativize(file, cwd)
  local has = file ~= ""
  return {
    file = file,
    fileBasename = has and vim.fn.fnamemodify(file, ":t") or "",
    fileBasenameNoExtension = has and vim.fn.fnamemodify(file, ":t:r") or "",
    fileDirname = has and vim.fn.fnamemodify(file, ":h") or "",
    fileExtname = has and vim.fn.fnamemodify(file, ":e") or "",
    relativeFile = rel,
    relativeFileDirname = rel ~= "" and vim.fn.fnamemodify(rel, ":h") or "",
    workspaceFolder = cwd,
    workspaceFolderBasename = cwd ~= "" and vim.fn.fnamemodify(cwd, ":t") or "",
    cwd = cwd,
  }
end

-- Expand one string against `vars`, collecting any unrecognised `${name}` into `unknown`
-- (a `name -> true` set the caller turns into a warning). `${env:NAME}` resolves first
-- so an env var named like a builtin can't be shadowed. The interactive `${input:…}` /
-- `${command:…}` tokens are LEFT in place (a second, async pass resolves them — see
-- `resolve_dynamic`) and noted via `flags.dynamic`; any other `${ns:id}` is unknown. A
-- replacement FUNCTION is used throughout, so a value containing `%` is substituted
-- literally (no capture-ref magic).
local function expand_string(s, vars, unknown, flags)
  s = s:gsub("%${env:([%w_]+)}", function(name)
    return os.getenv(name) or ""
  end)
  s = s:gsub("%${([%w_]+)}", function(name)
    local v = vars[name]
    if v ~= nil then
      return v
    end
    unknown[name] = true
    return "${" .. name .. "}" -- leave it untouched; the caller warns
  end)
  for ns in s:gmatch("%${(%a[%w]*):[%w_%.%-]+}") do
    if ns == "input" or ns == "command" then
      flags.dynamic = true -- resolved asynchronously, after the static pass
    elseif ns ~= "env" then
      unknown[ns] = true
    end
  end
  return s
end

-- Recurse `fn` over `config`, calling any function value (a dynamic value) and walking
-- its result. `string_fn(s)` handles each string leaf. Returns a fresh table (never
-- mutates the input). A function that errors fails loud.
local function map_config(config, string_fn)
  local function walk(v)
    local t = type(v)
    if t == "function" then
      local ok, res = pcall(v)
      if not ok then
        error("bemtvi-dap: a configuration value function errored: " .. tostring(res), 0)
      end
      return walk(res)
    elseif t == "table" then
      local out = {}
      for k, val in pairs(v) do
        out[k] = walk(val)
      end
      return out
    elseif t == "string" then
      return string_fn(v)
    end
    return v
  end
  return walk(config)
end

-- Expand every string in `config` (recursing into nested tables / `args` lists, calling
-- function values) against the current context. Returns `expanded, unknown_names,
-- has_dynamic` — `unknown_names` is the list of unrecognised `${...}` tokens (the caller
-- warns), and `has_dynamic` is true when an `${input:…}` / `${command:…}` remains for the
-- async `resolve_dynamic` pass. Pure: returns a fresh table.
function M.expand(config)
  local vars = M.context()
  local unknown = {}
  local flags = { dynamic = false }
  local expanded = map_config(config, function(s)
    return expand_string(s, vars, unknown, flags)
  end)
  local names = {}
  for name in pairs(unknown) do
    names[#names + 1] = name
  end
  return expanded, names, flags.dynamic
end

-- ----- interactive (`${input:…}` / `${command:…}`) resolution ----------------

-- Index a config's `inputs` list (VSCode launch.json shape: `{ id, type, description?,
-- default?, options?, command?, args? }`) by id.
local function index_inputs(list)
  local by_id = {}
  for _, def in ipairs(list or {}) do
    if def.id then
      by_id[def.id] = def
    end
  end
  return by_id
end

-- Resolve the interactive `${input:id}` / `${command:id}` tokens left by `expand`,
-- returning a PROMISE of the fully-resolved config. `${input:id}` looks up `config.inputs`
-- and prompts per its `type` (`promptString` → text, `pickString` → a menu, `command` →
-- a registered command); `${command:id}` runs `ctx.commands[id]` (which may return a
-- string or a promise). Each id is resolved once (cached), so a token referenced twice
-- prompts once. A missing definition, an unsupported type, or a cancelled prompt rejects
-- the promise (the launch is aborted loud — never a silent empty value).
function M.resolve_dynamic(config, ctx)
  ctx = ctx or {}
  local inputs = index_inputs(config.inputs)
  local commands = ctx.commands or {}
  local cache = {}
  return btv.async(function()
    local function run_command(id, args)
      local fn = commands[id]
      if not fn then
        error("bemtvi-dap: no command registered for ${command:" .. id .. "}", 0)
      end
      return tostring(btv.await(fn(args, config)))
    end
    local function run_input(id)
      local def = inputs[id]
      if not def then
        error("bemtvi-dap: no input '" .. id .. "' defined (config.inputs)", 0)
      end
      local kind = def.type
      if kind == "promptString" then
        local v = btv.await(btv.ui.input({
          prompt = (def.description or id) .. ": ",
          default = def.default or "",
        }))
        if v == nil then
          error("bemtvi-dap: input '" .. id .. "' cancelled", 0)
        end
        return v
      elseif kind == "pickString" then
        local v = btv.await(btv.ui.select(def.options or {}, { prompt = def.description or id }))
        if v == nil then
          error("bemtvi-dap: pick '" .. id .. "' cancelled", 0)
        end
        return tostring(v)
      elseif kind == "command" then
        return run_command(def.command, def.args)
      else
        error("bemtvi-dap: input '" .. id .. "' has unsupported type " .. tostring(kind), 0)
      end
    end
    local function token(ns, id)
      local key = ns .. ":" .. id
      if cache[key] == nil then
        cache[key] = (ns == "input") and run_input(id) or run_command(id)
      end
      return cache[key]
    end
    -- Replace the dynamic tokens in one string, awaiting each (a manual scan so the
    -- cursor advances past every match — including an unknown `${ns:id}` left as-is).
    local function resolve_string(s)
      local out, pos = {}, 1
      while true do
        local a, b, ns, id = s:find("%${(%a[%w]*):([%w_%.%-]+)}", pos)
        if not a then
          out[#out + 1] = s:sub(pos)
          break
        end
        out[#out + 1] = s:sub(pos, a - 1)
        if ns == "input" or ns == "command" then
          out[#out + 1] = token(ns, id)
        else
          out[#out + 1] = s:sub(a, b) -- not ours (already warned by expand)
        end
        pos = b + 1
      end
      return table.concat(out)
    end
    return map_config(config, resolve_string)
  end)()
end

return M
