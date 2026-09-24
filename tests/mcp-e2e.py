#!/usr/bin/env python3
"""End-to-end test of mcp/shani_harness_mcp.py against a real slot.

Speaks MCP (JSON-RPC over stdio) to the server exactly like an agent client
would, and runs the full look/act loop on a real GTK app inside @<slot>:
start -> wait -> screenshot (must be a PNG image) -> tree (must show the OK
button) -> type -> click OK by accessibility name -> stop -> the app's own
stdout must equal what was typed. Needs a bootstrapped slot.

  tests/mcp-e2e.py [slot]
"""
import base64
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "mcp", "shani_harness_mcp.py")
slot = sys.argv[1] if len(sys.argv) > 1 else "blue"

proc = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
seq = 0
results = []


def rpc(method, params=None):
    global seq
    seq += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


def tool(name, **args):
    r = rpc("tools/call", {"name": name, "arguments": args})
    return r.get("result", {"isError": True, "content": [{"type": "text", "text": json.dumps(r.get("error"))}]})


def check(label, ok, detail=""):
    results.append(ok)
    print("RESULT %-28s %s  %s" % (label, "PASS" if ok else "FAIL", detail[:140]))


def first_text(res):
    return next((c["text"] for c in res.get("content", []) if c["type"] == "text"), "")


init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "0"}})
check("initialize", init.get("result", {}).get("serverInfo", {}).get("name") == "shani-harness")
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); proc.stdin.flush()

r = tool("app_start", slot=slot, command="yad --entry --title='MCP Demo' --text='Your name:' --button=Cancel:1 --button=OK:0")
check("app_start", not r.get("isError"), first_text(r))
if r.get("isError"):
    sys.exit(1)
r = tool("app_wait_window", title="MCP Demo", timeout=90)
check("app_wait_window", not r.get("isError"), first_text(r))
r = tool("app_screenshot")
img = next((c for c in r.get("content", []) if c["type"] == "image"), None)
png = base64.b64decode(img["data"]) if img else b""
check("app_screenshot is PNG", png[:8] == b"\x89PNG\r\n\x1a\n", "%d bytes" % len(png))
r = tool("app_tree")
check("app_tree shows OK button", "button 'OK'" in first_text(r), first_text(r).replace("\n", " | ")[:140])
r = tool("app_find", query="button:^nope$")
check("app_find negative", bool(r.get("isError")), first_text(r))
r = tool("app_type", text="typed via mcp")
check("app_type", not r.get("isError"), first_text(r))
r = tool("app_click_element", query="button:^OK$")
check("app_click_element OK", not r.get("isError"), first_text(r))
r = tool("app_stop")
out = json.loads(first_text(r)) if not r.get("isError") else {}
check("app stdout == typed", out.get("stdout") == "typed via mcp" and out.get("rc") == "0",
      "stdout=%r rc=%r" % (out.get("stdout"), out.get("rc")))
proc.stdin.close()
proc.wait(timeout=60)
print("%d/%d passed" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
