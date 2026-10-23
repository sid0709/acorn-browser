#!/usr/bin/env python3
"""Drives the running app over its agent socket, with the kit's protocol, and checks the results.

    scripts/build.sh run          # start the app first
    Tests/agent_smoke.py

Exits 0 when every check passed.
"""
import base64
import json
import os
import socket
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOCKET = os.environ.get(
    "ACORN_AGENT_SOCKET",
    str(Path.home() / "Library/Application Support/com.acorn.browser/agent.sock"),
)
OUT = Path(os.environ.get("SMOKE_OUT", "/tmp/acorn-smoke"))
OUT.mkdir(parents=True, exist_ok=True)

failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
    if not ok:
        failures.append(name)


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(60)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 0

    def call(self, **request):
        self.next_id += 1
        request["id"] = self.next_id
        self.sock.sendall(json.dumps(request).encode() + b"\n")
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise RuntimeError("the app closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        reply = json.loads(line)
        assert reply["id"] == self.next_id, reply
        return reply

    def act(self, *actions):
        for i, a in enumerate(actions):
            a.setdefault("id", f"t{self.next_id + 1}a{i + 1}")
        reply = self.call(cmd="act", actions=list(actions))
        assert reply["ok"], reply
        return reply["results"]

    def look(self, name, **extra):
        reply = self.call(cmd="observe", survey=False, **extra)
        assert reply["ok"], reply
        o = reply["observation"]
        data = o["screenshot"].split(",", 1)[1]
        (OUT / f"{name}.jpg").write_bytes(base64.b64decode(data))
        return o


def jpeg_size(path):
    import struct
    data = path.read_bytes()
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i + 5 : i + 9])
            return w, h
        i += 2 + struct.unpack(">H", data[i + 2 : i + 4])[0]
    return None


def main():
    for _ in range(40):
        if os.path.exists(SOCKET):
            break
        time.sleep(0.5)
    c = Client(SOCKET)

    page = (ROOT / "page.html").as_uri()
    check("open", c.call(cmd="open", url=page)["ok"])
    o = c.look("1-open")
    vp = o["viewport"]
    check("title read", o["title"] == "Agent test page", o["title"])
    check("url read", o["url"].startswith("file://"), o["url"])
    size = jpeg_size(OUT / "1-open.jpg")
    check("picture is one pixel to a CSS pixel", size == (round(vp["width"]), round(vp["height"])),
          f"picture {size}, viewport {vp['width']}x{vp['height']}")
    check("page is taller than the viewport", vp["pageHeight"] > vp["height"] * 2, str(vp["pageHeight"]))

    # Find the input and the button from the page, to click where they really are.
    # (The harness would read them from the picture; the test needs a ground truth.)
    # Positions below are for the layout of page.html.
    results = c.act({"kind": "click", "x": 120, "y": 120})
    check("click ok", results[0]["ok"], str(results[0]))
    o = c.look("2-clicked")
    focus = o.get("focus") or {}
    check("click focused the input", focus.get("tag") == "input" and focus.get("label") == "Your name", str(focus))

    results = c.act({"kind": "type", "text": "Ada Lovelace, b. 1815!"})
    check("type ok", results[0]["ok"], str(results[0]))
    o = c.look("3-typed")
    check("typed text arrived", (o.get("focus") or {}).get("value") == "Ada Lovelace, b. 1815!", str(o.get("focus")))

    results = c.act({"kind": "key", "keys": "Enter"})
    check("Enter ok", results[0]["ok"], str(results[0]))

    results = c.act({"kind": "key", "keys": "Meta+a"}, {"kind": "type", "text": "Bob"})
    check("select all then type ok", all(r["ok"] for r in results), str(results))
    o = c.look("4-replaced")
    check("select-all replaced the text", (o.get("focus") or {}).get("value") == "Bob", str(o.get("focus")))

    results = c.act({"kind": "type", "text": "世界"})
    o = c.look("5-unicode")
    check("non-ASCII text inserted", (o.get("focus") or {}).get("value") == "Bob世界", str(o.get("focus")))

    before = c.look("5b-before-scroll")["viewport"]["scrollY"]
    results = c.act({"kind": "scroll", "dx": 0, "dy": 500})
    check("scroll ok", results[0]["ok"], str(results[0]))
    o = c.look("6-scrolled")
    scrolled = o["viewport"]["scrollY"]
    check("scroll moved by what was asked", abs((scrolled - before) - 500) <= 2, f"asked 500, moved {scrolled - before}")

    o = c.call(cmd="observe", survey=True)["observation"]
    check("survey returned several screens", len(o.get("survey", [])) >= 3, str(len(o.get("survey", []))))
    check("survey put the page back", abs(o["viewport"]["scrollY"] - scrolled) < 2, f"{o['viewport']['scrollY']} vs {scrolled}")

    results = c.act({"kind": "bogus"})
    check("unknown action fails cleanly", results[0]["ok"] is False, str(results[0]))

    results = c.act({"kind": "wait", "ms": 50})
    check("wait ok", results[0]["ok"])
    check("close", c.call(cmd="close")["ok"])

    print(f"\nPictures are in {OUT}")
    print("ALL PASSED" if not failures else f"{len(failures)} FAILED: {', '.join(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
