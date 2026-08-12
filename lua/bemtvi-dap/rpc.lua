-- The Debug Adapter Protocol wire codec: `Content-Length: N\r\n\r\n<N bytes JSON>`,
-- the exact framing LSP uses. The transport (`btv.process`) hands us RAW, un-split
-- byte chunks — a single read can carry half a header, several whole messages, or a
-- message split mid-body — so the decoder is a stateful accumulator that emits one
-- decoded table per complete frame and buffers the partial tail for the next chunk.
--
-- (This is why bemtvi-dap needs the duplex `btv.process` and not `btv.run_stream`: the
-- latter newline-splits stdout, which shreds a frame whose JSON body or `\r\n\r\n`
-- separator the split falls inside.)

local M = {}

-- Frame a DAP message table into a wire string ready for `handle:write`.
function M.encode(msg)
  local body = btv.json.encode(msg)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

-- Parse the Content-Length out of a header block (case-insensitive, tolerant of an
-- accompanying Content-Type line). Returns the integer byte count or nil.
local function content_length(header)
  for line in (header .. "\r\n"):gmatch("(.-)\r\n") do
    local key, value = line:match("^%s*(%S+)%s*:%s*(%d+)%s*$")
    if key and key:lower() == "content-length" then
      return tonumber(value)
    end
  end
end

-- Build a stateful decoder. Feed it raw chunks via the returned `feed(chunk)`; it
-- invokes `on_message(table)` once per complete frame. A malformed header (no
-- Content-Length) or an undecodable body calls `on_error(msg)` (LOUD — never a
-- silent drop) and resyncs.
--
-- The unconsumed bytes are held as a LIST of chunks rather than one growing string:
-- appending is then O(chunk), and the chunks are joined only when a whole frame might
-- be present. `buf = buf .. chunk` per read would copy everything retained so far on
-- every read — quadratic in the size of a big reply (a `variables` response for a large
-- container arrives as many pipe-sized reads), which is exactly the per-event cost that
-- scales with total size that the editor must never pay.
function M.decoder(on_message, on_error)
  local chunks, size = {}, 0
  -- Bytes needed, counted from the start of the unconsumed data, to complete the frame
  -- whose header we already parsed. nil while we are still looking for a header.
  local need = nil
  local function fail(msg)
    if on_error then
      on_error(msg)
    end
  end
  return function(chunk)
    if chunk == nil or chunk == "" then
      return
    end
    chunks[#chunks + 1] = chunk
    size = size + #chunk
    if need and size < need then
      return -- the body is still arriving: nothing to parse, and nothing to copy
    end

    local buf = #chunks == 1 and chunks[1] or table.concat(chunks)
    local pos = 1
    need = nil
    local ready = {} -- decoded frames, dispatched once the decoder state is settled
    while true do
      local hstart, hend = buf:find("\r\n\r\n", pos, true)
      if not hstart then
        break -- header still incomplete
      end
      local header = buf:sub(pos, hstart - 1)
      local len = content_length(header)
      if not len then
        fail("bemtvi-dap: missing Content-Length in DAP header: " .. header)
        pos = #buf + 1 -- can't trust the stream position; resync from empty
        break
      end
      local body_start = hend + 1
      if #buf - body_start + 1 < len then
        need = (body_start - pos) + len -- wait for the rest of the body
        break
      end
      local ok, decoded = pcall(btv.json.decode, buf:sub(body_start, body_start + len - 1))
      pos = body_start + len
      if ok then
        ready[#ready + 1] = decoded
      else
        fail("bemtvi-dap: undecodable DAP body: " .. tostring(decoded))
      end
    end

    -- Settle the buffered tail BEFORE dispatching, so a handler that feeds the decoder
    -- again (or tears the session down) can't race a half-updated state.
    local rest = pos > #buf and "" or buf:sub(pos)
    chunks, size = rest ~= "" and { rest } or {}, #rest
    for _, msg in ipairs(ready) do
      on_message(msg)
    end
  end
end

return M
