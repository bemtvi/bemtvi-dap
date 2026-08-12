-- The Content-Length wire codec: framing round-trips, and the incremental decoder's
-- handling of split / coalesced / multi-message byte chunks (the raw shapes
-- btv.process delivers). Pure logic — no editor session.

local rpc = require("bemtvi-dap.rpc")

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

btv.test.describe("bemtvi-dap.rpc", function()
  btv.test.it("frames a message with a byte-accurate Content-Length", function()
    local wire = rpc.encode({ seq = 1, type = "request", command = "initialize" })
    local body = btv.json.encode({ seq = 1, type = "request", command = "initialize" })
    btv.test.expect(wire).to_be("Content-Length: " .. #body .. "\r\n\r\n" .. body)
  end)

  btv.test.it("decodes a single whole frame", function()
    local out = decode_all({ rpc.encode({ type = "event", event = "stopped" }) })
    btv.test.expect(#out).to_be(1)
    btv.test.expect(out[1].event).to_be("stopped")
  end)

  btv.test.it("reassembles a frame split across chunks (header + body torn)", function()
    local wire = rpc.encode({ type = "response", request_seq = 7, success = true })
    -- Tear it at three awkward points: mid-header, at the separator, mid-body.
    local a, b, c = wire:sub(1, 8), wire:sub(9, 22), wire:sub(23)
    local out = decode_all({ a, b, c })
    btv.test.expect(#out).to_be(1)
    btv.test.expect(out[1].request_seq).to_be(7)
  end)

  btv.test.it("emits multiple messages coalesced in one chunk", function()
    local glued = rpc.encode({ type = "event", event = "a" })
      .. rpc.encode({ type = "event", event = "b" })
      .. rpc.encode({ type = "event", event = "c" })
    local out = decode_all({ glued })
    btv.test.expect(#out).to_be(3)
    btv.test.expect(out[1].event .. out[2].event .. out[3].event).to_be("abc")
  end)

  btv.test.it("preserves a body with embedded newlines (output events)", function()
    local out = decode_all({
      rpc.encode({ type = "event", event = "output", body = { output = "a\nb\r\nc" } }),
    })
    btv.test.expect(out[1].body.output).to_be("a\nb\r\nc")
  end)

  -- A big reply (a `variables` response for a large container) arrives as many
  -- pipe-sized reads. The decoder must reassemble it without re-copying everything
  -- retained so far on each read, and hand back the exact payload.
  btv.test.it("reassembles a large body delivered in many small chunks", function()
    local big = string.rep("x", 200000)
    local wire = rpc.encode({ type = "response", request_seq = 1, body = { value = big } })
    local pieces = {}
    for i = 1, #wire, 512 do
      pieces[#pieces + 1] = wire:sub(i, i + 511)
    end
    btv.test.expect(#pieces > 300).to_be_truthy() -- genuinely many reads
    local out, errs = decode_all(pieces)
    btv.test.expect(#errs).to_be(0)
    btv.test.expect(#out).to_be(1)
    btv.test.expect(#out[1].body.value).to_be(#big)
  end)

  -- A frame torn mid-body must carry its tail into the next chunk — together with any
  -- whole frames glued behind it.
  btv.test.it("carries a torn frame's tail into the next chunk's frames", function()
    local a = rpc.encode({ type = "event", event = "one" })
    local b = rpc.encode({ type = "event", event = "two" })
    local glued = a .. b
    local cut = #a - 3 -- tear inside the first frame's body
    local out = decode_all({ glued:sub(1, cut), glued:sub(cut + 1) })
    btv.test.expect(#out).to_be(2)
    btv.test.expect(out[1].event).to_be("one")
    btv.test.expect(out[2].event).to_be("two")
  end)

  btv.test.it("reports a malformed header loud, then resyncs", function()
    local good = rpc.encode({ type = "event", event = "ok" })
    local out, errs = decode_all({ "GET / HTTP/1.1\r\n\r\n", good })
    btv.test.expect(#errs).never.to_be(0)
    -- After resync the next good frame still decodes.
    btv.test.expect(#out).to_be(1)
    btv.test.expect(out[1].event).to_be("ok")
  end)
end)
