#!/usr/bin/env python3
"""shani-harness MCP server — lets an AI agent drive the ShaniOS test harness.

Two groups of tools:

  * GUI app testing ("computer use" for native apps, like Claude in Chrome
    does for web apps): start an app inside a real ShaniOS slot on a private
    virtual display, then screenshot it, read its accessibility tree, click,
    type, press keys, scroll, drag, wait for windows — and finally get the
    app's stdout and exit code. Backed by `test.sh app --control=...`.
  * Harness commands: status, verify-boot, probe, upgrade, rollback, suite,
    vmspawn, ... (an allow-list), returning their output.

Transport: MCP over stdio (newline-delimited JSON-RPC 2.0), stdlib only.

  claude mcp add shani-harness -- python3 /path/to/shani-testbed/mcp/shani_harness_mcp.py

(expects shani-install-media next to shani-testbed, or SHANI_INSTALL_MEDIA)

Only one app session at a time. Everything runs through run_in_container.sh
exactly like a human would run it; nothing here needs root on the host.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import threading
import time

TESTBED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The image repo (shani-install-media): owns the builder-container runner and
# the harness state dir. Override with SHANI_INSTALL_MEDIA.
REPO = os.path.realpath(os.environ.get("SHANI_INSTALL_MEDIA",
                                       os.path.join(TESTBED, "..", "shani-install-media")))
RUNNER = os.path.join(REPO, "run_in_container.sh")
TEST_SH = os.path.join(TESTBED, "testbed")          # HOST-ONLY commands
DATA_DIR = os.path.realpath(os.environ.get("SHANIOS_TEST_DATA", os.path.join(REPO, "test-env", "disk")))
CONTAINER_REPO = "/home/builduser/build"   # run_in_container.sh's CONTAINER_WORK_DIR
SESSION_DIR = os.path.join(DATA_DIR, "mcp-session")
PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
SERVER_INFO = {"name": "shani-harness", "version": "1.0.0"}

# Harness commands an agent may run. HOST-ONLY ones run test.sh directly.
CONTAINER_COMMANDS = {"status", "clean", "ca", "bootstrap", "verify-boot", "probe", "enter",
                      "upgrade", "rollback", "update-check", "reboot", "pacstrap", "suite",
                      "install", "configure"}
HOST_COMMANDS = {"vmspawn"}


def to_host_path(path):
    """Container path under the bind-mounted repo -> host path."""
    if path and path.startswith(CONTAINER_REPO + "/"):
        return os.path.join(REPO, path[len(CONTAINER_REPO) + 1:])
    return path


class AppSession:
    def __init__(self):
        self.proc = None
        self.log = None
        self.seq = 0
        self.info = None
        self.lock = threading.Lock()

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, slot, run, local_src=None, size="1280x800", display="virtual", startup_timeout=600):
        if self.running():
            raise RuntimeError("an app session is already running — call app_stop first")
        if os.path.isdir(SESSION_DIR):
            shutil.rmtree(SESSION_DIR, ignore_errors=True)
        os.makedirs(SESSION_DIR, exist_ok=True)
        ctl = CONTAINER_REPO + "/" + os.path.relpath(SESSION_DIR, REPO)
        args = [RUNNER, "build.sh", "test", "app", slot, "--run=" + run,
                "--size=" + size, "--display=" + display, "--control=" + ctl]
        if local_src:
            args.append("--local-src=" + local_src)
        self.log = open(os.path.join(DATA_DIR, "mcp-app-session.log"), "w")
        env = dict(os.environ, SHANIOS_NO_PULL=os.environ.get("SHANIOS_NO_PULL", "1"))
        # stdin MUST be detached: docker run -i would otherwise read the MCP
        # server's own JSON-RPC stream.
        self.proc = subprocess.Popen(args, cwd=REPO, stdin=subprocess.DEVNULL,
                                     stdout=self.log, stderr=subprocess.STDOUT, env=env)
        ready = os.path.join(SESSION_DIR, "session.json")
        deadline = time.time() + startup_timeout
        while time.time() < deadline:
            if os.path.exists(ready):
                with open(ready) as f:
                    self.info = json.load(f)
                return self.info
            if self.proc.poll() is not None:
                raise RuntimeError("app session exited during startup (rc=%s):\n%s"
                                   % (self.proc.returncode, self.tail()))
            time.sleep(1)
        self.proc.terminate()
        raise RuntimeError("app session not ready after %ss:\n%s" % (startup_timeout, self.tail()))

    def tail(self, n=40):
        try:
            with open(os.path.join(DATA_DIR, "mcp-app-session.log")) as f:
                return "".join(f.readlines()[-n:])
        except OSError:
            return ""

    def do(self, action, timeout=120):
        with self.lock:
            if not self.running():
                raise RuntimeError("no app session running — call app_start first")
            self.seq += 1
            rid = "r%d" % self.seq
            reply = os.path.join(SESSION_DIR, "reply.%s.json" % rid)
            with open(os.path.join(SESSION_DIR, "cmd.fifo"), "w") as f:
                f.write("%s %s\n" % (rid, action.replace("\n", "\\n")))
            deadline = time.time() + timeout
            while time.time() < deadline:
                if os.path.exists(reply):
                    with open(reply) as f:
                        msg = json.load(f)
                    try:
                        os.remove(reply)
                    except OSError:
                        pass
                    msg["file"] = to_host_path(msg.get("file") or "")
                    return msg
                if not self.running():
                    raise RuntimeError("app session ended:\n" + self.tail())
                time.sleep(0.1)
            raise RuntimeError("no reply to %r within %ss" % (action, timeout))

    def stop(self):
        out = {"stdout": "", "rc": None}
        if self.running():
            try:
                self.do("quit", timeout=30)
            except RuntimeError:
                pass
            try:
                self.proc.wait(timeout=90)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
        if self.info:
            host_out = to_host_path(self.info.get("out_dir", ""))
            for key, name in (("stdout", "app.stdout"), ("stderr", "app.stderr"), ("rc", "app.rc")):
                try:
                    with open(os.path.join(host_out, name)) as f:
                        out[key] = f.read().strip()
                except OSError:
                    pass
            out["out_dir"] = host_out
        self.proc, self.info = None, None
        return out


SESSION = AppSession()


def text(s, is_error=False):
    return {"content": [{"type": "text", "text": s}], "isError": is_error}


def action_result(msg):
    return text(msg.get("text", ""), not msg.get("ok", False))


def screenshot_result(msg):
    if not msg.get("ok") or not msg.get("file"):
        return action_result(msg)
    with open(msg["file"], "rb") as f:
        data = base64.b64encode(f.read()).decode()
    return {"content": [{"type": "image", "data": data, "mimeType": "image/png"},
                        {"type": "text", "text": msg["file"]}], "isError": False}


def point(a):
    if a.get("window"):
        return "@%s:%d,%d" % (a["window"], int(a["x"]), int(a["y"]))
    return "%d,%d" % (int(a["x"]), int(a["y"]))


def run_harness(command, args, timeout):
    if command in HOST_COMMANDS:
        argv = [TEST_SH, command] + args
    elif command in CONTAINER_COMMANDS:
        argv = [RUNNER, "build.sh", "test", command] + args
    else:
        return text("command %r is not allowed; allowed: %s"
                    % (command, ", ".join(sorted(CONTAINER_COMMANDS | HOST_COMMANDS))), True)
    env = dict(os.environ, SHANIOS_NO_PULL=os.environ.get("SHANIOS_NO_PULL", "1"))
    try:
        p = subprocess.run(argv, cwd=REPO, stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return text("timed out after %ss" % timeout, True)
    out = (p.stdout + p.stderr)[-20000:]
    return text("exit %d\n%s" % (p.returncode, out), p.returncode != 0)


XY = {"x": {"type": "integer"}, "y": {"type": "integer"},
      "window": {"type": "string", "description": "optional window-title regex; x,y are then relative to that window"}}
TOOLS = [
    ("app_start", "Start a GUI app inside a ShaniOS slot on a private virtual display (safe: never touches the real screen). Waits until ready. First run installs Xvfb/xdotool into the builder container.",
     {"slot": {"type": "string", "enum": ["blue", "green"]}, "command": {"type": "string", "description": "shell command run inside the slot, e.g. 'yad --entry'"},
      "local_src": {"type": "string", "description": "optional --local-src dir, e.g. /opt/shani-deploy/scripts"},
      "size": {"type": "string", "default": "1280x800"}, "display": {"type": "string", "enum": ["virtual", "host"], "default": "virtual"}},
     ["slot", "command"]),
    ("app_screenshot", "Screenshot of the whole virtual display (PNG image).", {}, []),
    ("app_tree", "Accessibility tree of the app (AT-SPI): [ref] role 'name' =value [states] @x,y wxh — the native-app DOM.", {"depth": {"type": "integer"}}, []),
    ("app_find", "Find on-screen elements. query: regex on name/role, or ROLE:NAME-REGEX like 'button:^OK$'.", {"query": {"type": "string"}}, ["query"]),
    ("app_click_element", "Click the centre of the Nth element matching query (see app_find).", {"query": {"type": "string"}, "nth": {"type": "integer", "default": 1}, "button": {"type": "string", "enum": ["left", "right", "double"], "default": "left"}}, ["query"]),
    ("app_click", "Click at pixel coordinates.", dict(XY, button={"type": "string", "enum": ["left", "middle", "right"], "default": "left"}), ["x", "y"]),
    ("app_double_click", "Double-click at pixel coordinates.", XY, ["x", "y"]),
    ("app_move", "Move the pointer (hover).", XY, ["x", "y"]),
    ("app_drag", "Press at (x1,y1), move to (x2,y2), release.", {"x1": {"type": "integer"}, "y1": {"type": "integer"}, "x2": {"type": "integer"}, "y2": {"type": "integer"}}, ["x1", "y1", "x2", "y2"]),
    ("app_scroll", "Scroll the wheel.", {"direction": {"type": "string", "enum": ["up", "down", "left", "right"]}, "amount": {"type": "integer", "default": 3}}, ["direction"]),
    ("app_type", "Type literal text into the focused widget.", {"text": {"type": "string"}}, ["text"]),
    ("app_key", "Press a key or combo (X keysyms): Return, Escape, Tab, ctrl+a, alt+F4, BackSpace.", {"combo": {"type": "string"}}, ["combo"]),
    ("app_windows", "List visible windows: id, position, size, title.", {}, []),
    ("app_wait_window", "Wait until a window whose title matches the regex is visible.", {"title": {"type": "string"}, "timeout": {"type": "integer", "default": 30}}, ["title"]),
    ("app_focus", "Give keyboard focus to the window matching the title regex.", {"title": {"type": "string"}}, ["title"]),
    ("app_status", "Is the app still running (or its exit code)?", {}, []),
    ("app_stop", "Stop the session; returns the app's stdout, stderr and exit code.", {}, []),
    ("harness_run", "Run a harness command (e.g. status, verify-boot blue, probe blue --exec=..., upgrade --local-src=..., suite). Returns exit code + output tail.",
     {"command": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}, "default": []}, "timeout": {"type": "integer", "default": 3600}}, ["command"]),
]


def call(name, a):
    if name == "app_start":
        info = SESSION.start(a["slot"], a["command"], a.get("local_src"), a.get("size", "1280x800"), a.get("display", "virtual"))
        return text("app session ready: " + json.dumps(info))
    if name == "app_stop":
        return text(json.dumps(SESSION.stop(), indent=1))
    if name == "harness_run":
        return run_harness(a["command"], list(a.get("args", [])), int(a.get("timeout", 3600)))
    if name == "app_screenshot":
        return screenshot_result(SESSION.do("screenshot"))
    mapping = {
        "app_tree": lambda: "tree" + ("=%d" % a["depth"] if a.get("depth") else ""),
        "app_find": lambda: "find=" + a["query"],
        "app_click_element": lambda: {"left": "click-element", "right": "rightclick-element", "double": "doubleclick-element"}[a.get("button", "left")]
                                     + "=" + a["query"] + ("#%d" % a["nth"] if a.get("nth", 1) != 1 else ""),
        "app_click": lambda: "%s=%s" % ("rightclick" if a.get("button") == "right" else "click", point(a))
                             + (":middle" if a.get("button") == "middle" else ""),
        "app_double_click": lambda: "doubleclick=" + point(a),
        "app_move": lambda: "move=" + point(a),
        "app_drag": lambda: "drag=%d,%d:%d,%d" % (a["x1"], a["y1"], a["x2"], a["y2"]),
        "app_scroll": lambda: "scroll=%s:%d" % (a["direction"], int(a.get("amount", 3))),
        "app_type": lambda: "type=" + a["text"],
        "app_key": lambda: "key=" + a["combo"],
        "app_windows": lambda: "windows",
        "app_wait_window": lambda: "wait-window=%s:%d" % (a["title"], int(a.get("timeout", 30))),
        "app_focus": lambda: "focus=" + a["title"],
        "app_status": lambda: "status",
    }
    if name not in mapping:
        return text("unknown tool %r" % name, True)
    return action_result(SESSION.do(mapping[name](), timeout=180))


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        want = (msg.get("params") or {}).get("protocolVersion")
        return {"protocolVersion": want if want in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                "capabilities": {"tools": {"listChanged": False}}, "serverInfo": SERVER_INFO,
                "instructions": "Drive GUI apps inside a ShaniOS test slot: app_start, then look (app_screenshot / app_tree), act (app_click_element, app_type, app_key, ...), look again; app_stop returns the app's output. Coordinates are virtual-display pixels."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": n, "description": d,
                           "inputSchema": {"type": "object", "properties": p, "required": r}}
                          for n, d, p, r in TOOLS]}
    if method == "tools/call":
        params = msg.get("params") or {}
        try:
            return call(params.get("name"), params.get("arguments") or {})
        except (RuntimeError, OSError, KeyError, ValueError) as e:
            return text("%s: %s" % (type(e).__name__, e), True)
    if mid is None:
        return None  # notification (e.g. notifications/initialized)
    raise LookupError(method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        mid = msg.get("id")
        try:
            result = handle(msg)
            if mid is None:
                continue
            resp = {"jsonrpc": "2.0", "id": mid, "result": result}
        except LookupError as e:
            resp = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % e}}
        except Exception as e:  # never let one bad call kill the server
            resp = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
    SESSION.stop()


if __name__ == "__main__":
    main()
