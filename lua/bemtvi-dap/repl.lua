-- The REPL / debug console: a bottom-dock `btv.view` that collects the adapter's
-- `output` events and the results of expressions you evaluate in the stopped frame.
-- A view is read-only, so input is entered through an `btv.ui.input` prompt (opened
-- with `<CR>`/`i` on the view, or `:DapEval`) rather than typed into the buffer —
-- the same pattern bemtvi-tree uses for rename/create.

local M = {}

local view, ns, cfg
local session
local lines = {} -- the console scrollback
local marks = {} -- per-line highlight marks (parallel to lines)
local pending = "" -- partial output line awaiting its newline
local render_queued = false -- a repaint is already scheduled for the end of this tick

-- The scrollback ceiling. A repaint ships the WHOLE console (a view owns its lines), so
-- an uncapped buffer would make a debuggee that logs in a loop cost O(everything ever
-- printed) per output event — the O(N²) flood the editor must never do. The oldest lines
-- are dropped once the cap is passed. `repl.max_lines = 0` (or false) lifts the cap.
local DEFAULT_MAX_LINES = 5000

local function ensure_view()
  if view then
    return
  end
  view = btv.view.create({ name = "bemtvi-dap-repl", filetype = "btvdap-repl" })
  ns = btv.ns.create("bemtvi-dap-repl")
  view:on_select(function()
    M.prompt()
  end)
end

function M.setup(config)
  cfg = config
end

function M.set_session(s)
  session = s
end

function M.is_open()
  return view ~= nil and view:winid() ~= nil
end

-- The REPL's backing buffer / window / 1-based cursor line (or nil before it exists).
-- For tests and the focus check.
function M.bufnr()
  return view and view:bufnr()
end
function M.winid()
  return view and view:winid()
end
function M.cursor_line()
  return view and view:line()
end

-- Whether the REPL is the focused window right now — the gate for auto-scrolling. Output
-- events shouldn't tail (and steal focus) while you're editing elsewhere.
local function is_focused()
  local win = view and view:winid()
  return win ~= nil and win == btv.win.current()
end

function M.open()
  ensure_view()
  if not M.is_open() then
    view:mount({ dock = cfg.repl.position, size = cfg.repl.height })
  end
  M.render()
end

function M.close()
  if view and M.is_open() then
    view:unmount()
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- A view's backing buffer lands a tick AFTER create, and `:set_decor` is a no-op until
-- it exists (`:set_lines` queues fine). A repaint issued in the same tick as `open()` —
-- the "─ starting … ─" banner, the first burst of adapter output — would therefore lose
-- its highlights for good, since nothing repaints those lines again. Wait for the
-- buffer (once, bounded) and lay the decorations down then.
--
-- Only the DECORATIONS are re-applied: the lines are already in (they queue), and a
-- full render would tail the cursor a tick late — after the user has moved it.
local awaiting_buf = false
local function decor_when_ready()
  if awaiting_buf then
    return
  end
  awaiting_buf = true
  btv.wait_for(function()
    return view and view:bufnr()
  end, { tries = 50, message = "bemtvi-dap: the REPL buffer never materialized" }):next(function()
    awaiting_buf = false
    if view and view:bufnr() then
      view:set_decor(ns, marks)
    end
  end, function(err)
    awaiting_buf = false
    btv.notify(tostring(err and err.message or err), 4)
  end)
end

