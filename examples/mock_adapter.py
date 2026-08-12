#!/usr/bin/env python3
# A minimal Debug Adapter Protocol server for the bemtvi-dap demo. It speaks the real
# Content-Length-framed wire over stdio (the exact path a real adapter uses through
# btv.process), but its "execution" is scripted: it reports one stopped frame at line 2
# of the launched `program`, single steps to line 3, and terminates on continue. Enough
# to exercise the whole client: handshake, breakpoints, the stopped drill-down
# (threads/stackTrace/scopes/variables), stepping, evaluate, watches, variable editing
# (setVariable / setExpression), exception breakpoint filters, restart, and teardown.
import sys
import json

seq = 0
program = "unknown"
current_line = 2
# The Locals scope's values, mutated by setVariable / setExpression so an edit shows up
# on the next `variables` read.
local_vars = {"x": "42", "n": "10"}


def write(msg):
    global seq
    seq += 1
    msg["seq"] = seq
    data = json.dumps(msg).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def respond(req, body=None, success=True):
    write({
        "type": "response",
        "request_seq": req["seq"],
        "success": success,
        "command": req["command"],
        "body": body or {},
    })


def event(name, body=None):
    write({"type": "event", "event": name, "body": body or {}})


def read_msg():
    header = b""
    while b"\r\n\r\n" not in header:
        ch = sys.stdin.buffer.read(1)
        if not ch:
            return None
        header += ch
    length = 0
    for line in header.decode("utf-8").split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    body = b""
    while len(body) < length:
        chunk = sys.stdin.buffer.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body.decode("utf-8"))


def main():
    global program, current_line, local_vars
    while True:
        req = read_msg()
        if req is None:
            break
        cmd = req.get("command")
        args = req.get("arguments") or {}
        if cmd == "initialize":
            respond(req, {
                "supportsConfigurationDoneRequest": True,
                "supportsSetVariable": True,
                "supportsSetExpression": True,
                "supportsRestartRequest": True,
                "supportsConditionalBreakpoints": True,
                "supportsHitConditionalBreakpoints": True,
                "supportsLogPoints": True,
                "exceptionBreakpointFilters": [
                    {"filter": "raised", "label": "Raised Exceptions", "default": False},
                    {"filter": "uncaught", "label": "Uncaught Exceptions", "default": True},
                ],
            })
            event("initialized")
        elif cmd == "launch":
            program = args.get("program", program)
            respond(req)
        elif cmd == "attach":
            respond(req)
        elif cmd == "setBreakpoints":
            bps = args.get("breakpoints", [])
            verified = [{"verified": True, "line": b.get("line")} for b in bps]
            respond(req, {"breakpoints": verified})
        elif cmd == "setExceptionBreakpoints":
            respond(req)
            filters = ", ".join(args.get("filters", []))
            event("output", {"category": "console", "output": "exception filters: [%s]\n" % filters})
        elif cmd == "setVariable":
            local_vars[args.get("name")] = args.get("value")
            respond(req, {"value": args.get("value"), "variablesReference": 0})
        elif cmd == "setExpression":
            local_vars[args.get("expression")] = args.get("value")
            respond(req, {"value": args.get("value"), "variablesReference": 0})
        elif cmd == "restart":
            current_line = 2
            respond(req)
            event("output", {"category": "console", "output": "restarted\n"})
            event("stopped", {"reason": "breakpoint", "threadId": 1, "allThreadsStopped": True})
        elif cmd == "configurationDone":
            respond(req)
            event("output", {"category": "console", "output": "running\n"})
            event("stopped", {"reason": "breakpoint", "threadId": 1, "allThreadsStopped": True})
        elif cmd == "threads":
            respond(req, {"threads": [{"id": 1, "name": "main"}]})
        elif cmd == "stackTrace":
            respond(req, {
                "stackFrames": [
                    {"id": 1000, "name": "main", "line": current_line, "column": 1,
                     "source": {"path": program, "name": program}},
                ],
                "totalFrames": 1,
            })
        elif cmd == "scopes":
            respond(req, {"scopes": [
                {"name": "Locals", "variablesReference": 2000, "expensive": False},
            ]})
        elif cmd == "variables":
            respond(req, {"variables": [
                {"name": name, "value": value, "type": "int", "variablesReference": 0}
                for name, value in local_vars.items()
            ]})
        elif cmd == "evaluate":
            respond(req, {"result": args.get("expression", "") + " => ok", "variablesReference": 0})
        elif cmd in ("next", "stepIn", "stepOut"):
            current_line = 3
            respond(req)
            event("stopped", {"reason": "step", "threadId": 1, "allThreadsStopped": True})
        elif cmd == "continue":
            respond(req, {"allThreadsContinued": True})
            event("terminated")
        elif cmd == "pause":
            respond(req)
            event("stopped", {"reason": "pause", "threadId": 1, "allThreadsStopped": True})
        elif cmd == "disconnect":
            respond(req)
            event("terminated")
            break
        else:
            respond(req)


if __name__ == "__main__":
    main()
