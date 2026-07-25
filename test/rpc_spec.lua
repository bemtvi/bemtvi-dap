-- The Content-Length wire codec: framing round-trips, and the incremental decoder's
-- handling of split / coalesced / multi-message byte chunks (the raw shapes
-- nx.process delivers). Pure logic — no editor session.

local rpc = require("nxvim-dap.rpc")

-- Collect every frame a decoder emits when fed `chunks` in order.
local function decode_all(chunks)
  local out, errs = {}, {}
  local feed = rpc.decoder(function(m)
    out[#out + 1] = m
  end, function(e)
    errs[#errs + 1] = e
  end)
  for _, c in ipairs(chunks) do
    feed(c)
  end
  return out, errs
end

nx.test.describe("nxvim-dap.rpc", function()
  nx.test.it("frames a message with a byte-accurate Content-Length", function()
    local wire = rpc.encode({ seq = 1, type = "request", command = "initialize" })
    local body = nx.json.encode({ seq = 1, type = "request", command = "initialize" })
    nx.test.expect(wire).to_be("Content-Length: " .. #body .. "\r\n\r\n" .. body)
  end)

  nx.test.it("decodes a single whole frame", function()
    local out = decode_all({ rpc.encode({ type = "event", event = "stopped" }) })
    nx.test.expect(#out).to_be(1)
    nx.test.expect(out[1].event).to_be("stopped")
  end)

  nx.test.it("reassembles a frame split across chunks (header + body torn)", function()
    local wire = rpc.encode({ type = "response", request_seq = 7, success = true })
    -- Tear it at three awkward points: mid-header, at the separator, mid-body.
    local a, b, c = wire:sub(1, 8), wire:sub(9, 22), wire:sub(23)
    local out = decode_all({ a, b, c })
    nx.test.expect(#out).to_be(1)
    nx.test.expect(out[1].request_seq).to_be(7)
  end)

  nx.test.it("emits multiple messages coalesced in one chunk", function()
    local glued = rpc.encode({ type = "event", event = "a" })
      .. rpc.encode({ type = "event", event = "b" })
      .. rpc.encode({ type = "event", event = "c" })
    local out = decode_all({ glued })
    nx.test.expect(#out).to_be(3)
    nx.test.expect(out[1].event .. out[2].event .. out[3].event).to_be("abc")
  end)

  nx.test.it("preserves a body with embedded newlines (output events)", function()
    local out = decode_all({
      rpc.encode({ type = "event", event = "output", body = { output = "a\nb\r\nc" } }),
    })
    nx.test.expect(out[1].body.output).to_be("a\nb\r\nc")
  end)

  -- A big reply (a `variables` response for a large container) arrives as many
  -- pipe-sized reads. The decoder must reassemble it without re-copying everything
  -- retained so far on each read, and hand back the exact payload.
  nx.test.it("reassembles a large body delivered in many small chunks", function()
    local big = string.rep("x", 200000)
    local wire = rpc.encode({ type = "response", request_seq = 1, body = { value = big } })
    local pieces = {}
    for i = 1, #wire, 512 do
      pieces[#pieces + 1] = wire:sub(i, i + 511)
    end
    nx.test.expect(#pieces > 300).to_be_truthy() -- genuinely many reads
    local out, errs = decode_all(pieces)
    nx.test.expect(#errs).to_be(0)
    nx.test.expect(#out).to_be(1)
    nx.test.expect(#out[1].body.value).to_be(#big)
  end)

  -- A frame torn mid-body must carry its tail into the next chunk — together with any
  -- whole frames glued behind it.
  nx.test.it("carries a torn frame's tail into the next chunk's frames", function()
    local a = rpc.encode({ type = "event", event = "one" })
    local b = rpc.encode({ type = "event", event = "two" })
    local glued = a .. b
    local cut = #a - 3 -- tear inside the first frame's body
    local out = decode_all({ glued:sub(1, cut), glued:sub(cut + 1) })
    nx.test.expect(#out).to_be(2)
    nx.test.expect(out[1].event).to_be("one")
    nx.test.expect(out[2].event).to_be("two")
  end)

  nx.test.it("reports a malformed header loud, then resyncs", function()
    local good = rpc.encode({ type = "event", event = "ok" })
    local out, errs = decode_all({ "GET / HTTP/1.1\r\n\r\n", good })
    nx.test.expect(#errs).never.to_be(0)
    -- After resync the next good frame still decodes.
    nx.test.expect(#out).to_be(1)
    nx.test.expect(out[1].event).to_be("ok")
  end)
end)