function M.render()
  if not view then
    return
  end
  view:set_lines(#lines > 0 and lines or { "" })
  if not view:bufnr() then
    decor_when_ready()
    return
  end
  view:set_decor(ns, marks)
  -- Tail the newest line, but ONLY while the REPL is the focused window — `set_cursor`
  -- focuses the view, so doing it on every render would let adapter output yank the
  -- cursor / steal focus while you're editing elsewhere. When the REPL is focused (you
  -- just evaluated, or you're reading it) it follows the output as before.
  if #lines > 0 and is_focused() then
    view:set_cursor(#lines)
  end
end

-- The configured scrollback ceiling (0 / false = unbounded).
local function max_lines()
  local n = cfg and cfg.repl and cfg.repl.max_lines
  if n == nil then
    return DEFAULT_MAX_LINES
  end
  return (n and n > 0) and n or nil
end

-- Drop the oldest lines once the scrollback passes its ceiling, shifting every mark up
-- by as many rows (a mark's row is an index into `lines`, so a trim that left them alone
-- would smear every highlight down the console).
local function trim()
  local cap = max_lines()
  if not cap or #lines <= cap then
    return
  end
  local drop = #lines - cap
  local kept = {}
  for i = drop + 1, #lines do
    kept[#kept + 1] = lines[i]
  end
  lines = kept
  local kept_marks = {}
  for _, m in ipairs(marks) do
    if m.line >= drop then
      m.line = m.line - drop
      m.end_row = m.end_row - drop
      kept_marks[#kept_marks + 1] = m
    end
  end
  marks = kept_marks
end

-- Append `text` as one or more display lines, optionally highlighting each whole line
-- with `hl`. `text` may carry embedded newlines (a multi-line eval error / info
-- message): split them so the shadow `lines` stays 1:1 with the view buffer — which
-- splits on "\n" too. A single mark spanning the joined string would otherwise be
-- clamped to the first row (highlighting only the first line) AND `#lines` would fall
-- behind the real buffer, so `set_cursor(#lines)` could no longer tail the newest line.
local function push(text, hl)
  for _, line in ipairs(vim.split(text, "\n")) do
    lines[#lines + 1] = line
    if hl then
      marks[#marks + 1] =
        { line = #lines - 1, col = 0, end_row = #lines - 1, end_col = #line, hl_group = hl }
    end
  end
  trim()
end

-- Repaint once at the end of this convergence instead of per event. Adapter output
-- arrives in bursts (a debuggee printing in a loop delivers many `output` events per
-- tick) and a repaint ships the whole console, so painting per event turns a burst into
-- O(events × scrollback). The user-paced paths (`info`, `eval`, `open`) render straight
-- away — there is only ever one of those per action.
local function render_soon()
  if render_queued or not view then
    return
  end
  render_queued = true
  btv.schedule(function()
    render_queued = false
    M.render()
  end)
end

-- Append text (which may contain several lines / a partial tail) from an output
-- stream, keeping an unterminated fragment buffered until its newline arrives.
--
-- The DAP `telemetry` category is for telemetry servers, not the user — the spec says
-- clients must not display it. debugpy emits two such events on attach (`output: "ptvsd"`
-- and `"debugpy"`, neither newline-terminated), which would otherwise sit in `pending`,
-- concatenate into a stray `ptvsddebugpy`, and get dumped before the first real output.
function M.append_output(category, text)
  if category == "telemetry" then
    return
  end
  pending = pending .. text:gsub("\r\n", "\n")
  local flushed = false
  local pos = 1
  while true do
    local nl = pending:find("\n", pos, true)
    if not nl then
      break
    end
    push(pending:sub(pos, nl - 1))
    pos = nl + 1
    flushed = true
  end
  -- One slice for the unconsumed tail, rather than re-slicing the whole buffer per line
  -- (which is quadratic in a chunk carrying many lines — exactly what a burst looks like).
  pending = pos > 1 and pending:sub(pos) or pending
  if flushed then
    render_soon()
  end
end

-- Flush any buffered partial line (on session end), so a trailing prompt without a
-- newline isn't lost.
function M.flush()
  if pending ~= "" then
    push(pending)
    pending = ""
    M.render()
  end
end

-- Echo a one-off informational line (session lifecycle).
function M.info(text)
  push(text, "BtvDapUIDecoration")
  M.render()
end

-- Evaluate `expr` in the current stopped frame and append the prompt + result.
function M.eval(expr)
  if expr == nil or expr == "" then
    return
  end
  push("> " .. expr, "BtvDapReplPrompt")
  M.render()
  if not session then
    push("  (no active session)", "BtvDapReplError")
    M.render()
    return
  end
  local frame_id = session.current_frame and session.current_frame.id
  session:evaluate(expr, frame_id, "repl", function(err, body)
    if err then
      for _, l in ipairs(vim.split(tostring(err.message or ""), "\n")) do
        push("  " .. l, "BtvDapReplError")
      end
    else
      for _, l in ipairs(vim.split((body and body.result) or "", "\n")) do
        push("  " .. l)
      end
    end
    M.render()
  end)
end

-- Map the adapter's DAP `CompletionItem`s to the `btv.ui.input` wildmenu shape
-- (`{ label, insert, doc, start?, length? }`). `text` defaults to `label` (DAP spec),
-- `detail` (when the adapter sends one) becomes the side-docs body, headed by the
-- item's `type` (`function`, `variable`, …) so the pane reads like a tiny signature
-- card. When the adapter specifies an explicit replace range (`start`/`length`), it is
-- forwarded so the completion overwrites exactly that span rather than the editor's
-- trailing-identifier token.
--
-- `start` is the 0-based char offset core wants, used as-is. The DAP spec says
-- `CompletionItem.start` honors the client's `columnsStartAt1` (we send `true`), which
-- would make it 1-based — but debugpy (the common Python adapter) ignores that for the
-- completions response and always emits a 0-based `start` (it computes `column - len(qualifier)`
-- on its own 0-based column and never converts back). Subtracting 1 here shifted every
-- replace span one char left, eating the character before the completed token (the `.`
-- in `os.get`, or mis-anchoring `abs(`). So we pass `start` through unchanged.
local function completion_items(targets)
  local out = {}
  for _, t in ipairs(targets) do
    local label = t.label or t.text or ""
    local doc = t.detail
    if t.type and t.type ~= "" then
      doc = doc and (t.type .. "\n\n" .. doc) or t.type
    end
    local item = { label = label, insert = t.text or label, doc = doc }
    if t.start ~= nil and t.length ~= nil then
      item.start = t.start
      item.length = t.length
    end
    out[#out + 1] = item
  end
  return out
end

-- The REPL's autocomplete source: ask the active adapter for completions at the
-- cursor (DAP columns are 1-based, so the 0-based `col` core hands us is `col + 1`),
-- in the current stopped frame. Returns a PROMISE — the request is a wire round-trip
-- — that resolves to the wildmenu candidates (empty when there's no session or the
-- adapter has no `completions` support, which simply opens no menu).
local function repl_complete(line, col)
  return btv.promise.new(function(resolve)
    if not session then
      return resolve({})
    end
    local frame_id = session.current_frame and session.current_frame.id
    session:completions(line, col + 1, frame_id, function(err, targets)
      if err or not targets then
        return resolve({})
      end
      resolve(completion_items(targets))
    end)
  end)
end

-- Open an input prompt for the next REPL expression. `history` gives the prompt
-- readline-style recall (`<Up>`/`<Down>`) over the expressions evaluated this
-- session, scoped to its own namespace so it's independent of the `:` / search
-- histories and of any other plugin's input history. `complete` wires `<Tab>`
-- autocomplete (with a side-docs pane) to the adapter's `completions` request.
--
-- The prompt STAYS OPEN like a real REPL: each `<CR>` evaluates the line and reopens
-- the prompt for the next expression; only `<Esc>` (which resolves the input to nil,
-- vs `""` for an empty `<CR>`) closes the loop. An empty `<CR>` re-prompts without
-- evaluating (`M.eval` no-ops on "").
function M.prompt()
  btv.ui
    .input({
      prompt = "dap> ",
      history = "bemtvi-dap-repl",
      complete = repl_complete,
    })
    :next(function(expr)
      if expr == nil then
        return -- <Esc> ends the REPL prompt loop
      end
      M.eval(expr)
      M.prompt() -- reopen for the next line, keeping the REPL input open
    end)
end

function M.clear()
  lines = {}
  marks = {}
  pending = ""
  if view then
    M.render()
  end
end

-- Tear the REPL fully down — drop its view (and dock) and scrollback — so it starts from
-- a clean slate. For tests that need a hermetic REPL independent of any prior session.
function M._reset()
  if view then
    view:close()
    view = nil
  end
  lines = {}
  marks = {}
  pending = ""
  render_queued = false
end

return M
