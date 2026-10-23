#!/usr/bin/env python3
"""shani-harness MCP server — lets an AI agent drive the ShaniOS test harness.

Two groups of tools:

  * GUI app testing ("computer use" for native apps, like Claude in Chrome
    does for web apps): start an app inside a real ShaniOS slot on a private
    virtual display, then screenshot it, read its accessibility tree, click,
    type, press keys, scroll, drag, wait for windows — and finally get the
    app's stdout and exit code. Backed by `test.sh app --control=...`.
  * Harness commands: status, verify-boot, probe, update-check, upgrade,
    rollback, suite, vmspawn, ... (an allow-list), returning their output.

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
# Every testbed command except `app`, which the app_* tools drive. Keep in sync
# with the dispatcher at the bottom of ../testbed (tests/mcp-parity.sh checks).
CONTAINER_COMMANDS = {"status", "clean", "disk", "ca", "bootstrap", "serve", "verify-boot", "probe",
                      "enter", "desktop", "slot-test", "slot-diff", "upgrade", "rollback",
                      "update-check", "reboot", "cycle", "pacstrap", "suite", "gate", "install",
                      "configure", "iso-install", "web"}
HOST_COMMANDS = {"vmspawn", "qemu", "gui", "iso", "watch"}
# Long-running servers/VMs: harness_start runs them in the background instead.
BACKGROUND_HINT = {"serve", "watch", "qemu", "gui"}


def to_container_path(path):
    """Host path under the repo -> the path the builder container sees."""
    real = os.path.realpath(path) if path else path
    if real and real.startswith(REPO + "/"):
        return CONTAINER_REPO + "/" + real[len(REPO) + 1:]
    return path


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
        self.record = None
        self.lock = threading.Lock()

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, slot, run, local_src=None, size="1280x800", display="virtual", startup_timeout=600,
              local_pkgs=(), extra=()):
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
        for pkg in local_pkgs:
            args.append("--local-pkg=" + pkg)
        args.extend(extra)
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
                if self.record:
                    self.info["record"] = self.record
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
            # No O_CREAT: open(..., "w") adds it, and with fs.protected_fifos=1
            # the kernel refuses an O_CREAT open of a FIFO owned by another user
            # (the container's root) in a sticky world-writable dir -> EACCES.
            fd = os.open(os.path.join(SESSION_DIR, "cmd.fifo"), os.O_WRONLY)
            with os.fdopen(fd, "w") as f:
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
            rec = self.info.get("record")
            if rec and os.path.exists(to_host_path(rec)):
                out["recording"] = to_host_path(rec)
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


def harness_argv(command, args):
    if command in HOST_COMMANDS:
        return [TEST_SH, command] + args
    if command in CONTAINER_COMMANDS:
        return [RUNNER, "build.sh", "test", command] + args
    raise ValueError("command %r is not allowed; allowed: %s"
                     % (command, ", ".join(sorted(CONTAINER_COMMANDS | HOST_COMMANDS))))


JOBS = {}


def job_tail(job, n=60):
    try:
        with open(job["log"]) as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def harness_start(command, args):
    argv = harness_argv(command, args)
    jid = "job%d" % (len(JOBS) + 1)
    logf = os.path.join(DATA_DIR, "mcp-%s-%s.log" % (jid, command))
    env = dict(os.environ, SHANIOS_NO_PULL=os.environ.get("SHANIOS_NO_PULL", "1"))
    proc = subprocess.Popen(argv, cwd=REPO, stdin=subprocess.DEVNULL, stdout=open(logf, "w"),
                            stderr=subprocess.STDOUT, env=env, start_new_session=True)
    JOBS[jid] = {"proc": proc, "log": logf, "command": command, "args": args}
    time.sleep(3)
    rc = proc.poll()
    return text("%s started: %s %s (pid %d, log %s)%s\n%s" % (
        jid, command, " ".join(args), proc.pid, logf,
        "" if rc is None else " - already exited rc=%d" % rc, job_tail(JOBS[jid], 20)), rc not in (None, 0))


def harness_job(jid, stop=False):
    job = JOBS.get(jid)
    if not job:
        return text("no job %r; jobs: %s" % (jid, ", ".join(JOBS) or "none"), True)
    if stop and job["proc"].poll() is None:
        import signal
        os.killpg(job["proc"].pid, signal.SIGTERM)
        try:
            job["proc"].wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(job["proc"].pid, signal.SIGKILL)
    rc = job["proc"].poll()
    state = "running" if rc is None else "exited rc=%d" % rc
    return text("%s (%s %s): %s\n%s" % (jid, job["command"], " ".join(job["args"]), state, job_tail(job)))


def run_harness(command, args, timeout):
    try:
        argv = harness_argv(command, args)
    except ValueError as e:
        return text(str(e), True)
    if command in BACKGROUND_HINT and "--help" not in args:
        return text("%s runs until stopped - use harness_start (then harness_job / harness_stop)" % command, True)
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
     {"slot": {"type": "string", "enum": ["blue", "green"]}, "command": {"type": "string", "description": "shell command run inside the slot, e.g. 'shani-cassini'"},
      "local_src": {"type": "string", "description": "optional --local-src dir, e.g. /opt/shani-deploy/scripts"},
      "local_pkg": {"type": "array", "items": {"type": "string"}, "default": [],
                    "description": "optional --local-pkg names/files overlaid into the slot, e.g. [\"shani-cassini\"] for an app the image does not ship yet"},
      "size": {"type": "string", "default": "1280x800"}, "display": {"type": "string", "enum": ["virtual", "host"], "default": "virtual"},
      "record": {"type": "boolean", "default": False, "description": "record the virtual display (and any voice) to an MP4; app_stop returns its path"},
      "strict": {"type": "boolean", "default": False, "description": "G_DEBUG=fatal-criticals: the first GLib/GTK critical aborts the app"},
      "voice": {"type": "boolean", "default": False, "description": "virtual microphone + speaker, for app_say / app_play / app_expect_heard"},
      "local_src_chronoa": {"type": "string", "description": "optional --local-src-chronoa checkout dir"},
      "repo_pkg": {"type": "array", "items": {"type": "string"}, "default": [], "description": "--repo-pkg: install these packages from the configured repos into the slot"},
      "whisper_model": {"type": "array", "items": {"type": "string"}, "default": []},
      "llm": {"type": "string", "description": "--llm=MODEL for apps that need a local model (Chronoa)"},
      "keyring": {"type": "string", "description": "--keyring mode (default login)"},
      "gsettings": {"type": "array", "items": {"type": "string"}, "default": [], "description": "--gsettings=schema key value entries applied before start"},
      "idle_timeout": {"type": "integer", "default": 1800, "description": "end the session after this many idle seconds"}},
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
    ("app_wait_element", "Wait until an element matching query (see app_find) is on screen.", {"query": {"type": "string"}, "timeout": {"type": "integer", "default": 30}}, ["query"]),
    ("app_expect_absent", "Fail if an element matching query appears at any point within secs.", {"query": {"type": "string"}, "secs": {"type": "integer", "default": 5}}, ["query"]),
    ("app_expect_window", "Fail unless a window whose title matches the regex exists now.", {"title": {"type": "string"}}, ["title"]),
    ("app_expect_gone", "Wait until no window matches the title regex.", {"title": {"type": "string"}, "timeout": {"type": "integer", "default": 30}}, ["title"]),
    ("app_wait_exit", "Wait for the app to exit and report its exit code.", {"timeout": {"type": "integer", "default": 60}}, []),
    ("app_a11y_lint", "Fail if any on-screen control has no accessible name (what a screen reader would announce as just 'button').", {}, []),
    ("app_expect_text", "OCR the display (tesseract) and fail unless the regex is found.", {"regex": {"type": "string"}}, ["regex"]),
    ("app_mask", "Blank a region in every later app_expect_same/app_expect_changed comparison (clock, spinner).", {"x": {"type": "integer"}, "y": {"type": "integer"}, "w": {"type": "integer"}, "h": {"type": "integer"}}, ["x", "y", "w", "h"]),
    ("app_expect_same", "Fail if more than pct % of the display differs from a reference PNG (visual regression).", {"ref": {"type": "string"}, "pct": {"type": "number", "default": 0.5}}, ["ref"]),
    ("app_expect_changed", "Fail unless more than pct % of the display differs from a reference PNG - 'the click did something'.", {"ref": {"type": "string"}, "pct": {"type": "number", "default": 0.5}}, ["ref"]),
    ("app_monkey", "N random clicks on enabled on-screen controls from the accessibility tree; fails if the app exits. The seed is printed so failures replay.", {"n": {"type": "integer", "default": 40}, "seed": {"type": "integer"}}, []),
    ("app_log", "Show the app's stderr so far.", {}, []),
    ("app_expect_clean_log", "Fail if the app's stderr has GLib/GTK/Qt warnings or criticals (optional ignore regex).", {"ignore": {"type": "string"}}, []),
    ("app_voice", "(voice sessions) pick the espeak-ng voice for app_say, e.g. en-us.", {"name": {"type": "string"}}, ["name"]),
    ("app_say", "(voice sessions) speak text into the app's virtual microphone.", {"text": {"type": "string"}}, ["text"]),
    ("app_play", "(voice sessions) play a WAV file into the app's virtual microphone.", {"file": {"type": "string"}}, ["file"]),
    ("app_heard_mark", "(voice sessions) start app_expect_heard afresh from now.", {}, []),
    ("app_expect_heard", "(voice sessions) transcribe what the app played on its virtual speaker and fail unless the regex is heard (or, with negate, fail if it is).", {"regex": {"type": "string"}, "secs": {"type": "integer", "default": 20}, "negate": {"type": "boolean", "default": False}}, ["regex"]),
    ("app_observe", "Numbered view of what the app shows: window title, focused element, selected rows, then '[N] role name' for every usable control. Cheaper than app_tree; pick a control by number with app_click_control.", {}, []),
    ("app_click_control", "Click control [n] as numbered by the last app_observe. The reply says which controls appeared or disappeared.", {"n": {"type": "integer"}}, ["n"]),
    ("app_expect_field", "Fail unless the focused text field's content matches the regex - verifies app_type actually landed (catches dropped keystrokes).", {"regex": {"type": "string"}}, ["regex"]),
    ("app_click_text", "Click visible text found by OCR (word boxes) - for windows with no accessibility tree. nth picks among several matches.", {"text": {"type": "string"}, "nth": {"type": "integer", "default": 1}}, ["text"]),
    ("app_wait_settle", "Wait until the display stops changing for `quiet` seconds (at most `timeout`) - instead of a fixed sleep.", {"quiet": {"type": "number", "default": 0.6}, "timeout": {"type": "number", "default": 10}}, []),
    ("app_sleep", "Pause inside the session (let an animation or async load settle).", {"secs": {"type": "number", "default": 1}}, []),
    ("app_action", "Escape hatch: send any raw lib/app.sh action string (e.g. 'sleep=2'). Prefer the typed tools.", {"action": {"type": "string"}}, ["action"]),
    ("harness_start", "Start a long-running harness command in the background (serve, watch, qemu, gui, or anything slow). Returns a job id.",
     {"command": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}, "default": []}}, ["command"]),
    ("harness_job", "Status and output tail of a background harness job.", {"job": {"type": "string"}}, ["job"]),
    ("harness_stop", "Stop a background harness job (SIGTERM to its process group).", {"job": {"type": "string"}}, ["job"]),
    ("harness_run", "Run a harness command to completion and return exit code + output tail. Any testbed command except app: status, clean, disk, ca, bootstrap, verify-boot, probe, enter, desktop, slot-test, slot-diff, upgrade, rollback, update-check, reboot, cycle, pacstrap, suite, gate, install, configure, iso-install, web (container) and vmspawn, iso (host). Use harness_start for serve, watch, qemu, gui.",
     {"command": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}, "default": []}, "timeout": {"type": "integer", "default": 3600}}, ["command"]),
]


def call(name, a):
    if name == "app_start":
        extra = []
        if a.get("strict"):
            extra.append("--strict")
        if a.get("voice"):
            extra.append("--voice")
        SESSION.record = None
        if a.get("record"):
            SESSION.record = "@out/session.mp4"
            extra.append("--record=" + SESSION.record)
        for key, flag in (("local_src_chronoa", "--local-src-chronoa="), ("llm", "--llm="), ("keyring", "--keyring=")):
            if a.get(key):
                extra.append(flag + a[key])
        for key, flag in (("repo_pkg", "--repo-pkg="), ("whisper_model", "--whisper-model="), ("gsettings", "--gsettings=")):
            extra.extend(flag + v for v in a.get(key) or ())
        extra.append("--idle-timeout=%d" % int(a.get("idle_timeout", 1800)))
        info = SESSION.start(a["slot"], a["command"], a.get("local_src"), a.get("size", "1280x800"), a.get("display", "virtual"),
                             local_pkgs=a.get("local_pkg") or (), extra=extra)
        if SESSION.record and info.get("out_dir"):
            info["record"] = info["out_dir"] + "/session.mp4"
            SESSION.info["record"] = info["record"]
        return text("app session ready: " + json.dumps(info))
    if name == "app_stop":
        return text(json.dumps(SESSION.stop(), indent=1))
    if name == "harness_run":
        return run_harness(a["command"], list(a.get("args", [])), int(a.get("timeout", 3600)))
    if name == "harness_start":
        return harness_start(a["command"], list(a.get("args", [])))
    if name in ("harness_job", "harness_stop"):
        return harness_job(a["job"], stop=(name == "harness_stop"))
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
        "app_wait_element": lambda: "wait-element=%s:%d" % (a["query"], int(a.get("timeout", 30))),
        "app_expect_absent": lambda: "expect-absent=%s:%d" % (a["query"], int(a.get("secs", 5))),
        "app_expect_window": lambda: "expect-window=" + a["title"],
        "app_expect_gone": lambda: "expect-gone=%s:%d" % (a["title"], int(a.get("timeout", 30))),
        "app_wait_exit": lambda: "wait-exit=%d" % int(a.get("timeout", 60)),
        "app_a11y_lint": lambda: "a11y-lint",
        "app_expect_text": lambda: "expect-text=" + a["regex"],
        "app_mask": lambda: "mask=%d,%d,%dx%d" % (a["x"], a["y"], a["w"], a["h"]),
        "app_expect_same": lambda: "expect-same=%s:%s" % (to_container_path(a["ref"]), a.get("pct", 0.5)),
        "app_expect_changed": lambda: "expect-changed=%s:%s" % (to_container_path(a["ref"]), a.get("pct", 0.5)),
        "app_monkey": lambda: "monkey=%d" % int(a.get("n", 40)) + (":%d" % int(a["seed"]) if a.get("seed") is not None else ""),
        "app_log": lambda: "show-log",
        "app_expect_clean_log": lambda: "expect-clean-log" + ("=" + a["ignore"] if a.get("ignore") else ""),
        "app_voice": lambda: "voice=" + a["name"],
        "app_say": lambda: "say=" + a["text"],
        "app_play": lambda: "play=" + to_container_path(a["file"]),
        "app_heard_mark": lambda: "heard-mark",
        "app_expect_heard": lambda: "%s=%s:%d" % ("expect-not-heard" if a.get("negate") else "expect-heard", a["regex"], int(a.get("secs", 20))),
        "app_sleep": lambda: "sleep=%s" % a.get("secs", 1),
        "app_observe": lambda: "observe",
        "app_click_control": lambda: "click-control=%d" % int(a["n"]),
        "app_expect_field": lambda: "expect-field=" + a["regex"],
        "app_click_text": lambda: "click-text=" + a["text"] + ("#%d" % int(a["nth"]) if int(a.get("nth", 1)) != 1 else ""),
        "app_wait_settle": lambda: "wait-settle=%s:%s" % (a.get("quiet", 0.6), a.get("timeout", 10)),
        "app_action": lambda: a["action"],
    }
    if name not in mapping:
        return text("unknown tool %r" % name, True)
    waits = {"app_wait_settle": "timeout", "app_wait_element": "timeout", "app_expect_gone": "timeout", "app_wait_exit": "timeout",
             "app_expect_absent": "secs", "app_expect_heard": "secs"}
    budget = 180 + int(a.get(waits.get(name, ""), 0) or 0) + (600 if name == "app_monkey" else 0)
    return action_result(SESSION.do(mapping[name](), timeout=budget))


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
