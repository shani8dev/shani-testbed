#!/usr/bin/env python3
"""QMP / qemu-guest-agent client for test-env's `gui` command.

One client instead of the five near-identical inline copies test.sh used to
carry. Stdlib only. Usage:

  qmp_client.py qga-ping   <qga.sock>
  qmp_client.py qga-exec   <qga.sock> <shell-cmd> [timeout-secs]
  qmp_client.py screendump <qmp.sock> <out.ppm>
  qmp_client.py click      <qmp.sock> <x> <y> [left|right|middle]
  qmp_client.py move       <qmp.sock> <x> <y>
  qmp_client.py key        <qmp.sock> <combo>        e.g. ret, ctrl+alt+t
  qmp_client.py type       <qmp.sock> <text>          US layout

Coordinates are real framebuffer pixels: click/move take a fresh screendump
first to learn the current resolution and scale to QMP's 0..32767 absolute
axis, so they stay right even if the guest changes resolution.

Input goes through the guest's emulated USB keyboard/tablet (real HID
events), so it works the same for X11 and Wayland guests.
"""
import base64
import json
import os
import socket
import sys
import tempfile
import time

KEY_ALIASES = {
    "super": "meta_l", "meta": "meta_l", "win": "meta_l",
    "enter": "ret", "return": "ret", "escape": "esc",
    "space": "spc", "del": "delete", "pageup": "pgup", "pagedown": "pgdn",
}
UNSHIFTED = {
    "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    ",": "comma", ".": "dot", "/": "slash", " ": "spc", "\n": "ret", "\t": "tab",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", "|": "backslash",
    ":": "semicolon", '"': "apostrophe", "~": "grave_accent",
    "<": "comma", ">": "dot", "?": "slash",
}


class Channel:
    """Line-delimited JSON over a unix socket (QMP and QGA both speak it)."""

    def __init__(self, path, timeout=30.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""

    def _line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def reply(self):
        # QMP may interleave asynchronous {"event": ...} messages at any time;
        # the old per-command copies read the next line as the reply
        # unconditionally, which misreads an event as the answer.
        while True:
            msg = self._line()
            if "event" not in msg:
                return msg

    def rpc(self, command, arguments=None):
        payload = {"execute": command}
        if arguments is not None:
            payload["arguments"] = arguments
        self.sock.sendall(json.dumps(payload).encode() + b"\n")
        msg = self.reply()
        if "error" in msg:
            raise RuntimeError("%s: %s" % (command, msg["error"]))
        return msg.get("return")


def qmp(path):
    ch = Channel(path)
    ch.reply()                      # greeting
    ch.rpc("qmp_capabilities")      # leave negotiation mode
    return ch


def framebuffer_size(ch):
    fd, probe = tempfile.mkstemp(suffix=".ppm")
    os.close(fd)
    try:
        ch.rpc("screendump", {"filename": probe})
        with open(probe, "rb") as f:
            if f.readline().strip() != b"P6":
                raise RuntimeError("screendump is not a P6 PPM")
            dims = f.readline()
            while dims.startswith(b"#"):
                dims = f.readline()
            w, h = (int(v) for v in dims.split())
        return w, h
    finally:
        try:
            os.remove(probe)
        except OSError:
            pass


def to_abs(ch, x, y):
    w, h = framebuffer_size(ch)
    ax = max(0, min(32767, round(x / w * 32767)))
    ay = max(0, min(32767, round(y / h * 32767)))
    return ax, ay, w, h


def key_event(qcode, down):
    return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}


def cmd_qga_ping(sock):
    ch = Channel(sock, timeout=3)
    ch.rpc("guest-ping")
    return 0


def cmd_qga_exec(sock, cmd, timeout="60"):
    ch = Channel(sock)
    pid = ch.rpc("guest-exec", {"path": "/bin/bash", "arg": ["-c", cmd],
                                "capture-output": True})["pid"]
    deadline = time.time() + float(timeout)
    status = {}
    while time.time() < deadline:
        status = ch.rpc("guest-exec-status", {"pid": pid}) or {}
        if status.get("exited"):
            break
        time.sleep(1)
    if not status.get("exited"):
        print("guest-exec: command did not finish within %ss" % timeout, file=sys.stderr)
        return 1
    out = base64.b64decode(status.get("out-data", "")).decode(errors="replace")
    err = base64.b64decode(status.get("err-data", "")).decode(errors="replace")
    sys.stdout.write(out)
    sys.stderr.write(err)
    return status.get("exitcode") or 0


def cmd_screendump(sock, outfile):
    qmp(sock).rpc("screendump", {"filename": os.path.abspath(outfile)})
    print("screendump OK: %s" % outfile)
    return 0


def cmd_click(sock, x, y, button="left"):
    ch = qmp(sock)
    ax, ay, w, h = to_abs(ch, int(x), int(y))
    ch.rpc("input-send-event", {"events": [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"down": True, "button": button}},
    ]})
    time.sleep(0.08)
    ch.rpc("input-send-event", {"events": [
        {"type": "btn", "data": {"down": False, "button": button}}]})
    print("clicked (%s,%s) -> abs(%d,%d) on %dx%d fb" % (x, y, ax, ay, w, h))
    return 0


def cmd_move(sock, x, y):
    ch = qmp(sock)
    ax, ay, w, h = to_abs(ch, int(x), int(y))
    ch.rpc("input-send-event", {"events": [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ]})
    print("moved -> abs(%d,%d) on %dx%d fb" % (ax, ay, w, h))
    return 0


def cmd_key(sock, combo):
    codes = [KEY_ALIASES.get(p, p) for p in combo.lower().split("+")]
    events = [key_event(q, True) for q in codes]
    events += [key_event(q, False) for q in reversed(codes)]
    qmp(sock).rpc("input-send-event", {"events": events})
    print("sent key combo: %s" % combo)
    return 0


def qcode_for(ch):
    if ch.isalpha() and ch.isascii():
        return ch.lower(), ch.isupper()
    if ch.isdigit():
        return ch, False
    if ch in UNSHIFTED:
        return UNSHIFTED[ch], False
    if ch in SHIFTED:
        return SHIFTED[ch], True
    return None, False


def cmd_type(sock, text):
    ch = qmp(sock)
    typed = 0
    for c in text:
        code, shift = qcode_for(c)
        if code is None:
            print("skipping unmappable character: %r" % c, file=sys.stderr)
            continue
        events = ([key_event("shift", True)] if shift else []) + \
                 [key_event(code, True), key_event(code, False)] + \
                 ([key_event("shift", False)] if shift else [])
        ch.rpc("input-send-event", {"events": events})
        typed += 1
        time.sleep(0.03)
    print("typed %d/%d chars" % (typed, len(text)))
    return 0


COMMANDS = {
    "qga-ping": cmd_qga_ping, "qga-exec": cmd_qga_exec,
    "screendump": cmd_screendump, "click": cmd_click, "move": cmd_move,
    "key": cmd_key, "type": cmd_type,
}

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(COMMANDS[sys.argv[1]](*sys.argv[2:]))
    except (OSError, RuntimeError, ConnectionError, ValueError, TypeError) as e:
        print("%s: %s" % (sys.argv[1], e), file=sys.stderr)
        sys.exit(1)
