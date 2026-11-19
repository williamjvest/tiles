#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["playwright>=1.50", "requests>=2.32", "jsbeautifier>=1.15", "websockets>=13", "msgpack>=1.0"]
# ///
"""Capture a Sony VENICE / VENICE 2 Web Remote fast, then watch it while its controls are exercised.

  venice.py find [--port 80]           look for the camera on this Mac's networks
  venice.py go HOST [-u admin] -p PASS mirror rm.html/rmt.html and every file they load, open both headless, log
                                       every WebSocket frame and request, inventory every control, write report.md
                                       (read-only, about a minute)
  venice.py watch HOST -p PASS [--headed] [--detach]
                                       stay connected and log everything; --headed opens a visible Chrome window
                                       on this Mac for clicking by hand
  venice.py proxy HOST [--detach]      reverse proxy on :8080 that records any browser (the laptop's, a phone's over
                                       Tailscale) driving the camera's page: http://<this Mac>:8080/rm.html
  venice.py ctl click ID|SELECTOR | eval JS | send TEXT | shot NAME | dom NAME | snap NAME | reload | stop
  venice.py note "what just happened"  print what happened since the last note and label that window
  venice.py savona HOST -p PASS [--dump] [--get KEY] [--set KEY=JSON] [--keys NAME] [--listen SECS]
                                       Sony's Savona API directly (VENICE, PXW): ws://HOST/linear, MessagePack-RPC,
                                       the nonce/digest login; --dump lists every property and reads them all
  venice.py raw [WSURL] -p PASS --send TEXT [--send …]
                                       talk to the camera's WebSocket without a browser (Digest, Origin and the
                                       page's cookies handled): proof a native client like Tiles can drive it
  venice.py diff [A [B]]               values that differ (watch start vs now by default): what to put back
  venice.py status | stop | report [DIR]

Captures go to captures/venice/<stamp>-<host>/ (gitignored); captures/venice/current points at the latest.
Nothing here presses a camera control by itself: go only loads pages, ctl acts only when told and refuses anything
that looks like delete, reset or update unless --force. Anything that looks like formatting, erasing or initialising
media is refused outright, --force or not, by ctl, raw and savona alike: Tiles' tools never send one. No reconnect loops: VENICE can crash on rapid
reconnects, so a dropped socket stays dropped until `ctl reload`.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from collections import Counter, defaultdict
from pathlib import Path
from urllib.parse import urldefrag, urljoin, urlsplit

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CAPROOT = Path(os.environ.get("VENICE_CAPTURES") or (REPO / "captures" / "venice"))
CURRENT = CAPROOT / "current"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/141.0.0.0 Safari/537.36")

SEED_PAGES = ["/rm.html", "/rmt.html", "/", "/index.html"]
STATIC_EXT = (".html", ".htm", ".js", ".mjs", ".css", ".json", ".xml", ".svg", ".png", ".jpg", ".jpeg", ".gif",
              ".ico", ".webp", ".woff", ".woff2", ".ttf", ".otf", ".eot", ".txt", ".map")
TEXT_EXT = (".html", ".htm", ".js", ".mjs", ".css", ".json", ".xml", ".svg", ".txt", ".map")
# Never sent, --force or not: formatting, erasing or initializing media (Tiles' rule; CameraCore's MediaSafety).
NEVER = re.compile(r"format|erase|initiali[sz]", re.I)
DANGER = re.compile(r"delete|factory|reset|update|upgrade|firmware|shut ?down|power ?off|reboot|restart|clear all", re.I)
NOISY = re.compile(r"time ?code|timecode|\btc\b|clock|date|battery|volt|level|\bdb|meter|temp|fan|remain|percent|"
                   r"hour|elapsed|tick|heartbeat|ping|pong|seq", re.I)
PROPLIKE = re.compile(r"^[A-Za-z][\w]*(?:\.[\w]+){1,9}$")
IDLIKE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+){1,}$")
FILEISH = re.compile(r"\.(?:js|mjs|css|html?|json|xml|svg|png|jpe?g|gif|ico|webp|woff2?|ttf|otf|eot|txt|map|com|org|"
                     r"net|io|jp)$|^www\.|^\d", re.I)
HTML_REF = re.compile(r"""(?:src|href|data-src|data-href|action|background|data)\s*=\s*["']([^"'<>]+)["']""", re.I)
CSS_REF = re.compile(r"""url\(\s*["']?([^"')]+)["']?\s*\)|@import\s+["']([^"']+)["']""", re.I)
JS_PATH = re.compile(r"""["'`]((?:\.{1,2}/|/)?[\w\-./]+\.(?:js|mjs|json|css|html?|xml|svg|png|jpe?g|gif|ico|webp|"""
                     r"""woff2?|ttf|otf|txt|map))(?:\?[^"'`]*)?["'`]""", re.I)
STR_LIT = re.compile(r'"((?:[^"\\\n]|\\.){2,200})"|\'((?:[^\'\\\n]|\\.){2,200})\'')

# What Tiles needs on a VENICE (docs/venice.md, "What it has to control"), as words to look for in names.
EXPECTED = [
    ("REC", ["Clip.Recorder", "Recorder", "Rec"]), ("Timecode", ["TimeCode", "Timecode"]),
    ("Clip name", ["ClipName", "Clip.Name", "ClipTitle", "Title", "Reel"]),
    ("Media remaining", ["Media", "AXS", "AXSA", "AXSB", "SxS", "SDCard", "RemainingPercent", "RemainTime"]),
    ("AXS slot change", ["Slot", "AXS"]),
    ("Frame rate/S&Q", ["FrameRate", "SlowAndQuick", "ProjectFrameRate", "Imager"]),
    ("Resolution/codec", ["Resolution", "Codec", "Imager", "RecFormat", "VideoFormat", "XOCN", "ProRes"]),
    ("Camera letter", ["CameraID", "CameraId"]), ("Shutter", ["Shutter"]),
    ("EI/base ISO", ["ExposureIndex", "ISO", "Gain"]), ("ND", ["NDFilter", "ND"]),
    ("White balance", ["WhiteBalance", "ColorTemperature", "Tint"]), ("AWB", ["AutoWhite", "AWB"]),
    ("WB presets on camera", ["Preset", "Memory"]), ("Shutter presets on camera", ["ShutterPreset", "Preset"]),
    ("Playback", ["Play", "Stop", "Next", "Prev", "Forward", "Rewind", "Pause", "Clips"]),
    ("Jog", ["Jog", "Shuttle"]), ("Sensor flip", ["Flip", "Invert", "Inversion", "Mirror"]),
    ("Colour bars", ["ColorBar", "Bars", "TestSignal"]),
    ("SDI/monitor status info", ["StatusInfo", "Character", "Overlay", "SDIInfo", "DisplayInfo", "Status"]),
    ("Frame lines", ["FrameLine", "Frameline", "Marker"]), ("User frame lines A/B", ["UserFrame"]),
    ("False colour", ["FalseColor", "FalseColour"]), ("De-squeeze", ["Desqueeze", "DeSqueeze", "Squeeze", "Anamorph"]),
    ("Iris", ["Iris"]), ("Zoom/focus", ["Zoom", "Focus"]), ("Battery", ["Battery"]), ("Audio", ["Audio"]),
    ("Assignable buttons", ["Assign"]), ("Look/LUT/CDL", ["Look", "LUT", "CDL"]),
]
SKAARHOJ = [
    "Camera.Gain.ExposureIndex.Value", "Camera.Gain.ISOValue", "Camera.Shutter.Value", "Camera.Shutter.Mode",
    "Camera.Shutter.Value.DisplayValue", "Camera.NDFilter.Value", "Camera.NDFilter.Mode",
    "Camera.WhiteBalance.ColorTemperature.Value.Venice", "Camera.WhiteBalance.Tint.Value",
    "Camera.WhiteBalance.AutoWhite", "Camera.Iris.Value", "Camera.Iris.SettingMethod",
    "Camera.SlowAndQuickMotion.Enabled", "Camera.SlowAndQuickMotion.FrameRate.Venice", "Clip.Recorder",
    "Clip.Mediabox.TimeCode.Value", "P.Clip.Mediabox.TimeCode.Type", "P.System.Menu.WebInfo.Media.AXSA",
    "P.System.Menu.WebInfo.Media.AXSB", "System.Battery.Active.Remain.Voltage", "System.CameraID",
    "System.CameraID.Color", "Output.Audio.dBLevel",
]

HOOK_JS = r"""
(() => {
  if (window.__vc) return;
  window.__vc = { sockets: [] };
  const Native = window.WebSocket;
  if (!Native) return;
  const Hooked = function (url, protocols) {
    const ws = protocols === undefined ? new Native(url) : new Native(url, protocols);
    try { window.__vc.sockets.push(ws); } catch (e) {}
    return ws;
  };
  Hooked.prototype = Native.prototype;
  ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(k => { try { Object.defineProperty(Hooked, k, { value: Native[k] }); } catch (e) {} });
  window.WebSocket = Hooked;
})();
"""

DOM_JS = r"""
() => {
  const sel = 'button, input, select, textarea, a[href], [onclick], [onchange], [onmousedown], [ontouchstart], [role], [id], [data-id], [data-key], [data-cmd]';
  const out = [];
  for (const el of document.querySelectorAll(sel)) {
    if (out.length >= 6000) break;
    const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
    const o = { tag: el.tagName.toLowerCase(), id: el.id || null,
      cls: typeof el.className === 'string' ? (el.className || null) : null,
      text: (el.innerText || el.value || el.getAttribute('aria-label') || el.title || '').trim().replace(/\s+/g, ' ').slice(0, 80),
      visible: r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none',
      box: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)] };
    const attrs = {};
    for (const a of el.attributes) if (!['id', 'class', 'style'].includes(a.name)) attrs[a.name] = a.value.slice(0, 300);
    if (Object.keys(attrs).length) o.attrs = attrs;
    if (el.tagName === 'SELECT') o.options = [...el.options].map(op => ({ v: op.value, t: op.text, sel: op.selected }));
    if (el.tagName === 'INPUT') Object.assign(o, { type: el.type, value: el.value, min: el.min, max: el.max, step: el.step });
    out.push(o);
  }
  return out;
}
"""

GLOBALS_JS = r"""
() => {
  const f = document.createElement('iframe'); f.style.display = 'none'; document.documentElement.appendChild(f);
  const base = new Set(Object.getOwnPropertyNames(f.contentWindow)); f.remove();
  const safe = (v) => { const seen = new WeakSet(); try { return JSON.stringify(v, (k, x) => {
      if (typeof x === 'function') return '[fn]';
      if (x && typeof x === 'object') { if (seen.has(x)) return '[cycle]'; seen.add(x);
        if (typeof Node !== 'undefined' && x instanceof Node) return '[node]'; if (x === window) return '[window]'; }
      return x; }); } catch (e) { return null; } };
  const out = {};
  for (const k of Object.getOwnPropertyNames(window)) {
    if (base.has(k) || k.startsWith('__vc') || /^on/.test(k)) continue;
    let v; try { v = window[k]; } catch (e) { out[k] = { type: 'unreadable' }; continue; }
    const t = typeof v, e = { type: t };
    if (v && (t === 'object' || t === 'function')) {
      try { e.keys = Object.keys(v).slice(0, 400); } catch (_) {}
      if (t === 'function') e.src = String(v).slice(0, 300);
      if (t === 'object') { const s = safe(v); if (s && s.length <= 1500000) e.json = s; else if (s) e.json_len = s.length; }
    } else e.value = String(v).slice(0, 300);
    out[k] = e;
  }
  return out;
}
"""

MISSING = object()


def halow_mesh() -> tuple[ipaddress.IPv4Network | None, tuple[int, ...]]:
    """The HaLow mesh `find` also sweeps, if there is one: its /16 and its node numbers (node N hands out
    <subnet>.N.100-199). From $HALOW_MESH and $HALOW_MESH_NODES ("10.0.0.0/16", "1,2,3") or scripts/halow-mesh.json
    ({"subnet": "10.0.0.0/16", "nodes": [1, 2, 3]}); neither, no mesh sweep."""
    f = REPO / "scripts" / "halow-mesh.json"
    cfg = json.loads(f.read_text()) if f.exists() else {}
    subnet = os.environ.get("HALOW_MESH") or cfg.get("subnet")
    nodes = os.environ.get("HALOW_MESH_NODES")
    return (ipaddress.ip_network(subnet) if subnet else None,
            tuple(int(n) for n in nodes.split(",")) if nodes else tuple(cfg.get("nodes", ())))


MESH, MESH_NODES = halow_mesh()


# ---------------------------------------------------------------------------------------------------------- helpers

def now_s(t: float) -> str:
    return dt.datetime.fromtimestamp(t).strftime("%H:%M:%S.") + f"{int((t % 1) * 10)}"


def base_url(host: str, https: bool = False) -> str:
    if "://" in host:
        u = urlsplit(host)
        return f"{u.scheme}://{u.netloc}"
    return f"{'https' if https else 'http'}://{host.rstrip('/')}"


def set_current(d: Path) -> None:
    CAPROOT.mkdir(parents=True, exist_ok=True)
    tmp = CAPROOT / ".current.tmp"
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(d.name)
    os.replace(tmp, CURRENT)


def new_session(host: str) -> Path:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    d = CAPROOT / f"{stamp}-{re.sub(r'[^A-Za-z0-9.-]+', '_', host)}"
    d.mkdir(parents=True, exist_ok=False)
    set_current(d)
    return d


def session_dir(arg: str | None = None) -> Path:
    if arg:
        return Path(arg).expanduser().resolve()
    if not CURRENT.exists():
        sys.exit("no capture yet: run `venice.py go HOST` first")
    return CURRENT.resolve()


def read_json(p: Path, default=None):
    try:
        return json.loads(p.read_text())
    except Exception:
        return default


def load_events(sess: Path) -> list[dict]:
    out = []
    p = sess / "events.jsonl"
    if not p.exists():
        return out
    with open(p, encoding="utf-8") as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def append_event(sess: Path, rec: dict) -> None:
    with open(sess / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def jsonable(x):
    if isinstance(x, (bytes, bytearray)):
        return {"bytes": bytes(x).hex()}
    if isinstance(x, dict):
        return {str(k): jsonable(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [jsonable(v) for v in x]
    if hasattr(x, "code") and hasattr(x, "data"):  # msgpack ExtType
        return {"ext": x.code, "data": bytes(x.data).hex()}
    return x


def mp_decode(b: bytes):
    """A binary frame as MessagePack (Sony's Savona API), or None."""
    try:
        import msgpack
        return jsonable(msgpack.unpackb(b, raw=False, strict_map_key=False))
    except Exception:
        return None


class MpStream:
    """Savona's frames aren't one message each: VENICE 2 (savona-2.9.4) packs several MessagePack
    messages into one WebSocket frame and can split one across two. feed() returns each complete message's bytes; a
    split tail waits for the next frame. Text, and anything that isn't MessagePack, passes through whole."""

    def __init__(self):
        self.buf = b""

    def feed(self, p):
        if not isinstance(p, (bytes, bytearray)):
            return [p]
        try:
            import msgpack
        except Exception:
            return [bytes(p)]
        data = self.buf + bytes(p)
        self.buf = b""
        out, pos = [], 0
        u = msgpack.Unpacker(raw=False, strict_map_key=False)
        u.feed(data)
        try:
            for _ in u:
                end = u.tell()
                out.append(data[pos:end])
                pos = end
        except Exception:
            out.append(data[pos:])  # not MessagePack: the rest goes through as it is
            return out
        if pos < len(data):
            rest = data[pos:]
            if len(rest) < (1 << 20):
                self.buf = rest  # a message split across frames: the next frame finishes it
            else:
                out.append(rest)
        return out


def enc_payload(p) -> dict:
    if isinstance(p, (bytes, bytearray)):
        b = bytes(p)
        rec = {"bin": True, "len": len(b), "b64": base64.b64encode(b).decode(), "hex": b[:64].hex()}
        mp = mp_decode(b)
        if mp is not None:
            rec["mp"] = mp
        return rec
    return {"bin": False, "len": len(p), "text": p}


def savona_view(mp) -> dict | None:
    """MessagePack-RPC as Savona uses it: [0,id,method,params] request, [1,id,error,result] response,
    [2,name,data] notification."""
    if not isinstance(mp, list) or not mp or mp[0] not in (0, 1, 2):
        return None
    if mp[0] == 0 and len(mp) == 4 and isinstance(mp[2], str):
        return {"kind": "request", "id": mp[1], "method": mp[2], "params": mp[3]}
    if mp[0] == 1 and len(mp) == 4:
        return {"kind": "response", "id": mp[1], "error": mp[2], "result": mp[3]}
    if mp[0] == 2 and len(mp) == 3 and isinstance(mp[1], str):
        return {"kind": "notify", "name": mp[1], "data": mp[2]}
    return None


SAVONA_STATE_METHODS = {"Property.GetValue": "", "Capability.GetValue": "cap:", "Property.GetStatus": "status:"}


def savona_shape(sv: dict) -> str:
    if sv["kind"] == "notify":
        d = sv["data"]
        return f"notify {sv['name']}" + ("" if isinstance(d, list) and d and isinstance(d[0], dict) else
                                         " " + re.sub(r"\d+", "#", json.dumps(d)[:60]))
    return f"{sv['kind']} {sv.get('method', '')}".strip()


def short(v, n: int = 120) -> str:
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, default=str)
    return s if len(s) <= n else s[: n - 1] + "…"


def mirror_path(root: Path, url: str) -> Path:
    u = urlsplit(url)
    p = u.path or "/"
    if p.endswith("/"):
        p += "index.html"
    parts = [x for x in p.split("/") if x not in ("", ".", "..")]
    rel = Path(*parts) if parts else Path("index.html")
    if u.query:
        rel = rel.with_name(f"{rel.stem}__q{hashlib.sha1(u.query.encode()).hexdigest()[:8]}{rel.suffix}")
    return root / rel


# --------------------------------------------------------------------------------------------- state from frames

NAME_KEYS = ("name", "Name", "NAME", "key", "Key", "property", "Property", "prop", "Prop", "id", "Id", "ID", "path",
             "Path")
ENVELOPE = {"type", "Type", "cmd", "command", "method", "event", "Event", "result", "status", "msg", "kind", "op",
            "seq", "id", "Id", "jsonrpc", "reqid", "requestId", "error", "code", "topic"}
VALUE_KEYS = ("value", "Value", "VALUE", "val", "Val", "current", "Current", "data", "Data")


def parse_payload(text: str):
    try:
        return json.loads(text)
    except Exception:
        pass
    if "=" in text and "\n" not in text.strip() and "&" in text:
        return dict(x.split("=", 1) for x in text.split("&") if "=" in x)
    return None


def flatten(obj, prefix: str = "", out: dict | None = None) -> dict:
    """Flatten a frame into name -> value. {name: X, value: Y} records become X = Y wherever they sit."""
    if out is None:
        out = {}
    if isinstance(obj, dict):
        nk = next((k for k in NAME_KEYS if isinstance(obj.get(k), str) and obj.get(k)), None)
        vk = next((k for k in VALUE_KEYS if k in obj), None) if nk else None
        if nk and vk:
            b = obj[nk]  # a {name, value} record names a property: it's global wherever it sits
            v = obj[vk]
            if isinstance(v, (dict, list)):
                flatten(v, b + ".", out)
            else:
                out[b] = v
            for k, sub in obj.items():
                if k in (nk, vk):
                    continue
                if isinstance(sub, (dict, list)):
                    flatten(sub, f"{b}.{k}.", out)
                else:
                    out[f"{b}.{k}"] = sub
            return out
        for k, sub in obj.items():
            key = str(k) if PROPLIKE.match(str(k)) else prefix + str(k)
            if not prefix and k in ENVELOPE and not isinstance(sub, (dict, list)):
                key = "_env." + str(k)  # message type, command, sequence: not camera state
            if isinstance(sub, (dict, list)):
                flatten(sub, key + ".", out)
            else:
                out[key] = sub
        return out
    if isinstance(obj, list):
        if all(not isinstance(x, (dict, list)) for x in obj):
            out[prefix.rstrip(".") or "_list"] = json.dumps(obj, ensure_ascii=False)
            return out
        for i, sub in enumerate(obj):
            if isinstance(sub, dict) and any(isinstance(sub.get(k), str) for k in NAME_KEYS):
                flatten(sub, prefix, out)
            elif isinstance(sub, (dict, list)):
                flatten(sub, f"{prefix}{i}.", out)
            else:
                out[f"{prefix}{i}"] = sub
        return out
    out[prefix.rstrip(".") or "_value"] = obj
    return out


def shape(text: str) -> str:
    return re.sub(r"\d+", "#", text[:200])


class State:
    def __init__(self):
        self.v: dict = {}
        self.counts: Counter = Counter()
        self.shapes: Counter = Counter()
        self.pending: dict = {}

    def feed(self, payload) -> tuple[list, str | None]:
        """Returns (changes, raw) — raw is the text when the frame isn't parseable."""
        if not isinstance(payload, str):
            return [], None
        obj = parse_payload(payload)
        if obj is None:
            self.shapes[shape(payload)] += 1
            return [], payload
        return self.feed_obj(obj), None

    def feed_obj(self, obj, prefix: str = "") -> list:
        ch = []
        for k, val in flatten(obj).items():
            k = prefix + k
            old = self.v.get(k, MISSING)
            if old != val:
                ch.append((k, None if old is MISSING else old, val))
                self.v[k] = val
                self.counts[k] += 1
        return ch

    def sent(self, rec: dict) -> dict | None:
        """Remember what a request asked, so its response can be read as state."""
        sv = savona_view(rec.get("mp")) if rec.get("bin") else None
        if sv and sv["kind"] == "request":
            self.pending[sv["id"]] = sv["method"]
        return sv

    def feed_rec(self, rec: dict) -> tuple[list, str | None, dict | None]:
        """A received frame, text or MessagePack → (value changes, unparsed text, Savona message)."""
        if not rec.get("bin"):
            ch, raw = self.feed(rec.get("text", ""))
            return ch, raw, None
        mp = rec.get("mp")
        sv = savona_view(mp) if mp is not None else None
        if mp is None:
            return [], None, None
        if sv is None:
            return (self.feed_obj(mp) if isinstance(mp, (dict, list)) else []), None, None
        ch: list = []
        if sv["kind"] == "notify":
            d = sv["data"]
            body = d[0] if isinstance(d, list) and d and isinstance(d[0], dict) else None
            if body is not None:
                n = sv["name"]
                ch = self.feed_obj(body, "cap:" if ".Capability." in n else "status:" if ".Status." in n else
                                   "error:" if "Error" in n else "")
        elif sv["kind"] == "response":
            method = self.pending.pop(sv["id"], None)
            sv["method"] = method
            if method in SAVONA_STATE_METHODS and isinstance(sv["result"], dict) and not sv["error"]:
                ch = self.feed_obj(sv["result"], SAVONA_STATE_METHODS[method])
        if not ch:
            self.shapes[savona_shape(sv)] += 1
        return ch, None, sv


# ------------------------------------------------------------------------------------------------------------ find

def local_ifaces() -> list[tuple[str, ipaddress.IPv4Interface]]:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    res, name = [], None
    for line in out.splitlines():
        m = re.match(r"^([\w.]+): flags=", line)
        if m:
            name = m.group(1)
            continue
        m = re.search(r"\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-f]+)", line)
        if m and name:
            prefix = bin(int(m.group(2), 16)).count("1")
            res.append((name, ipaddress.IPv4Interface(f"{m.group(1)}/{prefix}")))
    skip = ("lo", "utun", "gif", "stf", "awdl", "llw", "anpi", "ap")
    return [r for r in res if not r[0].startswith(skip)]


def arp_table() -> list[tuple[str, str, str]]:
    out = subprocess.run(["arp", "-an"], capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines():
        m = re.search(r"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-f:]+|\(incomplete\)) on (\w+)", line)
        if m and m.group(2) != "(incomplete)" and not m.group(1).endswith(".255"):
            res.append((m.group(1), m.group(2), m.group(3)))
    return res


def dhcp_leases() -> list[dict]:
    p = Path("/private/var/db/dhcpd_leases")
    try:
        text = p.read_text()
    except Exception:
        return []
    res = []
    for block in re.findall(r"\{(.*?)\}", text, re.S):
        d = dict(re.findall(r"(\w+)=(.*)", block))
        if "ip_address" in d:
            res.append(d)
    return res


def mdns_http(secs: float = 2.5) -> list[str]:
    try:
        p = subprocess.Popen(["dns-sd", "-B", "_http._tcp", "local."], stdout=subprocess.PIPE, text=True)
    except Exception:
        return []
    time.sleep(secs)
    p.terminate()
    out = p.communicate(timeout=3)[0]
    return sorted({ln.split("_http._tcp.", 1)[1].strip() for ln in out.splitlines() if " Add " in ln and "_http._tcp." in ln})


async def sweep(ips: list[str], port: int, conc: int = 256, timeout: float = 0.6) -> list[str]:
    sem, found = asyncio.Semaphore(conc), []

    async def one(ip):
        async with sem:
            try:
                _, w = await asyncio.wait_for(asyncio.open_connection(ip, port), timeout)
                w.close()
                found.append(ip)
            except Exception:
                pass

    await asyncio.gather(*(one(ip) for ip in ips))
    return found


def fingerprint(ip: str, port: int) -> dict:
    import requests
    host = ip if port == 80 else f"{ip}:{port}"
    fp = {"ip": ip, "port": port, "score": 1}
    try:
        r = requests.get(f"http://{host}/rm.html", timeout=2.5, allow_redirects=False, headers={"User-Agent": UA})
        fp["rm"] = r.status_code
        fp["auth"] = r.headers.get("WWW-Authenticate", "")[:80]
        fp["server"] = r.headers.get("Server", "")
        if r.status_code in (200, 401):
            fp["score"] += 2
        if r.status_code == 401 and "digest" in fp["auth"].lower():
            fp["score"] += 2
    except Exception as e:
        fp["error"] = type(e).__name__
    try:
        r = requests.get(f"http://{host}/", timeout=2.5, headers={"User-Agent": UA})
        m = re.search(r"<title[^>]*>(.*?)</title>", r.text[:4000], re.S | re.I)
        fp["title"] = (m.group(1).strip()[:60] if m else "")
    except Exception:
        pass
    blob = " ".join(str(fp.get(k, "")) for k in ("auth", "server", "title")).lower()
    if any(w in blob for w in ("sony", "venice", "cinealta", "mpc-3", "fx9", "pxw")):
        fp["score"] += 3
    return fp


def sweep_targets(ifs) -> set[str]:
    """Each interface's /24; on a bigger network also the network's first /24 (on a HaLow mesh a Mac sits at
    <subnet>.N.x/16 while cameras may sit in its first /24)."""
    out: set[str] = set()
    for _, ifc in ifs:
        net = ifc.network
        if net.is_link_local:
            continue
        nets = [net]
        if net.prefixlen < 22:
            nets = [ipaddress.ip_network(f"{ifc.ip}/24", strict=False),
                    ipaddress.ip_network(f"{net.network_address}/24", strict=False)]
        for n in nets:
            out.update(str(h) for h in n.hosts() if h != ifc.ip)
        if MESH and ifc.ip in MESH:  # each node N hands out <subnet>.N.100-199
            a, b = str(MESH.network_address).split(".")[:2]
            for node in MESH_NODES:
                out.update(f"{a}.{b}.{node}.{h}" for h in range(100, 200))
    out.difference_update(str(i.ip) for _, i in ifs)
    return out


def find_cameras(port: int = 80, quiet: bool = False) -> list[dict]:
    t0 = time.time()
    ifs = local_ifaces()
    seeds: dict[str, set] = defaultdict(set)
    for ip, mac, ifc in arp_table():
        seeds[ip].add(f"arp {ifc} {mac}")
    for lease in dhcp_leases():
        seeds[lease["ip_address"]].add(f"lease {lease.get('name', '')} {lease.get('hw_address', '')}".strip())
    targets = set(seeds) | sweep_targets(ifs)
    names = mdns_http() if not quiet else []
    open_ = asyncio.run(sweep(sorted(targets), port))
    fps = sorted((fingerprint(ip, port) for ip in open_), key=lambda f: -f["score"])
    for f in fps:
        f["seen"] = sorted(seeds.get(f["ip"], []))
    if not quiet:
        print("interfaces: " + ", ".join(f"{n} {i}" for n, i in ifs))
        if names:
            print("bonjour http: " + ", ".join(names))
        print(f"swept {len(targets)} addresses for port {port} in {time.time() - t0:.1f}s")
        if not fps:
            print("nothing answering. Check the cable, Technical > Network Setting = LAN, and Info > System > IP Address.")
        for f in fps:
            print(f"  {f['ip']:<15} score {f['score']}  rm.html {f.get('rm', '-')}  {f.get('auth', '')}  "
                  f"{f.get('server', '')}  {f.get('title', '')}  {' '.join(f['seen'])}".rstrip())
    return fps


# ------------------------------------------------------------------------------------------------------------ grab

def make_http(base: str, user: str, pw: str | None):
    import requests
    import urllib3
    from requests.auth import HTTPBasicAuth, HTTPDigestAuth
    urllib3.disable_warnings()
    s = requests.Session()
    s.headers["User-Agent"] = UA
    s.verify = False
    info: dict = {}
    r = s.get(base + "/rm.html", timeout=10, allow_redirects=False)
    info.update(status=r.status_code, challenge=r.headers.get("WWW-Authenticate", ""), server=r.headers.get("Server", ""))
    if r.status_code == 401:
        if not pw:
            info["auth"] = "needed"
            return s, info
        s.auth = (HTTPBasicAuth if info["challenge"].lower().startswith("basic") else HTTPDigestAuth)(user, pw)
        r = s.get(base + "/rm.html", timeout=10, allow_redirects=False)
        info["auth"] = "rejected" if r.status_code == 401 else "ok"
        info["status_after"] = r.status_code
    else:
        info["auth"] = "none asked"
    return s, info


def extract_refs(text: str, ext: str, doc_url: str, base: str) -> set[str]:
    refs = set()
    is_html = ext in (".html", ".htm", "") or "<html" in text[:3000].lower()
    if is_html:
        for m in HTML_REF.finditer(text):
            refs.add(urljoin(doc_url, m.group(1).strip()))
    if is_html or ext == ".css":
        for m in CSS_REF.finditer(text):
            refs.add(urljoin(doc_url, (m.group(1) or m.group(2) or "").strip()))
    if ext in (".js", ".mjs", ".json", ".html", ".htm", ""):
        for m in JS_PATH.finditer(text):
            p = m.group(1)
            refs.add(urljoin(base + "/", p) if not p.startswith(("./", "../")) else urljoin(doc_url, p))
            refs.add(urljoin(doc_url, p))
    return {urldefrag(r)[0] for r in refs if r and not r.startswith(("data:", "javascript:", "mailto:", "about:"))}


def grab(sess: Path, base: str, s, extra=(), max_files: int = 600) -> dict:
    mirror = sess / "mirror"
    mirror.mkdir(exist_ok=True)
    netloc = urlsplit(base).netloc
    queue = [urljoin(base + "/", p.lstrip("/")) for p in [*SEED_PAGES, *extra]]
    seen, skipped = set(), []
    fetched = total = ok = 0
    t0 = time.time()
    with open(mirror / "_index.jsonl", "a") as idx:
        while queue and fetched < max_files:
            url = queue.pop(0)
            u = urlsplit(url)
            key = u.path + ("?" + u.query if u.query else "")
            if key in seen or u.netloc != netloc:
                continue
            seen.add(key)
            ext = os.path.splitext(u.path)[1].lower()
            if not (u.path in ("", "/") or u.path.endswith("/") or ext in STATIC_EXT):
                skipped.append(key)
                continue
            t1 = time.time()
            try:
                r = s.get(url, timeout=45)
            except Exception as e:
                idx.write(json.dumps({"url": url, "error": str(e)[:200]}) + "\n")
                continue
            fetched += 1
            body = r.content
            rec = {"url": url, "final": r.url, "status": r.status_code, "len": len(body),
                   "type": r.headers.get("Content-Type"), "headers": dict(r.headers), "ms": int((time.time() - t1) * 1000)}
            if r.status_code == 200:
                ok += 1
                total += len(body)
                dest = mirror_path(mirror, url)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(body)
                rec["file"] = str(dest.relative_to(sess))
                ctype = (r.headers.get("Content-Type") or "").lower()
                if ext in TEXT_EXT or ext == "" or "text" in ctype or "javascript" in ctype or "json" in ctype:
                    text = body.decode("utf-8", "replace")
                    for ref in sorted(extract_refs(text, ext or ".html", r.url, base)):
                        ru = urlsplit(ref)
                        if ru.netloc == netloc and (ru.path + ("?" + ru.query if ru.query else "")) not in seen:
                            queue.append(ref)
            idx.write(json.dumps(rec) + "\n")
    return {"fetched": fetched, "ok": ok, "bytes": total, "secs": round(time.time() - t0, 1),
            "skipped": skipped[:200], "capped": bool(queue)}


# ------------------------------------------------------------------------------------------------- live capture

class Log:
    def __init__(self, path: Path, run: str):
        self.f = open(path, "a", buffering=1, encoding="utf-8")
        self.run = run

    def __call__(self, type_: str, **kw) -> dict:
        rec = {"t": round(time.time(), 4), "run": self.run, **kw, "type": type_}  # type last: nothing overrides it
        self.f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
        return rec


async def launch(pw_, headless: bool):
    if not headless and subprocess.run(["launchctl", "managername"], capture_output=True, text=True).stdout.strip() \
            != "Aqua":
        raise SystemExit("--headed needs the Mac's desktop session (run it from Terminal on that Mac, not over SSH); "
                         "over SSH use `proxy` and a browser instead")
    errs = []
    for kw in ({"channel": "chrome"}, {}):
        try:
            return await asyncio.wait_for(pw_.chromium.launch(headless=headless, **kw), timeout=60)
        except Exception as e:
            errs.append(f"{kw.get('channel', 'bundled chromium')}: {str(e).splitlines()[0][:160]}")
    raise SystemExit("can't start Chrome: " + " | ".join(errs))


class Capture:
    def __init__(self, sess: Path, base: str, user: str, pw: str | None, run: str, headless=True, har=False):
        self.sess, self.base, self.user, self.pw, self.run = sess, base, user, pw, run
        self.headless, self.har = headless, har
        self.log = Log(sess / "events.jsonl", run)
        self.state = State()
        self.ws_open = self.recv = self.sent = 0
        self.tasks: set = set()
        (sess / "runtime").mkdir(exist_ok=True)
        (sess / "shots").mkdir(exist_ok=True)

    def spawn(self, coro):
        t = asyncio.ensure_future(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)

    async def start(self, pw_, path: str):
        self.browser = await launch(pw_, self.headless)
        kw: dict = {"ignore_https_errors": True}
        if self.pw:
            kw["http_credentials"] = {"username": self.user, "password": self.pw}
        if self.headless:
            kw["viewport"] = {"width": 1280, "height": 900}
        else:
            kw["no_viewport"] = True
        if self.har:
            kw.update(record_har_path=str(self.sess / f"{self.run.replace(':', '_').replace('/', '')}.har"),
                      record_har_content="embed")
        self.ctx = await self.browser.new_context(**kw)
        await self.ctx.add_init_script(HOOK_JS)
        self.ctx.on("request", self.on_request)
        self.ctx.on("response", lambda r: self.spawn(self.on_response(r)))
        self.ctx.on("requestfailed", lambda r: self.log("http_fail", url=r.url, error=r.failure))
        self.page = await self.ctx.new_page()
        self.wire(self.page)
        try:
            self.cdp = await self.ctx.new_cdp_session(self.page)
            await self.cdp.send("Network.enable")
            for ev in ("webSocketCreated", "webSocketWillSendHandshakeRequest", "webSocketHandshakeResponseReceived",
                       "webSocketClosed", "webSocketFrameError"):
                self.cdp.on(f"Network.{ev}", lambda p, ev=ev: self.log("cdp", event=ev, params=p))
        except Exception as e:
            self.log("cdp_error", error=str(e)[:300])
        url = self.base + path
        self.log("goto", url=url, headless=self.headless)
        t0 = time.time()
        try:
            resp = await self.page.goto(url, wait_until="domcontentloaded", timeout=60000)
            st = resp.status if resp else None
            self.log("loaded", url=url, status=st, ms=int((time.time() - t0) * 1000))
            return st
        except Exception as e:
            self.log("goto_error", url=url, error=str(e)[:500])
            return None

    def wire(self, page):
        page.on("websocket", self.on_ws)
        page.on("console", lambda m: self.log("console", level=m.type, text=m.text[:2000]))
        page.on("pageerror", lambda e: self.log("pageerror", text=str(e)[:2000]))
        page.on("dialog", lambda d: self.spawn(self.on_dialog(d)))
        page.on("popup", lambda p: (self.log("popup", url=p.url), self.wire(p)))
        page.on("framenavigated", lambda f: self.log("navigated", url=f.url) if f == page.main_frame else None)

    async def on_dialog(self, d):
        # A camera page might confirm() before something drastic: always answer no, and log it.
        self.log("dialog", kind=d.type, message=d.message[:500], answered="dismiss")
        try:
            await d.dismiss()
        except Exception:
            pass

    def on_ws(self, ws):
        self.ws_open += 1
        url = ws.url
        self.log("ws_open", url=url)

        out_stream, in_stream = MpStream(), MpStream()

        def sent(p):
            if isinstance(p, dict):
                p = p.get("payload")
            self.sent += 1
            for chunk in out_stream.feed(p):
                rec = enc_payload(chunk)
                self.state.sent(rec)
                self.log("ws_send", url=url, **rec)

        def recv(p):
            if isinstance(p, dict):
                p = p.get("payload")
            self.recv += 1
            for chunk in in_stream.feed(p):
                rec = enc_payload(chunk)
                self.state.feed_rec(rec)
                self.log("ws_recv", url=url, **rec)

        ws.on("framesent", sent)
        ws.on("framereceived", recv)
        ws.on("close", lambda *_: self.log("ws_close", url=url))
        ws.on("socketerror", lambda e: self.log("ws_error", url=url, error=str(e)[:300]))

    def on_request(self, req):
        rec = {"method": req.method, "url": req.url, "rtype": req.resource_type}
        if req.method != "GET" or req.resource_type in ("xhr", "fetch", "eventsource", "other"):
            pd = req.post_data
            if pd:
                rec["post"] = pd[:65536]
            self.spawn(self._req_headers(req, rec))
        else:
            self.log("http_req", **rec)

    async def _req_headers(self, req, rec):
        try:
            rec["headers"] = await req.all_headers()
        except Exception:
            pass
        self.log("http_req", **rec)

    async def on_response(self, resp):
        req = resp.request
        rt = req.resource_type
        rec = {"method": req.method, "url": resp.url, "status": resp.status, "rtype": rt,
               "ctype": resp.headers.get("content-type")}
        if resp.status == 200 and rt in ("document", "script", "stylesheet", "xhr", "fetch", "other", "image", "font",
                                         "manifest"):
            try:
                body = await asyncio.wait_for(resp.body(), timeout=120)
                rec["len"] = len(body)
                dest = mirror_path(self.sess / "runtime", resp.url)
                dest.parent.mkdir(parents=True, exist_ok=True)
                if not dest.exists():
                    dest.write_bytes(body)
                if rt in ("xhr", "fetch", "other") and len(body) <= 65536:
                    rec["body"] = body.decode("utf-8", "replace")
            except Exception as e:
                rec["body_error"] = str(e)[:200]
        self.log("http_resp", **rec)

    async def collect(self, name: str) -> dict:
        out: dict = {}
        p = self.page
        try:
            await p.screenshot(path=str(self.sess / "shots" / f"{name}.png"), full_page=True, timeout=15000)
            out["shot"] = f"shots/{name}.png"
        except Exception as e:
            out["shot_error"] = str(e)[:200]
        try:
            html = await p.content()
            (self.sess / f"rendered-{name}.html").write_text(html)
            out["html"] = len(html)
        except Exception as e:
            out["html_error"] = str(e)[:200]
        controls = 0
        for i, fr in enumerate(p.frames):
            try:
                dom = await fr.evaluate(DOM_JS)
                suffix = "" if i == 0 else f"-frame{i}"
                (self.sess / f"dom-{name}{suffix}.json").write_text(json.dumps(dom, indent=1, ensure_ascii=False))
                controls += len(dom)
            except Exception as e:
                out[f"dom_error{i}"] = str(e)[:200]
        out["controls"] = controls
        try:
            g = await p.evaluate(GLOBALS_JS)
            (self.sess / f"globals-{name}.json").write_text(json.dumps(g, indent=1, ensure_ascii=False))
            out["globals"] = len(g)
        except Exception as e:
            out["globals_error"] = str(e)[:200]
        try:
            (self.sess / "cookies.json").write_text(json.dumps(await self.ctx.cookies(), indent=1))
        except Exception:
            pass
        self.snap(name)
        out["values"] = len(self.state.v)
        self.log("collected", name=name, **out)
        return out

    def snap(self, name: str) -> None:
        (self.sess / f"state-{name}.json").write_text(
            json.dumps(self.state.v, indent=1, ensure_ascii=False, sort_keys=True, default=str))

    async def learn_noise(self, secs: float) -> list[str]:
        """Values that change while nobody touches anything (timecode, meters, battery) get hidden from notes."""
        t0 = time.time()
        self.state.counts.clear()
        self.state.shapes.clear()
        await asyncio.sleep(secs)
        keys = sorted(k for k, n in self.state.counts.items() if n >= 2 or NOISY.search(k))
        shapes = sorted(s for s, n in self.state.shapes.items() if n >= 2)
        (self.sess / "noise.json").write_text(json.dumps(
            {"run": self.run, "window": [t0, time.time()], "keys": keys, "shapes": shapes}, indent=1, ensure_ascii=False))
        self.log("noise", n=len(keys), keys=keys[:300], shapes=len(shapes))
        return keys

    async def exec(self, cmd: dict):
        op, arg, p = cmd.get("op"), cmd.get("arg") or "", self.page
        if op == "click":
            sel = arg if not re.fullmatch(r"[A-Za-z][\w-]*", arg) or arg.lower() in ("button", "input", "select", "a") \
                else f"#{arg}"
            loc = p.locator(sel).first
            info = await loc.evaluate(
                "el => ({id: el.id, tag: el.tagName, text: (el.innerText || el.value || '').trim().slice(0, 80), "
                "aria: el.getAttribute('aria-label'), title: el.title, cls: String(el.className || '')})", timeout=4000)
            blob = " ".join(str(v) for v in info.values() if v)
            if NEVER.search(blob):
                return {"refused": f"never sent ({NEVER.search(blob).group(0)}): {info}"}
            if DANGER.search(blob) and not cmd.get("force"):
                return {"refused": f"looks dangerous ({DANGER.search(blob).group(0)}): {info}; add --force if sure"}
            try:
                await loc.click(timeout=3000)
                how = "click"
            except Exception:
                await loc.evaluate("el => el.click()")
                how = "el.click()"
            return {"clicked": info, "how": how}
        if op == "eval":
            return await p.evaluate(arg)
        if op == "send":
            return await p.evaluate(
                "(msg) => { const s = (window.__vc && window.__vc.sockets || []).filter(x => x.readyState === 1);"
                " if (!s.length) return 'no open socket'; const ws = s[s.length - 1]; ws.send(msg); return ws.url; }", arg)
        if op in ("shot", "dom"):
            return await self.collect(arg or f"{op}-{int(time.time())}")
        if op == "snap":
            self.snap(arg or f"snap-{int(time.time())}")
            return {"values": len(self.state.v)}
        if op == "reload":
            r = await p.reload(wait_until="domcontentloaded", timeout=60000)
            return {"status": r.status if r else None}
        if op == "goto":
            r = await p.goto(self.base + (arg if arg.startswith("/") else "/" + arg), wait_until="domcontentloaded",
                             timeout=60000)
            return {"status": r.status if r else None}
        if op in ("stop", "ping"):
            return "ok"
        return {"error": f"unknown op {op}"}

    async def control_loop(self, deadline: float, stop: asyncio.Event):
        ctl = self.sess / "ctl.jsonl"
        ctl.touch()
        pos = ctl.stat().st_size
        while time.time() < deadline and not stop.is_set():
            await asyncio.sleep(0.2)
            if self.page.is_closed():
                self.log("page_closed")
                return
            size = ctl.stat().st_size
            if size <= pos:
                continue
            with open(ctl, encoding="utf-8") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            for line in chunk.splitlines():
                try:
                    cmd = json.loads(line)
                except Exception:
                    continue
                self.log("ctl", **{k: v for k, v in cmd.items() if k != "t"})
                try:
                    res = await asyncio.wait_for(self.exec(cmd), timeout=30)
                except Exception as e:
                    res = {"error": f"{type(e).__name__}: {str(e)[:400]}"}
                self.log("ctl_result", id=cmd.get("id"), op=cmd.get("op"), result=res)
                if cmd.get("op") == "stop":
                    return
        self.log("watch_end", reason="deadline" if time.time() >= deadline else "signal")

    async def close(self):
        if self.tasks:
            await asyncio.wait(list(self.tasks), timeout=3)
        for closer in (self.ctx.close, self.browser.close):
            try:
                await asyncio.wait_for(closer(), timeout=15)
            except Exception:
                pass


def page_name(path: str) -> str:
    return re.sub(r"\.html?$", "", path.strip("/").replace("/", "_")) or "root"


async def scan_pages(sess: Path, base: str, user: str, pw: str | None, pages: list[str], settle: float,
                     noise: float) -> list[str]:
    from playwright.async_api import async_playwright
    lines = []
    async with async_playwright() as pw_:
        for i, path in enumerate(pages):
            run = f"scan{i + 1}:{path}"
            cap = Capture(sess, base, user, pw, run, headless=True, har=True)
            st = await cap.start(pw_, path)
            if st in (None, 404):
                lines.append(f"{path}: {'no answer' if st is None else '404'}")
                await cap.close()
                continue
            await asyncio.sleep(settle)
            await cap.collect(page_name(path))
            if i == 0 and noise:
                await cap.learn_noise(noise)
            lines.append(f"{path}: HTTP {st}, {cap.ws_open} WebSocket(s), {cap.recv} frames in, {cap.sent} out, "
                         f"{len(cap.state.v)} values")
            await cap.close()
            if i < len(pages) - 1:
                await asyncio.sleep(3)  # no rapid reconnects
    return lines


# ---------------------------------------------------------------------------------------------- reading a session

def noise_of(sess: Path) -> tuple[set, set]:
    n = read_json(sess / "noise.json", {}) or {}
    return set(n.get("keys", [])), set(n.get("shapes", []))


def latest_run(evs: list[dict], prefix: str | None = None) -> str | None:
    runs = [e["run"] for e in evs if e.get("type") in ("goto", "run_start")
            and (prefix is None or e["run"].startswith(prefix))]
    return runs[-1] if runs else None


STATIC_URL = re.compile(r"\.(?:js|mjs|css|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|otf|eot|map|html?)(?:\?|$)", re.I)


def window_lines(sess: Path, since: float, until: float | None = None, raw: bool = False) -> list[str]:
    """What happened between since and until, across every run (watch, proxy, scan): frames sent verbatim, received
    frames as value changes (self-changing values hidden), non-file HTTP calls, and anything alarming."""
    evs = load_events(sess)
    nk, nshapes = noise_of(sess)
    states: dict[str, State] = defaultdict(State)
    runs_in = {e.get("run") for e in evs if e.get("t", 0) >= since and (until is None or e.get("t", 0) <= until)
               and e.get("type") in ("ws_send", "ws_recv", "http_req")}
    tag = (lambda r: f"[{r}] ") if len(runs_in) > 1 else (lambda r: "")
    lines, hidden = [], 0
    for e in evs:
        t = e.get("t", 0)
        inside = t >= since and (until is None or t <= until)
        ty, run = e.get("type"), e.get("run")
        if ty == "ws_send" and not inside:
            states[run].sent(e)
            continue
        if ty == "ws_recv":
            ch, rawtext, sv = states[run].feed_rec(e)
            if not inside:
                continue
            if raw or (e.get("bin") and e.get("mp") is None):
                body = e.get("mp") if e.get("bin") else e.get("text", "")
                lines.append(f"{now_s(t)} {tag(run)}← {short(body if body is not None else 'bin ' + e.get('hex', ''), 300)}")
                continue
            if rawtext is not None:
                if shape(rawtext) in nshapes:
                    hidden += 1
                else:
                    lines.append(f"{now_s(t)} {tag(run)}← {short(rawtext, 300)}")
            if sv and sv["kind"] == "response" and sv["error"]:
                lines.append(f"{now_s(t)} {tag(run)}← ERROR to {sv.get('method') or '#' + str(sv['id'])}: "
                             f"{short(sv['error'], 200)}")
            elif sv and not ch:
                if savona_shape(sv) in nshapes:
                    hidden += 1
                elif sv["kind"] == "notify":
                    lines.append(f"{now_s(t)} {tag(run)}← {sv['name']} {short(sv['data'], 240)}")
                elif sv["kind"] == "response" and sv["result"] is not None:
                    lines.append(f"{now_s(t)} {tag(run)}← reply to {sv.get('method') or '#' + str(sv['id'])}: "
                                 f"{short(sv['result'], 240)}")
                elif sv["kind"] == "request":
                    lines.append(f"{now_s(t)} {tag(run)}← camera asks {sv['method']} {short(sv['params'], 200)}")
            for k, old, new in ch:
                if k.startswith("_env."):
                    continue
                if k in nk:
                    hidden += 1
                else:
                    lines.append(f"{now_s(t)} {tag(run)}← {k}: {short(old, 60)} → {short(new, 80)}")
        elif not inside:
            continue
        elif ty == "ws_send":
            sv = states[run].sent(e)
            if sv:
                body = f"{sv['method']} {json.dumps(sv['params'], ensure_ascii=False)}" if sv["kind"] == "request" \
                    else json.dumps(e.get("mp"), ensure_ascii=False)
            elif e.get("bin"):
                body = json.dumps(e["mp"], ensure_ascii=False) if e.get("mp") is not None else f"bin {e['len']}B {e.get('hex', '')}"
            else:
                body = e.get("text")
            lines.append(f"{now_s(t)} {tag(run)}→ {short(body, 600)}")
        elif ty == "http_req" and not STATIC_URL.search(e.get("url", "")):
            lines.append(f"{now_s(t)} {tag(run)}→ http {e['method']} {e['url']} {short(e.get('post', ''), 300)}".rstrip())
        elif ty == "http_resp" and e.get("body") is not None and not STATIC_URL.search(e.get("url", "")):
            lines.append(f"{now_s(t)} {tag(run)}← http {e['status']} {short(e['body'], 300)}")
        elif ty in ("ws_open", "ws_close", "ws_error", "dialog", "pageerror", "goto_error", "page_closed", "popup",
                    "run_start"):
            lines.append(f"{now_s(t)} {tag(run)}! {ty} "
                         f"{short({k: v for k, v in e.items() if k not in ('t', 'run', 'type')}, 300)}")
        elif ty == "ctl_result":
            lines.append(f"{now_s(t)} · {e.get('op')}: {short(e.get('result'), 300)}")
        elif ty == "note" and t > since:
            lines.append(f"{now_s(t)} === {e.get('label')}")
    if hidden:
        lines.append(f"({hidden} timecode/meter-type changes hidden; --raw shows everything)")
    return lines


def traffic(evs: list[dict]) -> dict[str, dict]:
    """Per run: seconds connected, WebSocket bytes and frames each way, HTTP bytes. The HaLow budget question."""
    out: dict[str, dict] = {}
    for e in evs:
        r = out.setdefault(e.get("run"), {"t0": e.get("t", 0), "t1": e.get("t", 0), "in": 0, "out": 0, "fin": 0,
                                          "fout": 0, "http": 0})
        r["t1"] = e.get("t", r["t1"])
        if e.get("type") == "ws_recv":
            r["in"] += e.get("len", 0)
            r["fin"] += 1
        elif e.get("type") == "ws_send":
            r["out"] += e.get("len", 0)
            r["fout"] += 1
        elif e.get("type") == "http_resp":
            r["http"] += e.get("len", 0) or 0
    for r in out.values():
        r["secs"] = max(r["t1"] - r["t0"], 0.001)
    return out


def traffic_line(r: dict) -> str:
    return (f"{r['secs']:.0f} s: WebSocket in {r['in'] / 1024:.1f} KB ({r['in'] * 8 / r['secs'] / 1000:.1f} kbit/s, "
            f"{r['fin'] / r['secs']:.1f} frames/s), out {r['out'] / 1024:.1f} KB; page files {r['http'] / 1024:.0f} KB")


def live_state(sess: Path, run: str | None = None) -> dict:
    evs = load_events(sess)
    run = run or latest_run(evs)
    st = State()
    for e in evs:
        if e.get("run") != run:
            continue
        if e.get("type") == "ws_send":
            st.sent(e)
        elif e.get("type") == "ws_recv":
            st.feed_rec(e)
    return st.v


# ---------------------------------------------------------------------------------------------------------- report

def text_files(sess: Path) -> dict[str, str]:
    files, hashes = {}, set()
    for root in ("mirror", "runtime"):
        d = sess / root
        if not d.exists():
            continue
        for p in sorted(d.rglob("*")):
            if p.is_file() and p.suffix.lower() in TEXT_EXT + ("",) and not p.name.startswith("_"):
                rel = str(p.relative_to(d))
                if rel in files:
                    continue
                try:
                    data = p.read_bytes()
                except Exception:
                    continue
                h = hashlib.sha1(data).hexdigest()
                if h not in hashes:
                    hashes.add(h)
                    files[rel] = data.decode("utf-8", errors="replace")
    return files


def snippets(text: str, needle: str, width: int = 160, cap: int = 12) -> list[str]:
    out, i = [], 0
    while len(out) < cap:
        i = text.find(needle, i)
        if i < 0:
            break
        out.append(re.sub(r"\s+", " ", text[max(0, i - width): i + width]))
        i += len(needle)
    return out


def matches(key: str, words: list[str]) -> bool:
    toks = set()
    for seg in re.split(r"[._\-\s/]+", key):
        toks.update(t.lower() for t in re.findall(r"[A-Z]+(?=[A-Z][a-z]|\d|$)|[A-Z]?[a-z]+|\d+", seg))
        toks.add(seg.lower())
    for w in words:
        if len(w) >= 6 and w.lower() in key.lower():
            return True
        if w.lower() in toks:
            return True
    return False


def frame_shape(e: dict) -> str:
    """A frame's skeleton: JSON keys (two levels), or text with digits blanked, or 'binary'."""
    if e.get("bin"):
        sv = savona_view(e.get("mp")) if e.get("mp") is not None else None
        if sv:
            return "savona " + savona_shape(sv)
        if e.get("mp") is not None:
            return "msgpack " + type(e["mp"]).__name__
        return f"binary, starts {e.get('hex', '')[:8]}"
    t = e.get("text", "")
    try:
        o = json.loads(t)
    except Exception:
        return "text: " + re.sub(r"\d+", "#", t[:48])

    def sig(x, depth=0):
        if isinstance(x, dict):
            if depth > 2:
                return "{…}"
            return "{" + ",".join(f"{k}:{sig(v, depth + 1)}" if isinstance(v, (dict, list)) else str(k)
                                  for k, v in sorted(x.items())) + "}"
        if isinstance(x, list):
            return "[" + (sig(x[0], depth + 1) if x else "") + "]"
        return type(x).__name__

    return "json " + sig(o)


def shapes(frames: list[dict]) -> list[tuple[str, int, str]]:
    seen: dict[str, list] = {}
    for e in frames:
        k = frame_shape(e)
        if k not in seen:
            seen[k] = [0, e.get("text") or (json.dumps(e["mp"], ensure_ascii=False) if e.get("mp") is not None
                                            else e.get("hex")) or ""]
        seen[k][0] += 1
    return sorted(((k, n, ex) for k, (n, ex) in seen.items()), key=lambda x: -x[1])


def build_report(sess: Path) -> list[str]:
    meta = read_json(sess / "meta.json", {}) or {}
    idx = [json.loads(x) for x in (sess / "mirror" / "_index.jsonl").read_text().splitlines()] \
        if (sess / "mirror" / "_index.jsonl").exists() else []
    evs = load_events(sess)
    files = text_files(sess)
    strings: Counter = Counter()
    where: dict[str, set] = defaultdict(set)
    for rel, text in files.items():
        for m in STR_LIT.finditer(text):
            s = m.group(1) or m.group(2)
            strings[s] += 1
            if len(where[s]) < 4:
                where[s].add(rel)
    props = sorted(s for s in strings if PROPLIKE.match(s) and not FILEISH.search(s))
    props_cap = [s for s in props if re.search(r"[A-Z]", s)]
    ids = sorted(s for s in strings if IDLIKE.match(s))
    api = sorted(s for s in strings if ".cgi" in s or s.startswith(("/api", "/command", "/cgi", "/rest")))
    (sess / "strings.json").write_text(json.dumps(
        {"props": props, "ids": ids, "api": api, "all": strings.most_common()}, indent=0, ensure_ascii=False))

    ws_static = []
    for rel, text in files.items():
        last = -10_000
        for i in sorted(m.start() for m in re.finditer(r"WebSocket\(|wss?://", text))[:40]:
            if i - last > 280:
                ws_static.append(f"{rel}: …{re.sub(r'[ \t\r\n]+', ' ', text[max(0, i - 140): i + 140])}…")
                last = i
    send_static = []
    for rel, text in files.items():
        if rel.endswith((".js", ".mjs", ".html", ".htm")):
            send_static += [f"{rel}: …{s}…" for s in snippets(text, ".send(", 120, 8)]

    ws_urls = sorted({e["url"] for e in evs if e.get("type") == "ws_open"})
    handshakes = [e["params"] for e in evs if e.get("type") == "cdp"
                  and e.get("event") in ("webSocketWillSendHandshakeRequest", "webSocketHandshakeResponseReceived")][:6]
    handshakes += [{k: e.get(k) for k in ("url", "request", "status", "response")}
                   for e in evs if e.get("type") == "ws_handshake"][:2]
    sends = [e for e in evs if e.get("type") == "ws_send"]
    recvs = [e for e in evs if e.get("type") == "ws_recv"]
    calls = [e for e in evs if e.get("type") == "http_req" and not STATIC_URL.search(e.get("url", ""))]
    states = {p.stem[6:]: read_json(p, {}) for p in sorted(sess.glob("state-*.json"))}
    live: dict = {}
    for v in states.values():
        live.update({k: x for k, x in (v or {}).items() if not k.startswith("_env.")})
    nk, _ = noise_of(sess)
    dom = []
    for p in sorted(sess.glob("dom-*.json")):
        for el in read_json(p, []) or []:
            el["_page"] = p.stem[4:]
            dom.append(el)
    dom_ids = sorted({el["id"] for el in dom if el.get("id")})
    universe = sorted(set(live) | set(props) | set(ids) | set(dom_ids))

    L = []
    w = L.append
    w(f"# VENICE capture {sess.name}\n")
    w(f"Host {meta.get('base', '?')}, user {meta.get('user', '?')}, started {meta.get('started', '?')}. "
      f"Login: {meta.get('http', {}).get('auth', '?')} ({meta.get('http', {}).get('challenge', '')[:90]}). "
      f"Server: {meta.get('http', {}).get('server', '')}.\n")
    sent_shapes, recv_shapes = shapes(sends), shapes(recvs)
    w("## Protocol sketch\n")
    w(f"Sent, {len(sent_shapes)} kinds:\n")
    for k, n, ex in sent_shapes[:20]:
        w(f"- ×{n} `{short(k, 160)}` e.g. `{short(ex, 300)}`")
    w(f"\nReceived, {len(recv_shapes)} kinds:\n")
    for k, n, ex in recv_shapes[:20]:
        w(f"- ×{n} `{short(k, 160)}` e.g. `{short(ex, 300)}`")
    w("")
    okfiles = [r for r in idx if r.get("status") == 200]
    w(f"## Files\n\n{len(okfiles)} mirrored ({sum(r.get('len', 0) for r in okfiles) / 1e6:.2f} MB), "
      f"{len(list((sess / 'runtime').rglob('*'))) if (sess / 'runtime').exists() else 0} saved at runtime. "
      f"Skipped (not static, never fetched): {', '.join(meta.get('grab', {}).get('skipped', [])[:30]) or 'none'}.\n")
    for r in okfiles[:80]:
        w(f"- `{urlsplit(r['url']).path}` {r.get('len', 0)} B {r.get('type', '')}")
    w("\n## WebSocket\n")
    w("Opened at runtime: " + (", ".join(f"`{u}`" for u in ws_urls) or "**none**") + "\n")
    for h in handshakes:
        w(f"- handshake: `{short(h, 700)}`")
    w(f"\n{len(sends)} frames sent, {len(recvs)} received. First sent:\n")
    for e in sends[:8]:
        w(f"- `{short(e.get('text') or e.get('hex'), 500)}`")
    w("\nFirst received:\n")
    for e in recvs[:8]:
        w(f"- `{short(e.get('text') or e.get('hex'), 500)}`")
    w("\nIn the scripts:\n")
    for s in ws_static[:20]:
        w(f"- `{short(s, 400)}`")
    for s in send_static[:20]:
        w(f"- `{short(s, 360)}`")
    if calls:
        w("\n## HTTP calls besides files\n")
        for e in calls[:40]:
            w(f"- {e['method']} `{e['url']}` {short(e.get('post', ''), 200)}")
    w("\n## Traffic (what the Web Remote costs on the link)\n")
    for run_, r in traffic(evs).items():
        if r["fin"] or r["http"]:
            w(f"- {run_}: {traffic_line(r)}")
    w(f"\n## Live values ({len(live)}; {len(nk)} change on their own)\n")
    for k in sorted(live)[:1500]:
        w(f"- `{k}` = `{short(live[k], 100)}`{'  (moves by itself)' if k in nk else ''}")
    w(f"\n## Names in the scripts ({len(props_cap)} property-like with capitals, {len(props)} in all; "
      f"{len(ids)} ID-like)\n")
    for s in props_cap[:800]:
        w(f"- `{s}` ×{strings[s]} {'(live)' if s in live else ''} — {', '.join(sorted(where[s]))}")
    w("\nID-like:\n")
    w(", ".join(f"`{s}`" for s in ids[:1500]))
    if api:
        w("\nAPI-looking paths: " + ", ".join(f"`{s}`" for s in api))
    w("\n## Controls on the page\n")
    for el in dom:
        if not (el.get("id") or el.get("options") or el["tag"] in ("button", "input", "select")):
            continue
        extra = ""
        if el.get("options"):
            extra = " options: " + ", ".join(f"{o['t']}={o['v']}" + ("*" if o.get("sel") else "") for o in el["options"][:40])
        if el["tag"] == "input":
            extra += f" {el.get('type')} value={el.get('value')} min={el.get('min')} max={el.get('max')}"
        w(f"- [{el['_page']}] {el['tag']}#{el.get('id') or ''} “{el.get('text', '')}”{'' if el.get('visible') else ' (hidden)'}{extra}")
    w("\n## Tiles coverage\n")
    found_lines, missing = [], []
    for label, words in EXPECTED:
        hits = [k for k in universe if matches(k, words)]
        livehits = [k for k in hits if k in live]
        if hits:
            found_lines.append(label)
            w(f"- **{label}**: " + ", ".join(f"`{k}`" for k in (livehits + [h for h in hits if h not in livehits])[:10])
              + (f" (+{len(hits) - 10})" if len(hits) > 10 else ""))
        else:
            missing.append(label)
            w(f"- **{label}**: not found")
    w("\nSkaarHoj's names: " + ", ".join(
        f"`{n}` {'live' if n in live else 'script' if n in strings else 'absent'}" for n in SKAARHOJ))
    (sess / "report.md").write_text("\n".join(L) + "\n")

    sk_live = sum(1 for n in SKAARHOJ if n in live)
    sk_any = sum(1 for n in SKAARHOJ if n in live or n in strings)
    return [
        f"report: {sess / 'report.md'}",
        f"protocol: {len(sent_shapes)} kinds of frame sent, {len(recv_shapes)} received; most common in: "
        f"{short(recv_shapes[0][0], 120) if recv_shapes else '-'}",
        f"files: {len(okfiles)} mirrored; WebSocket: {', '.join(ws_urls) or 'NONE opened'}; "
        f"{len(sends)} frames out, {len(recvs)} in",
        f"names: {len(live)} live values, {len(props_cap)} property names and {len(ids)} IDs in the scripts, "
        f"{len(dom_ids)} element IDs on the page",
        f"SkaarHoj's {len(SKAARHOJ)} names: {sk_live} live, {sk_any} live or in the scripts",
        f"Tiles controls with a candidate name: {len(found_lines)}/{len(EXPECTED)}; none yet: {', '.join(missing) or '-'}",
    ]


def beautify(sess: Path, budget: float = 90) -> int:
    import jsbeautifier
    t0, n = time.time(), 0
    out = sess / "pretty"
    for root in ("mirror", "runtime"):
        for p in sorted((sess / root).rglob("*.js")) if (sess / root).exists() else []:
            if time.time() - t0 > budget:
                return n
            dest = out / root / p.relative_to(sess / root)
            if dest.exists() or p.stat().st_size > 4_000_000:
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                dest.write_text(jsbeautifier.beautify(p.read_text(encoding="utf-8", errors="replace")))
                n += 1
            except Exception:
                pass
    return n


# -------------------------------------------------------------------------------------------------------- commands

def cmd_find(a) -> int:
    find_cameras(a.port)
    return 0


def pick_host(port: int) -> str:
    fps = find_cameras(port)
    good = [f for f in fps if f["score"] >= 3]
    if len(good) == 1 or (good and good[0]["score"] > good[1]["score"]):
        host = good[0]["ip"] if port == 80 else f"{good[0]['ip']}:{port}"
        print(f"using {host}")
        return host
    sys.exit("no single obvious camera: pass HOST")


def cmd_go(a) -> int:
    host = a.host or pick_host(a.port)
    base = base_url(host, a.https)
    t0 = time.time()
    sess = new_session(urlsplit(base).netloc)
    s, info = make_http(base, a.user, a.password)
    meta = {"base": base, "user": a.user, "started": dt.datetime.now().isoformat(timespec="seconds"), "http": info,
            "tool": "scripts/venice/venice.py"}
    (sess / "meta.json").write_text(json.dumps(meta, indent=1))
    print(f"{base}: rm.html → HTTP {info['status']}, login {info['auth']} {info['challenge'][:70]} {info['server']}")
    if info["auth"] in ("needed", "rejected"):
        print("stopping: the camera wants its login (Technical > Authentication). Retry with -u/-p. "
              "Not guessing passwords: cameras can lock out.")
        return 2
    g = grab(sess, base, s)
    meta["grab"] = g
    (sess / "meta.json").write_text(json.dumps(meta, indent=1))
    print(f"mirrored {g['ok']} files ({g['bytes'] / 1e6:.2f} MB) in {g['secs']}s"
          + (f"; not fetched: {', '.join(g['skipped'][:8])}" if g["skipped"] else ""))
    pages = [p if p.startswith("/") else "/" + p for p in a.pages.split(",")]
    for ln in asyncio.run(scan_pages(sess, base, a.user, a.password, pages, a.settle, a.noise)):
        print(ln)
    for ln in build_report(sess):
        print(ln)
    print(f"done in {time.time() - t0:.0f}s; pretty-printing scripts…")
    print(f"pretty-printed {beautify(sess, a.beautify)} scripts into {sess / 'pretty'}")
    return 0


def keep_awake(pid: int) -> None:
    """Hold the Mac out of idle sleep for as long as pid lives (a sleeping laptop drops the camera mid-capture)."""
    if Path("/usr/bin/caffeinate").exists():
        subprocess.Popen(["/usr/bin/caffeinate", "-i", "-s", "-w", str(pid)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def watch_running(sess: Path, name: str = "watch.pid") -> int | None:
    info = read_json(sess / name)
    if not info:
        return None
    try:
        os.kill(info["pid"], 0)
        return info["pid"]
    except Exception:
        return None


def cmd_watch(a) -> int:
    base = base_url(a.host, a.https)
    if a.session:
        sess = session_dir(a.session)
    elif CURRENT.exists() and not a.new and (read_json(CURRENT / "meta.json", {}) or {}).get("base") == base:
        sess = CURRENT.resolve()
    else:
        sess = new_session(urlsplit(base).netloc)
        (sess / "meta.json").write_text(json.dumps({"base": base, "user": a.user,
                                                    "started": dt.datetime.now().isoformat(timespec="seconds")}))
    pid = watch_running(sess)
    if pid:
        print(f"already watching (pid {pid}) in {sess}")
        return 1
    if a.detach:
        argv = [sys.executable, str(Path(__file__).resolve()), "watch", a.host, "-u", a.user, "--session", str(sess),
                "--minutes", str(a.minutes), "--settle", str(a.settle), "--noise", str(a.noise), "--path", a.path]
        if a.password:
            argv += ["-p", a.password]
        if a.headed:
            argv.append("--headed")
        if a.https:
            argv.append("--https")
        start = time.time()
        with open(sess / "watch.log", "a") as logf:
            proc = subprocess.Popen(argv, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    start_new_session=True)
        print(f"watching in the background (pid {proc.pid}), session {sess}")
        while time.time() - start < a.settle + a.noise + 60:
            time.sleep(0.5)
            if proc.poll() is not None:
                print(f"watch exited with {proc.returncode}; see {sess / 'watch.log'}")
                print((sess / "watch.log").read_text()[-1500:])
                return 1
            evs = [e for e in load_events(sess) if e.get("t", 0) >= start and str(e.get("run", "")).startswith("watch")]
            bad = [e for e in evs if e["type"] == "goto_error"]
            if bad:
                print(f"page didn't load: {bad[-1].get('error', '')[:300]}")
                return 1
            ready = [e for e in evs if e["type"] == "ready"]
            if ready:
                r = ready[-1]
                print(f"ready: {r['ws']} WebSocket(s), {r['recv']} frames in, {r['values']} values; "
                      f"{r.get('noise', 0)} self-changing values hidden from notes. ctl/note/diff now work.")
                return 0
        print("not ready after a minute; it's still running — check `venice.py status`")
        return 0
    (sess / "watch.pid").write_text(json.dumps({"pid": os.getpid(), "started": time.time()}))
    keep_awake(os.getpid())
    try:
        asyncio.run(watch_main(sess, base, a.user, a.password, a.path, not a.headed, a.minutes, a.settle, a.noise))
    finally:
        try:
            (sess / "watch.pid").unlink()
        except Exception:
            pass
    return 0


async def watch_main(sess: Path, base: str, user: str, pw: str | None, path: str, headless: bool, minutes: float,
                     settle: float, noise: float):
    from playwright.async_api import async_playwright
    n = 1 + sum(1 for e in load_events(sess) if e.get("type") == "goto" and str(e.get("run", "")).startswith("watch"))
    run = f"watch{n}"
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    async with async_playwright() as pw_:
        cap = Capture(sess, base, user, pw, run, headless=headless)
        st = await cap.start(pw_, path)
        if st in (None, 401, 404):
            cap.log("goto_error", url=base + path, error=f"HTTP {st}")
            await cap.close()
            return
        await asyncio.sleep(settle)
        await cap.collect(f"{run}-start")
        keys = await cap.learn_noise(noise) if noise else []
        cap.log("ready", ws=cap.ws_open, recv=cap.recv, values=len(cap.state.v), noise=len(keys))
        await cap.control_loop(time.time() + minutes * 60, stop)
        try:
            await cap.collect(f"{run}-end")
        except Exception:
            pass
        await cap.close()


def cmd_ctl(a) -> int:
    sess = session_dir(a.session)
    if not watch_running(sess):
        print("nothing is watching: start `venice.py watch HOST -p … --detach` first")
        return 1
    cid = uuid.uuid4().hex[:8]
    t0 = time.time()
    with open(sess / "ctl.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps({"id": cid, "op": a.op, "arg": " ".join(a.arg) if a.arg else None, "force": a.force,
                            "t": t0}) + "\n")
    res = None
    while time.time() - t0 < a.timeout and res is None:
        time.sleep(0.15)
        for e in reversed(load_events(sess)):
            if e.get("type") == "ctl_result" and e.get("id") == cid:
                res = e
                break
    if res is None:
        print("no answer from watch (still busy, or dead: `venice.py status`)")
        return 1
    print(f"{a.op}: {short(res.get('result'), 2000)}")
    if a.op not in ("stop",) and a.after > 0:
        time.sleep(a.after)
        for ln in window_lines(sess, t0):
            if " · " not in ln:
                print(ln)
    return 0


def cmd_note(a) -> int:
    sess = session_dir(a.session)
    evs = load_events(sess)
    run = latest_run(evs)
    start = next((e["t"] for e in evs if e.get("run") == run and e.get("type") in ("ready", "run_start")), None) \
        or next((e["t"] for e in evs if e.get("run") == run), time.time())
    since = max([start] + [e["t"] for e in evs if e.get("type") == "note" and e["t"] >= start])
    if a.since:
        since = time.time() - a.since
    lines = window_lines(sess, since, raw=a.raw)
    print("\n".join(lines) if lines else "(nothing since the last note)")
    if a.label:
        append_event(sess, {"t": round(time.time(), 4), "run": run, "type": "note", "label": " ".join(a.label),
                            "from": since})
    return 0


def cmd_diff(a) -> int:
    sess = session_dir(a.session)
    evs = load_events(sess)
    run = latest_run(evs, "watch") or latest_run(evs)

    def load(name):
        if name in (None, "now"):
            return live_state(sess, run), f"{run} now"
        p = Path(name) if Path(name).exists() else sess / f"state-{name}.json"
        return read_json(p, {}) or {}, p.stem

    A, an = load(a.a or f"{run}-start")
    B, bn = load(a.b)
    nk, _ = noise_of(sess)
    changed = [k for k in sorted(set(A) | set(B))
               if A.get(k, MISSING) != B.get(k, MISSING) and k not in nk and not k.startswith("_env.")]
    print(f"{an} → {bn}: {len(changed)} differ")
    for k in changed:
        print(f"  {k}: {short(A.get(k, '(absent)'), 60)} → {short(B.get(k, '(absent)'), 60)}")
    return 0


def cmd_status(a) -> int:
    sess = session_dir(a.session)
    evs = load_events(sess)
    run = latest_run(evs)
    pid = watch_running(sess)
    recent = [e for e in evs if e.get("t", 0) > time.time() - 60]
    opened = sum(1 for e in evs if e.get("run") == run and e.get("type") == "ws_open")
    closed = sum(1 for e in evs if e.get("run") == run and e.get("type") == "ws_close")
    last = f"{time.time() - evs[-1]['t']:.0f}s ago" if evs else "never"
    ppid = watch_running(sess, "proxy.pid")
    tr = traffic(evs).get(run)
    if tr:
        print(f"{run} traffic, {traffic_line(tr)}")
    print(f"session {sess}\nrun {run}; watch {'running, pid ' + str(pid) if pid else 'not running'}; "
          f"proxy {'running, pid ' + str(ppid) if ppid else 'not running'}; sockets {opened} opened, {closed} closed "
          f"in that run; {len(recent)} events in the last minute; last event {last}")
    return 0


def stop_session(sess: Path) -> list[str]:
    done = []
    ppid = watch_running(sess, "proxy.pid")
    if ppid:
        os.kill(ppid, signal.SIGTERM)
        for _ in range(50):
            time.sleep(0.2)
            if not watch_running(sess, "proxy.pid"):
                break
        (sess / "proxy.pid").unlink(missing_ok=True)
        done.append(f"proxy stopped ({sess.name})")
    pid = watch_running(sess)
    if pid:
        with open(sess / "ctl.jsonl", "a") as f:
            f.write(json.dumps({"id": uuid.uuid4().hex[:8], "op": "stop", "t": time.time()}) + "\n")
        for _ in range(100):
            time.sleep(0.2)
            if not watch_running(sess):
                break
        else:
            os.kill(pid, signal.SIGTERM)
        done.append(f"watch stopped ({sess.name})")
    return done


def cmd_stop(a) -> int:
    """Stops watch and proxy: in --session, or in every session when none is given."""
    sessions = [session_dir(a.session)] if a.session else sorted(d for d in CAPROOT.glob("2*") if d.is_dir())
    done = [ln for d in sessions for ln in stop_session(d)]
    print("\n".join(done) if done else "nothing running")
    return 0


def cmd_proxy(a) -> int:
    base = base_url(a.host, a.https)
    if a.session:
        sess = session_dir(a.session)
    elif CURRENT.exists() and (read_json(CURRENT / "meta.json", {}) or {}).get("base") == base:
        sess = CURRENT.resolve()
    else:
        sess = new_session(urlsplit(base).netloc)
        (sess / "meta.json").write_text(json.dumps({"base": base, "user": a.user,
                                                    "started": dt.datetime.now().isoformat(timespec="seconds")}))
    if watch_running(sess, "proxy.pid"):
        print(f"proxy already running in {sess}")
        return 1
    mitm = next((p for p in ("/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump") if Path(p).exists()), "mitmdump")
    n = 1 + sum(1 for e in load_events(sess) if e.get("type") == "run_start" and str(e.get("run", "")).startswith("proxy"))
    argv = [mitm, "-q", "--mode", f"reverse:{base}/", "--listen-host", a.listen, "--listen-port", str(a.port),
            "-s", str(HERE / "venice_mitm.py"), "--set", f"venice_session={sess}", "--set", f"venice_upstream={base}",
            "--set", f"venice_run=proxy{n}", "--set", "ssl_insecure=true", "--set", "connection_strategy=lazy"]
    for extra in a.also_port:
        argv += ["--mode", f"reverse:{urlsplit(base).scheme}://{urlsplit(base).hostname}:{extra}/@{extra}"]
    logf = open(sess / "proxy.log", "a")
    proc = subprocess.Popen(argv, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    (sess / "proxy.pid").write_text(json.dumps({"pid": proc.pid, "started": time.time(), "port": a.port}))
    keep_awake(proc.pid)
    time.sleep(2.5)
    if proc.poll() is not None:
        print(f"mitmdump exited {proc.returncode}:\n" + (sess / "proxy.log").read_text()[-1500:])
        return 1
    # Tailscale's address too, if it's installed: a phone on the same tailnet can open the page there.
    ts = subprocess.run(["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "ip", "-4"], capture_output=True,
                        text=True).stdout.strip() if Path("/Applications/Tailscale.app").exists() else ""
    lan = [str(i.ip) for n_, i in local_ifaces() if not i.network.is_link_local]
    hosts = ["localhost"] if a.listen.startswith("127.") else ["localhost", *lan, *([ts] if ts else [])]
    print(f"proxy{n} up (pid {proc.pid}) → {base}; open any of: "
          + ", ".join(f"http://{h}:{a.port}/rm.html" for h in hosts))
    if not a.detach:
        try:
            proc.wait()
        except KeyboardInterrupt:
            proc.terminate()
        (sess / "proxy.pid").unlink(missing_ok=True)
    return 0


def auth_header(challenge: str, method: str, uri: str, user: str, pw: str) -> str:
    """Answer a WWW-Authenticate challenge (Basic, or Digest MD5/SHA-256, with or without qop/-sess)."""
    if challenge.lower().startswith("basic"):
        return "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
    p = {k.lower(): (x or y) for k, x, y in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]*))', challenge.split(" ", 1)[1])}
    algo = p.get("algorithm") or "MD5"
    hf = hashlib.sha256 if algo.upper().startswith("SHA-256") else hashlib.md5

    def H(x: str) -> str:
        return hf(x.encode()).hexdigest()

    realm, nonce, cnonce, nc = p.get("realm", ""), p.get("nonce", ""), os.urandom(8).hex(), "00000001"
    ha1 = H(f"{user}:{realm}:{pw}")
    if algo.upper().endswith("-SESS"):
        ha1 = H(f"{ha1}:{nonce}:{cnonce}")
    ha2 = H(f"{method}:{uri}")
    qops = [q.strip() for q in (p.get("qop") or "").split(",") if q.strip()]
    if qops:
        q = "auth" if "auth" in qops else qops[0]
        hdr = (f'Digest username="{user}", realm="{realm}", nonce="{nonce}", uri="{uri}", algorithm={algo}, '
               f'response="{H(f"{ha1}:{nonce}:{nc}:{cnonce}:{q}:{ha2}")}", qop={q}, nc={nc}, cnonce="{cnonce}"')
    else:
        hdr = (f'Digest username="{user}", realm="{realm}", nonce="{nonce}", uri="{uri}", algorithm={algo}, '
               f'response="{H(f"{ha1}:{nonce}:{ha2}")}"')
    if p.get("opaque"):
        hdr += f', opaque="{p["opaque"]}"'
    return hdr


def cmd_raw(a) -> int:
    """Talk to the camera's WebSocket the way a native app would: no browser, one command at a time."""
    from websockets.exceptions import InvalidStatus
    from websockets.sync.client import connect
    sess = session_dir(a.session) if (a.session or CURRENT.exists()) else None
    evs = load_events(sess) if sess else []
    url = a.url or next((e["url"] for e in evs if e.get("type") == "ws_open"), None)
    if not url:
        sys.exit("no WebSocket URL: pass one, or run go first")
    u = urlsplit(url)
    origin = a.origin or f"{'https' if u.scheme == 'wss' else 'http'}://{u.netloc}"
    headers = {}
    if sess and not a.no_cookies:
        ck = [c for c in (read_json(sess / "cookies.json", []) or []) if c.get("domain", "").lstrip(".") == u.hostname]
        if ck:
            headers["Cookie"] = "; ".join(f"{c['name']}={c['value']}" for c in ck)
    proto = a.protocol
    if not proto:
        for e in evs:
            if e.get("type") == "cdp" and e.get("event") == "webSocketWillSendHandshakeRequest":
                h = {k.lower(): v for k, v in e["params"]["request"]["headers"].items()}
                if h.get("sec-websocket-protocol"):
                    proto = h["sec-websocket-protocol"]
                    break
    subprotocols = [x.strip() for x in proto.split(",")] if proto else None
    path = u.path + ("?" + u.query if u.query else "") or "/"
    n = 1 + sum(1 for e in evs if e.get("type") == "run_start" and str(e.get("run", "")).startswith("raw"))
    log = Log(sess / "events.jsonl", f"raw{n}") if sess else (lambda *x, **k: None)

    def open_ws(extra: dict):
        return connect(url, origin=origin, additional_headers={**headers, **extra}, subprotocols=subprotocols,
                       user_agent_header=UA, open_timeout=30, ping_interval=None, max_size=None)

    t0 = time.time()
    authed = False
    try:
        ws = open_ws({})
    except InvalidStatus as e:
        if e.response.status_code != 401:
            print(f"handshake refused: HTTP {e.response.status_code} {dict(e.response.headers)}")
            return 1
        if not a.password:
            print("the socket wants a login: add -p")
            return 1
        ch = e.response.headers.get("WWW-Authenticate", "")
        try:
            ws = open_ws({"Authorization": auth_header(ch, "GET", path, a.user, a.password)})
        except InvalidStatus as e2:
            print(f"login refused on the socket: HTTP {e2.response.status_code} (challenge was {ch[:120]})")
            return 1
        authed = True
    print(f"connected to {url} in {time.time() - t0:.1f}s without a browser; login {'Digest/Basic' if authed else 'not asked'}"
          f"; subprotocol {ws.subprotocol}; origin {origin}{'; page cookies sent' if 'Cookie' in headers else ''}")
    log("run_start", kind="raw", url=url)
    log("ws_open", url=url)
    st, (nk, nshapes) = State(), (noise_of(sess) if sess else (set(), set()))
    hidden = 0

    def drain(until: float):
        nonlocal hidden
        while True:
            left = until - time.time()
            if left <= 0:
                return
            try:
                m = ws.recv(timeout=left)
            except TimeoutError:
                return
            log("ws_recv", url=url, **enc_payload(m))
            if not isinstance(m, str):
                print(f"{now_s(time.time())} ← bin {len(m)}B {m[:32].hex()}")
                continue
            ch, rawtext = st.feed(m)
            if a.raw or (rawtext is not None and shape(rawtext) not in nshapes):
                print(f"{now_s(time.time())} ← {short(m, 300)}")
                continue
            for k, old, new in ch:
                if k in nk or k.startswith("_env."):
                    hidden += 1
                else:
                    print(f"{now_s(time.time())} ← {k}: {short(old, 50)} → {short(new, 80)}")

    with ws:
        drain(time.time() + a.wait)
        for text in a.send:
            if NEVER.search(text):
                print(f"refused, never sent ({NEVER.search(text).group(0)}): {short(text, 120)}")
                continue
            ws.send(text)
            log("ws_send", url=url, **enc_payload(text))
            print(f"{now_s(time.time())} → {short(text, 300)}")
            drain(time.time() + a.gap)
        drain(time.time() + a.secs)
    log("ws_close", url=url)
    print(f"closed. {len(st.v)} values seen" + (f", {hidden} self-changing ones hidden" if hidden else ""))
    return 0


def savona_cli(a) -> int:
    """Drive the camera's Savona API directly: ws://HOST/linear, MessagePack-RPC, login, one command at a time.
    Tries the nonce/digest login, then Digest on the socket itself, then the older basic-credential one."""
    import msgpack
    import requests as rq
    from websockets.exceptions import InvalidStatus
    from websockets.sync.client import connect
    import urllib3
    urllib3.disable_warnings()

    host = a.host
    base = base_url(host, False)
    url = a.ws or f"ws://{urlsplit(base).netloc}/linear"
    log = (lambda *x, **k: None)
    if CURRENT.exists() or a.session:
        sess = session_dir(a.session)
        n = 1 + sum(1 for e in load_events(sess) if e.get("type") == "run_start" and str(e.get("run", "")).startswith("savona"))
        lg = Log(sess / "events.jsonl", f"savona{n}")
        log = lambda ty, **kw: lg(ty, **kw)
        log("run_start", kind="savona", url=url)

    st = State()
    stream = MpStream()

    def send(frame, timeout: float = 8):
        """One request at a time; returns (error, result)."""
        ws.send(msgpack.packb(frame, use_bin_type=True))
        rec = enc_payload(msgpack.packb(frame, use_bin_type=True))
        st.sent(rec)
        log("ws_send", url=url, **rec)
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                m = ws.recv(timeout=max(0.1, deadline - time.time()))
            except TimeoutError:
                break
            answer = None
            for chunk in stream.feed(m if isinstance(m, (bytes, bytearray)) else str(m)):
                r = enc_payload(chunk)
                ch, _raw, sv = st.feed_rec(r)
                log("ws_recv", url=url, **r)
                if sv and sv["kind"] == "response" and sv["id"] == frame[1]:
                    answer = (sv["error"], sv["result"])
                for k, old, new in ch:
                    print(f"{now_s(time.time())} ← {k}: {short(old, 50)} → {short(new, 80)}")
            if answer is not None:
                return answer
        return ["timeout"], None

    def call(method: str, params, timeout: float = 8):
        i = 1
        while i in st.pending:
            i += 1
        err, res = send([0, i, method, params], timeout)
        if err:
            print(f"{method} → ERROR {short(err, 200)}")
        return err, res

    def show(tag, obj):
        print(f"{tag}: {json.dumps(obj, ensure_ascii=False, default=str)[:1500]}")

    # --- connect and log in the way VENICE 2's own page does (rm.html, savona-2.9.4):
    # GET /cgi-bin/getsavonacred.cgi with the HTTP login -> "sha256(user):sha256(password)" in hex, then
    # Alternate.Authentication.Basic with params [ {username, password} ] -- an array holding one map. A bare map gets
    # no answer at all, and neither does GetNonce on that firmware. Older firmware's nonce/digest door is the fallback.
    t0 = time.time()
    try:
        ws = connect(url, open_timeout=20, ping_interval=None, max_size=None, user_agent_header=UA)
    except (OSError, InvalidStatus) as e:
        # A VENICE takes one client: another is on it (Tiles, the page, watch), or it let one go seconds ago.
        print(f"the camera refused the socket ({str(e)[:80]}): close Tiles / the page / watch, wait ~5 s, try again")
        return 1
    print(f"socket open to {url} in {time.time() - t0:.1f}s")
    log("ws_open", url=url)
    how = None
    try:
        r = rq.get(f"{base}/cgi-bin/getsavonacred.cgi", timeout=8, verify=False, headers={"User-Agent": UA})
        if r.status_code == 401:
            kind = r.headers.get("WWW-Authenticate", "").lower()
            auth = (rq.auth.HTTPDigestAuth(a.user, a.password) if kind.startswith("digest")
                    else (a.user, a.password))
            r = rq.get(f"{base}/cgi-bin/getsavonacred.cgi", auth=auth, timeout=8, verify=False,
                       headers={"User-Agent": UA})
        if r.status_code == 200 and ":" in r.text:
            u, p = r.text.strip().split(":", 1)
            err3, _ = call("Alternate.Authentication.Basic", [{"username": u, "password": p}], 3)
            how = "basic credentials cgi (the page's own login)" if not err3 else f"basic refused: {err3}"
        elif r.status_code in (401, 403):
            how = f"getsavonacred.cgi HTTP {r.status_code}: check the password"
    except Exception as e:
        how = f"getsavonacred.cgi failed: {e}"
    if how is None or not how.startswith("basic credentials"):
        err, res = call("Alternate.Authentication.GetNonce", [], 3)
        if not err and isinstance(res, dict) and res.get("nonce"):
            r = rq.get(f"{base}/cgi-bin/getsavonadigest.cgi", params={"nonce": res["nonce"]},
                       auth=rq.auth.HTTPDigestAuth(a.user, a.password), timeout=8, verify=False,
                       headers={"User-Agent": UA})
            if r.status_code == 200:
                q = dict(x.split("=", 1) for x in r.text.replace("\r", "").split("\n") if "=" in x)
                err2, _ = call("Alternate.Authentication.Digest",
                               [{"cnonce": q.get("cnonce", ""), "response": q.get("response", "")}], 3)
                how = "nonce/digest cgi" if not err2 else f"digest refused: {err2}"
            else:
                how = f"getsavonadigest.cgi HTTP {r.status_code}"
    print("login: " + (how or "none asked or none accepted yet"))
    err, ver = call("System.GetVersion", [])
    if err and str(err[0]) in ("403", "5001"):
        print("not logged in — check the password")
        return 1
    if not err and ver is not None:
        show("camera", ver)
    if not a.no_subscribe:
        # The page's shape: one argument, the list of notifications (a bare list gets no answer on savona-2.9.4).
        call("Notify.Subscribe", [["Notify.Properties", "Notify.Process", "Notify.Property"]])

    try:
        for name in a.get:
            err, res = call("Property.GetValue", [{name: ["*"]}])
            if not err:
                show(name, res)
        for kv in a.set:
            name, _, val = kv.partition("=")
            if NEVER.search(kv):
                print(f"refused, never sent ({NEVER.search(kv).group(0)}): {kv}")
                continue
            try:
                value = json.loads(val)
            except Exception:
                value = val
            err, _ = call("Property.SetValue", [{name: value}])
            if not err:
                err2, res = call("Property.GetValue", [{name: ["*"]}])
                show(f"{name} now", res if not err2 else err2)
        for key in a.keys:
            if NEVER.search(key):
                print(f"refused, never sent ({NEVER.search(key).group(0)}): {key}")
                continue
            call("Button.SendKeys", [[key]])
        for method, params in a.call:
            if NEVER.search(method + " " + params):
                print(f"refused, never sent ({NEVER.search(method + ' ' + params).group(0)}): {method} {params}")
                continue
            err, res = call(method, json.loads(params))
            if not err:
                show(method, res)
        if a.dump or a.props:
            err, res = call("System.GetProperties", [])
            names = []
            if not err:
                cand = res[0] if isinstance(res, list) and res and isinstance(res[0], list) else res
                if isinstance(cand, list):
                    names = [x for x in cand if isinstance(x, str)]
            print(f"{len(names)} properties known" + (f": {', '.join(names[:40])}" if names else
                                                       f" (System.GetProperties said {short(res, 200)})"))
            if not names and (a.session or CURRENT.exists()):
                # savona-2.9.4 doesn't answer System.GetProperties: ask for every name the camera's own page asked
                # for, or that the camera has reported, in this session's capture.
                seen: set = set()
                for e in load_events(session_dir(a.session)):
                    mp = e.get("mp")
                    if not isinstance(mp, list) or len(mp) < 3:
                        continue
                    if e.get("type") == "ws_send" and len(mp) == 4 and mp[2] == "Property.GetValue":
                        arg = mp[3][0] if isinstance(mp[3], list) and mp[3] else mp[3]
                        if isinstance(arg, dict):
                            seen.update(k for k in arg if isinstance(k, str))
                    elif e.get("type") == "ws_recv" and mp[0] == 2 and mp[1] == "Notify.Property.Value.Changed":
                        arg = mp[2][0] if isinstance(mp[2], list) and mp[2] else mp[2]
                        if isinstance(arg, dict):
                            seen.update(k for k in arg if isinstance(k, str))
                names = sorted(seen)
                print(f"{len(names)} names from this session's capture (the page's requests and the camera's notes)")
            if a.dump and names:
                dump: dict = {}
                for i in range(0, len(names), 60):
                    batch = {n: ["*"] for n in names[i: i + 60]}
                    err, res = call("Property.GetValue", [batch], 15)
                    if not err and isinstance(res, dict):
                        dump.update(res)
                out = (session_dir(a.session) if (a.session or CURRENT.exists()) else Path(".")) / "savona-dump.json"
                out.write_text(json.dumps(dump, indent=1, ensure_ascii=False))
                print(f"dumped {len(dump)} properties to {out}")
        if a.master and (a.session or CURRENT.exists()):
            # Everything the camera will tell us, for working on it once it's gone: every property name in the page's
            # own scripts and this session's traffic, read (values, lock status) and asked for its option list, plus
            # every full-menu node's list (P.System.Menu.L3_…). One request at a time; silence is a name it lacks.
            import re as _re
            sess = session_dir(a.session)
            names: set = set()
            menu_nodes: set = set()
            for e in load_events(sess):
                mp = e.get("mp")
                if not isinstance(mp, list) or len(mp) < 3:
                    continue
                arg = mp[3][0] if len(mp) == 4 and isinstance(mp[3], list) and mp[3] else (mp[2][0] if len(mp) == 3 and isinstance(mp[2], list) and mp[2] else None)
                if isinstance(arg, dict):
                    names.update(k for k in arg if isinstance(k, str))
                elif isinstance(arg, list):
                    names.update(k for k in arg if isinstance(k, str) and "." in k)
            for root in (sess / "runtime", sess / "mirror"):
                for f in root.rglob("*.js") if root.exists() else []:
                    text = f.read_text(errors="ignore")
                    names.update("P.System.Menu." + m for m in _re.findall(r"savonaPrefix \+ '([A-Za-z0-9_.]+)'", text))
                    names.update(_re.findall(r"['\"]((?:Camera|Output|LUT|Storage|Clip|System|Video|Button|Network|Paint|Camcorder|"
                                             r"Control|Monitoring|Audio|Lens|Media|FrameLineFile|P\.Clip|P\.System|P\.Menu)"
                                             r"\.[A-Za-z0-9_.]*[A-Za-z0-9])['\"]", text))
                    menu_nodes.update("P.System.Menu." + m for m in _re.findall(r'new MenuNode\(\d+, "(L\d_[A-Z0-9_]+)"', text))
            names = sorted(n for n in names if not n.startswith(("Notify.", "Alternate.")))
            print(f"master: {len(names)} property names, {len(menu_nodes)} menu lists")

            def ask(method, params, timeout=8):
                return send([0, 1, method, params], timeout)

            values, statuses, capabilities = {}, {}, {}
            for i in range(0, len(names), 50):
                chunk = names[i:i + 50]
                err, res = ask("Property.GetValue", [{n: ["*"] for n in chunk}], 12)
                if not err and isinstance(res, dict):
                    values.update(res)
                err, res = ask("Property.GetStatus", [{n: None for n in chunk}], 12)
                if not err and isinstance(res, dict):
                    statuses.update(res)
            print(f"master: {len(values)} values, {len(statuses)} statuses")
            wanted = sorted(set(names) | set(values) | set(menu_nodes))
            # Does the camera take several names in one Capability.GetValue? (The page asks one at a time.)
            err, res = ask("Capability.GetValue", [["Camera.Shutter.Angle", "Camera.Gain.ExposureIndex.Value"]], 5)
            batched = not err and isinstance(res, dict) and len(res) >= 1
            print(f"master: option lists {'in batches' if batched else 'one at a time'} for {len(wanted)} names")
            deadline = time.time() + 600  # ten minutes at most: the rest of the session matters more
            step = 25 if batched else 1
            for i in range(0, len(wanted), step):
                if time.time() > deadline:
                    print(f"master: stopped the option lists at {i} of {len(wanted)} (time)")
                    break
                chunk = wanted[i:i + step]
                err, res = ask("Capability.GetValue", [chunk], 8 if batched else 1.5)
                if not err and isinstance(res, dict):
                    capabilities.update(res)
                elif batched and err == ["timeout"]:
                    for n in chunk:  # one name in the batch the camera won't answer: ask one by one
                        e2, r2 = ask("Capability.GetValue", [[n]], 1.5)
                        if not e2 and isinstance(r2, dict):
                            capabilities.update(r2)
                if i and i % 200 < step:
                    print(f"master: {i} of {len(wanted)} asked, {len(capabilities)} lists")
            out = sess / "master.json"
            out.write_text(json.dumps({"taken": time.strftime("%Y-%m-%d %H:%M:%S"), "url": url, "names_asked": names,
                                       "menu_lists_asked": sorted(menu_nodes), "values": values, "statuses": statuses,
                                       "capabilities": capabilities}, indent=1, ensure_ascii=False, default=str))
            print(f"master: {len(capabilities)} option lists -> {out}")
        if a.listen > 0:
            print(f"listening {a.listen:.0f}s (change things on the camera or its page)…")
            deadline = time.time() + a.listen
            while time.time() < deadline:
                try:
                    m = ws.recv(timeout=max(0.1, deadline - time.time()))
                except TimeoutError:
                    break
                for chunk in stream.feed(m if isinstance(m, (bytes, bytearray)) else str(m)):
                    r = enc_payload(chunk)
                    ch, _raw, sv = st.feed_rec(r)
                    log("ws_recv", url=url, **r)
                    if not ch and sv:
                        print(f"{now_s(time.time())} ← {sv.get('name') or sv.get('kind')} {short(sv.get('data'), 160)}")
                    for k, old, new in ch:
                        print(f"{now_s(time.time())} ← {k}: {short(old, 50)} → {short(new, 80)}")
    finally:
        try:
            ws.close()
        except Exception:
            pass
        log("ws_close", url=url)
    print(f"done. {len(st.v)} values seen")
    return 0


def cmd_report(a) -> int:
    for ln in build_report(session_dir(a.dir)):
        print(ln)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def conn(p, host_required=True):
        p.add_argument("host", nargs=None if host_required else "?", help="camera IP or host[:port]")
        p.add_argument("-u", "--user", default=os.environ.get("VENICE_USER", "admin"))
        p.add_argument("-p", "--password", default=os.environ.get("VENICE_PASS"))
        p.add_argument("--https", action="store_true")

    p = sub.add_parser("find")
    p.add_argument("--port", type=int, default=80)
    p.set_defaults(fn=cmd_find)
    p = sub.add_parser("go")
    conn(p, host_required=False)
    p.add_argument("--port", type=int, default=80, help="port to sweep for when HOST is omitted")
    p.add_argument("--pages", default="/rm.html,/rmt.html")
    p.add_argument("--settle", type=float, default=8, help="seconds to listen after each page loads")
    p.add_argument("--noise", type=float, default=8, help="seconds of hands-off listening to learn self-changing values")
    p.add_argument("--beautify", type=float, default=90, help="seconds allowed for pretty-printing scripts")
    p.set_defaults(fn=cmd_go)
    p = sub.add_parser("watch")
    conn(p)
    p.add_argument("--path", default="/rm.html")
    p.add_argument("--headed", action="store_true", help="visible Chrome window on this Mac")
    p.add_argument("--detach", action="store_true")
    p.add_argument("--new", action="store_true", help="new session folder instead of the current one")
    p.add_argument("--session")
    p.add_argument("--minutes", type=float, default=120)
    p.add_argument("--settle", type=float, default=6)
    p.add_argument("--noise", type=float, default=8)
    p.set_defaults(fn=cmd_watch)
    p = sub.add_parser("proxy")
    conn(p)
    p.add_argument("--listen", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--also-port", type=int, action="append", default=[],
                   help="another camera port to relay as-is (if the page opens its WebSocket on its own port)")
    p.add_argument("--detach", action="store_true")
    p.add_argument("--session")
    p.set_defaults(fn=cmd_proxy)
    p = sub.add_parser("savona")
    p.add_argument("host", help="camera IP or host[:port]")
    p.add_argument("-u", "--user", default=os.environ.get("VENICE_USER", "admin"))
    p.add_argument("-p", "--password", default=os.environ.get("VENICE_PASS"))
    p.add_argument("--ws", help="ws://… (default ws://HOST/linear)")
    p.add_argument("--get", action="append", default=[], help="read a property, e.g. Camera.NDFilter.Value")
    p.add_argument("--set", action="append", default=[], metavar="KEY=JSON", help="write a property")
    p.add_argument("--keys", action="append", default=[], metavar="NAME", help="press a key, e.g. Rec")
    p.add_argument("--call", action="append", default=[], metavar="METHOD PARAMS", nargs=2, help="any method")
    p.add_argument("--props", action="store_true", help="list the property names the camera knows")
    p.add_argument("--dump", action="store_true", help="read every property into savona-dump.json")
    p.add_argument("--master", action="store_true",
                   help="the whole interface into master.json: every name the page's scripts and the session know, "
                        "read with its lock status and option list, and every full-menu list")
    p.add_argument("--listen", type=float, default=0, help="seconds of notifications after the commands")
    p.add_argument("--no-subscribe", action="store_true")
    p.add_argument("--session")
    p.set_defaults(fn=savona_cli)
    p = sub.add_parser("raw")
    p.add_argument("url", nargs="?", help="ws://… (default: the one the page opened in this session)")
    p.add_argument("-u", "--user", default=os.environ.get("VENICE_USER", "admin"))
    p.add_argument("-p", "--password", default=os.environ.get("VENICE_PASS"))
    p.add_argument("--send", action="append", default=[], help="a text frame; repeat for more, sent one at a time")
    p.add_argument("--wait", type=float, default=3, help="seconds to listen before the first send")
    p.add_argument("--gap", type=float, default=2.5, help="seconds to listen after each send")
    p.add_argument("--secs", type=float, default=2, help="seconds to listen at the end")
    p.add_argument("--origin")
    p.add_argument("--protocol", help="Sec-WebSocket-Protocol (default: what the page asked for)")
    p.add_argument("--no-cookies", action="store_true")
    p.add_argument("--raw", action="store_true")
    p.add_argument("--session")
    p.set_defaults(fn=cmd_raw)
    p = sub.add_parser("ctl")
    p.add_argument("op", choices=["click", "eval", "send", "shot", "dom", "snap", "reload", "goto", "ping", "stop"])
    p.add_argument("arg", nargs="*")
    p.add_argument("--force", action="store_true")
    p.add_argument("--after", type=float, default=2.5, help="seconds of follow-up to print")
    p.add_argument("--timeout", type=float, default=40)
    p.add_argument("--session")
    p.set_defaults(fn=cmd_ctl)
    p = sub.add_parser("note")
    p.add_argument("label", nargs="*")
    p.add_argument("--since", type=float, help="seconds back instead of since the last note")
    p.add_argument("--raw", action="store_true")
    p.add_argument("--session")
    p.set_defaults(fn=cmd_note)
    p = sub.add_parser("diff")
    p.add_argument("a", nargs="?")
    p.add_argument("b", nargs="?")
    p.add_argument("--session")
    p.set_defaults(fn=cmd_diff)
    for name, fn in (("status", cmd_status), ("stop", cmd_stop)):
        p = sub.add_parser(name)
        p.add_argument("--session")
        p.set_defaults(fn=fn)
    p = sub.add_parser("report")
    p.add_argument("dir", nargs="?")
    p.set_defaults(fn=cmd_report)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
