#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["requests>=2.32", "aiohttp>=3.9"]
# ///
"""Capture an ARRI camera's Web Remote (ALEXA Mini, Mini LF, ALEXA 35, AMIRA) fast, then watch it while its controls
are exercised. Plain HTTP and JSON, no login, so no browser is needed to read it.

  arri.py find [--port 80]           look for ARRI Web Remotes on this Mac's networks (and the HaLow mesh)
  arri.py go HOST                    mirror the page and its scripts, save all.cgi and the enum script, check the
                                     long poll's shape, write report.md with Tiles' coverage (read-only, seconds)
  arri.py watch HOST [--detach]      hold update.cgi?id= open and log every change, labelled (all.cgi diffs if the
                                     long poll isn't there); `stop` ends it
  arri.py proxy HOST [--port 8081] [--detach]
                                     reverse proxy that records a browser driving the camera's own page:
                                     open http://localhost:8081/ and use it; every call is logged
  arri.py note "what I just did"     print the changes since the last note and label that window; also snaps (below)
                                     unless --no-snap, printing any range / choice / read-only change
  arri.py snap "16:9 HD, ProRes HQ"  save all.cgi as snaps/NNN-label.json and print what the camera now allows that it
                                     didn't (ranges, selectable choices, read-only flags, values) since the last snap
  arri.py ranges [NAME ...]          per snap: each variable's value and what was allowed then, for the key exposure
                                     variables and every variable whose range or choices moved (writes ranges.md)
  arri.py diff [A [B]]               variables that differ (session start vs the camera now): what to put back
  arri.py set HOST NAME=VALUE        one set.cgi (VALUE: a number, true/false, or text)
  arri.py call HOST COMMAND [JSON]   one call.cgi, by the command's name or ID
  arri.py raw HOST PATH [JSON]       any GET (or POST with JSON)
  arri.py status | stop | report [DIR]

Captures go to captures/arri/<stamp>-<host>/ (gitignored); captures/arri/current points at the latest. Nothing
here changes a setting by itself: go, watch and diff only read; set, call and raw act only when told.

Over SSH to a Mac, run watch and proxy in the foreground (a terminal multiplexer's pane, or an ssh session kept open), not --detach:
macOS takes local-network access away from a process once the ssh session that started it ends, and the camera then
reads as "No route to host" while it's fine.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import ipaddress
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlsplit

HERE = Path(__file__).resolve().parent
# Never sent, whatever is asked: formatting, erasing or initializing media (Tiles' rule; CameraCore's MediaSafety).
NEVER = re.compile(r"format|erase|initiali[sz]", re.I)
REPO = HERE.parent.parent
CAPROOT = Path(os.environ.get("ARRI_CAPTURES") or (REPO / "captures" / "arri"))
CURRENT = CAPROOT / "current"


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

# ------------------------------------------------------------------------------------------------------- sessions


def stamp(t: float | None = None) -> str:
    t = time.time() if t is None else t
    return dt.datetime.fromtimestamp(t).strftime("%H:%M:%S.") + f"{int((t % 1) * 10)}"


def base(host: str) -> str:
    return host.rstrip("/") if "://" in host else f"http://{host.rstrip('/')}"


def new_session(host: str) -> Path:
    d = CAPROOT / f"{dt.datetime.now():%Y%m%d-%H%M%S}-{re.sub(r'[^A-Za-z0-9.-]+', '_', host)}"
    d.mkdir(parents=True)
    tmp = CAPROOT / ".current.tmp"
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(d.name)
    os.replace(tmp, CURRENT)
    (d / "host").write_text(host)
    return d


def session(arg: str | None = None) -> Path:
    if arg:
        return Path(arg).expanduser().resolve()
    if not CURRENT.exists():
        sys.exit("no capture yet: run `arri.py go HOST` first")
    return CURRENT.resolve()


def event(sess: Path, rec: dict) -> None:
    rec.setdefault("t", time.time())
    with open(sess / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, default=str) + "\n")


def events(sess: Path) -> list[dict]:
    p = sess / "events.jsonl"
    if not p.exists():
        return []
    out = []
    for line in p.read_text(encoding="utf-8").splitlines():
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out


# ------------------------------------------------------------------------------------------------- the camera's data


def http():
    import requests
    s = requests.Session()
    s.trust_env = False  # never through a system proxy
    return s


def get_all(host: str, s=None) -> tuple[dict, int]:
    r = (s or http()).get(f"{base(host)}/all.cgi", timeout=8)
    r.raise_for_status()
    return r.json(), len(r.content)


class Enums:
    """The page script's enums: variable → type, type → tokens, "Type_TOKEN" → English label."""

    def __init__(self, script: str = ""):
        self.type_of: dict[str, str] = {}
        self.tokens: dict[str, list[str]] = {}
        self.labels: dict[str, str] = {}
        for m in re.finditer(r"\.([A-Za-z_]\w*)\s*=\s*\{([^{}]{0,600})\}", script):
            t = re.search(r"\btype\s*:\s*[\"']([\w]+)[\"']", m.group(2))
            if t:
                n = re.search(r"\bname\s*:\s*[\"']([\w]+)[\"']", m.group(2))
                self.type_of[n.group(1) if n else m.group(1)] = t.group(1)
        for m in re.finditer(r"([A-Za-z_$][\w$]*)\s*:\s*[\"']([^\"']*)[\"']\s*\.split\(\s*[\"'] [\"']\s*\)", script):
            self.tokens.setdefault(m.group(1), m.group(2).split())
        for m in re.finditer(r"([A-Za-z_$][\w$]*)\s*:\s*\[\s*((?:\"[^\"]*\"|'[^']*')(?:\s*,\s*(?:\"[^\"]*\"|'[^']*'))*)\s*,?\s*\]", script):
            self.tokens.setdefault(m.group(1), re.findall(r"[\"']([^\"']*)[\"']", m.group(2)))
        for m in re.finditer(r"\.en\.ENUM_(\w+)\s*=\s*\"((?:[^\"\\]|\\.)*)\"", script):
            self.labels.setdefault(m.group(1), m.group(2))
        if not self.labels:
            for m in re.finditer(r"[\"']?ENUM_(\w+)[\"']?\s*[:=]\s*\"((?:[^\"\\]|\\.)*)\"", script):
                self.labels.setdefault(m.group(1), m.group(2))

    def label(self, name: str, index) -> str | None:
        t = self.type_of.get(name)
        toks = self.tokens.get(t or "", [])
        try:
            i = int(index)
        except Exception:
            return None
        if not (0 <= i < len(toks)):
            return None
        return self.labels.get(f"{t}_{toks[i]}", toks[i])

    def options(self, name: str, var: dict) -> list[str]:
        t = self.type_of.get(name)
        toks = self.tokens.get(t or "", [])
        flags = var.get("properties") or [3] * len(toks)
        out = []
        for i, tok in enumerate(toks):
            lab = self.labels.get(f"{t}_{tok}", tok)
            out.append(lab if i < len(flags) and flags[i] & 3 == 3 else f"{lab}×")
        return out


def load_enums(sess: Path) -> Enums:
    p = sess / "all-dg.min.js"
    return Enums(p.read_text(encoding="utf-8", errors="replace") if p.exists() else "")


def show(name: str, value, enums: Enums) -> str:
    lab = enums.label(name, value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    text = json.dumps(value) if not isinstance(value, str) else value
    return f"{text} [{lab}]" if lab is not None else text


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
            res.append((name, ipaddress.IPv4Interface(f"{m.group(1)}/{bin(int(m.group(2), 16)).count('1')}")))
    return [r for r in res if not r[0].startswith(("lo", "utun", "gif", "stf", "awdl", "llw", "anpi", "ap"))]


def targets() -> set[str]:
    out: set[str] = set()
    for _, ifc in local_ifaces():
        net = ifc.network
        nets = [net] if net.prefixlen >= 22 else [ipaddress.ip_network(f"{ifc.ip}/24", strict=False)]
        for n in nets:
            out.update(str(h) for h in n.hosts() if h != ifc.ip)
        if MESH and ifc.ip in MESH:  # each HaLow node N hands out <subnet>.N.100-199
            a, b = str(MESH.network_address).split(".")[:2]
            for node in MESH_NODES:
                out.update(f"{a}.{b}.{node}.{h}" for h in range(100, 200))
    arp = subprocess.run(["arp", "-an"], capture_output=True, text=True).stdout
    out.update(re.findall(r"\((\d+\.\d+\.\d+\.\d+)\) at [0-9a-f:]+", arp))
    return out


async def sweep(ips: list[str], port: int) -> list[str]:
    sem, found = asyncio.Semaphore(256), []

    async def one(ip):
        async with sem:
            try:
                _, w = await asyncio.wait_for(asyncio.open_connection(ip, port), 0.6)
                w.close()
                found.append(ip)
            except Exception:
                pass

    await asyncio.gather(*(one(ip) for ip in ips))
    return found


def cmd_find(a) -> int:
    t0 = time.time()
    ips = sorted(targets())
    open_ = asyncio.run(sweep(ips, a.port))
    print(f"swept {len(ips)} addresses for port {a.port} in {time.time() - t0:.1f}s; {len(open_)} answer")
    s, hits = http(), 0
    for ip in open_:
        host = ip if a.port == 80 else f"{ip}:{a.port}"
        try:
            doc, size = get_all(host, s)
            v = doc.get("variables", {})
            model = next((v[k]["value"] for k in ("SystemCameraType", "CameraType") if isinstance(v.get(k), dict)), "?")
            print(f"  ARRI {host:<21} {model}  {len(v)} variables, all.cgi {size} bytes")
            hits += 1
        except Exception:
            print(f"  {host:<26} not an ARRI Web Remote")
    if not hits:
        print("no ARRI Web Remote found. Check the camera's Ethernet (or Wi-Fi: 192.168.153.1) and its network menu.")
    return 0 if hits else 1


# -------------------------------------------------------------------------------------------------------------- go


def wire(host: str, path: str, s) -> dict:
    """What one read costs on the link: the bytes as sent (compressed or not), gzip accepted as Tiles' URLSession
    accepts it. A full all.cgi can run to a few hundred KB decoded: half a minute at HaLow's 64 kbit/s budget."""
    r = s.get(f"{base(host)}{path}", timeout=15, stream=True, headers={"Accept-Encoding": "gzip, deflate"})
    raw = r.raw.read(decode_content=False)
    return {"path": path, "status": r.status_code, "wire_bytes": len(raw), "encoding": r.headers.get("Content-Encoding"),
            "content_length": r.headers.get("Content-Length"), "type": r.headers.get("Content-Type"),
            "server": r.headers.get("Server"), "cache": r.headers.get("Cache-Control")}


def mirror(sess: Path, host: str, s) -> dict:
    """The root page and every script, style and page it references, as the browser would load them."""
    root = sess / "mirror"
    seen, queue, info = set(), ["/", "/index.html"], {}
    while queue and len(seen) < 300:
        path = queue.pop(0)
        if path in seen:
            continue
        seen.add(path)
        try:
            r = s.get(urljoin(base(host) + "/", path.lstrip("/")), timeout=10)
        except Exception as e:
            info[path] = {"error": type(e).__name__}
            continue
        info[path] = {"status": r.status_code, "bytes": len(r.content), "type": r.headers.get("Content-Type", ""),
                      "etag": r.headers.get("ETag"), "last_modified": r.headers.get("Last-Modified"),
                      "cache": r.headers.get("Cache-Control"), "encoding": r.headers.get("Content-Encoding"),
                      "server": r.headers.get("Server")}
        if r.status_code != 200:
            continue
        local = root / (path.strip("/") or "index.html")
        if local.suffix == "" and not path.endswith((".js", ".css")):
            local = local / "index.html"
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_bytes(r.content)
        if any(k in r.headers.get("Content-Type", "") for k in ("html", "javascript", "css")) or path.endswith((".js", ".html", ".css")):
            text = r.text
            for ref in re.findall(r"""(?:src|href)\s*=\s*["']([^"'#?]+)""", text) + re.findall(r"""["'](/?[\w./-]+\.(?:js|css|html|json))["']""", text):
                u = urlsplit(urljoin(path if path.startswith("/") else "/" + path, ref))
                if not u.netloc and u.path and not u.path.endswith((".png", ".jpg", ".svg", ".woff", ".woff2", ".ttf", ".ico")):
                    queue.append(u.path)
    return info


def cmd_go(a) -> int:
    s = http()
    t0 = time.time()
    try:
        doc, size = get_all(a.host, s)
    except Exception as e:
        print(f"{a.host}: all.cgi didn't answer as an ARRI Web Remote ({e}). Try `arri.py find`.")
        return 1
    sess = new_session(a.host)
    (sess / "all.cgi.json").write_text(json.dumps(doc, indent=1, sort_keys=True))
    (sess / "start.json").write_text(json.dumps(doc, sort_keys=True))
    event(sess, {"kind": "all", "bytes": size, "id": doc.get("id")})
    print(f"all.cgi: {len(doc.get('variables', {}))} variables, {len(doc.get('commands', {}))} commands, {size} bytes")
    try:
        cost = wire(a.host, "/all.cgi", s) | {"decoded_bytes": size}
        (sess / "wire.json").write_text(json.dumps(cost, indent=1))
        print(f"all.cgi on the wire: {cost['wire_bytes']} bytes, encoding {cost['encoding'] or 'none'} "
              f"({cost['wire_bytes'] * 8 / 64000:.1f} s at 64 kbit/s)")
    except Exception as e:
        print(f"all.cgi wire size not measured ({type(e).__name__}: {e})")
    r = s.get(f"{base(a.host)}/js/all-dg.min.js", timeout=30)
    if r.status_code == 200:
        (sess / "all-dg.min.js").write_bytes(r.content)
        print(f"page script: {len(r.content)} bytes (ETag {r.headers.get('ETag')}, Last-Modified {r.headers.get('Last-Modified')}, "
              f"encoding {r.headers.get('Content-Encoding')})")
    else:
        print(f"page script: HTTP {r.status_code}")
    if not a.no_mirror:
        pages = mirror(sess, a.host, s)
        (sess / "mirror.json").write_text(json.dumps(pages, indent=1))
        print(f"mirror: {sum(1 for p in pages.values() if p.get('status') == 200)} files")
    # The long poll's shape: ask for what changed since the change before last; a camera that keeps no history
    # holds the request, which says it's a long poll but not yet what it answers.
    # `id` is this client's session (all.cgi hands one out; the camera keeps what changed per session), not a change
    # counter: poll with our own, as the page does. Someone else's id would take their changes.
    try:
        t = time.time()
        u = s.get(f"{base(a.host)}/update.cgi", params={"id": doc.get("id")}, timeout=4)
        probe = {"after": doc.get("id"), "status": u.status_code, "bytes": len(u.content),
                 "seconds": round(time.time() - t, 2), "body": u.text[:3000]}
    except Exception as e:
        probe = {"after": doc.get("id"), "held": type(e).__name__}
    (sess / "update-probe.json").write_text(json.dumps(probe, indent=1))
    print(f"update.cgi: {probe.get('status', probe.get('held'))} "
          f"{str(probe.get('body', ''))[:160]}")
    write_report(sess)
    print(f"done in {time.time() - t0:.1f}s → {sess}/report.md")
    return 0


# ------------------------------------------------------------------------------------------------------------ report

WORDS = ["rec", "state", "timecode", "tc", "look", "frame", "false", "zebra", "peak", "focus", "tool", "overlay",
         "evf", "sdi", "mon", "battery", "volt", "media", "remain", "card", "reel", "clip", "lens", "iris", "lds",
         "test", "flip", "squeeze", "user", "button", "tally", "awb", "auto", "project", "sensor", "codec", "format"]


def camctl() -> str | None:
    for c in (os.environ.get("CAMCTL"), str(HERE / "bin" / "camctl"), str(HERE.parent / "bin" / "camctl"),
              str(REPO / "Packages/CameraKit/.build/debug/camctl"), shutil.which("camctl")):
        if c and Path(c).exists():
            return c
    return None


def write_report(sess: Path) -> None:
    doc = json.loads((sess / "all.cgi.json").read_text())
    v, cmds = doc.get("variables", {}), doc.get("commands", {})
    enums = load_enums(sess)

    def val(n):
        x = v.get(n)
        return x.get("value") if isinstance(x, dict) else x

    lines = [f"# ARRI Web Remote capture: {(sess / 'host').read_text() if (sess / 'host').exists() else sess.name}", "",
             f"- Captured {dt.datetime.fromtimestamp((sess / 'all.cgi.json').stat().st_mtime):%Y-%m-%d %H:%M}",
             f"- Model {val('SystemCameraType')}, serial {val('SystemCameraSerial')}, "
             f"SUP {next((val(k) for k in v if 'sup' in k.lower() or 'softwareversion' in k.lower()), '?')}",
             f"- {len(v)} variables, {len(cmds)} commands, change counter {doc.get('id')}",
             f"- all.cgi {(sess / 'all.cgi.json').stat().st_size} bytes as saved (indented); page script "
             f"{(sess / 'all-dg.min.js').stat().st_size if (sess / 'all-dg.min.js').exists() else 'missing'} bytes; "
             f"{len(enums.type_of)} enum variables, {len(enums.labels)} labels"]
    cost = json.loads((sess / "wire.json").read_text()) if (sess / "wire.json").exists() else {}
    if cost:
        lines.append(f"- all.cgi on the wire: {cost.get('wire_bytes')} bytes, encoding {cost.get('encoding') or 'none'}, "
                     f"{cost.get('decoded_bytes')} decoded; server {cost.get('server')}")
    probe = json.loads((sess / "update-probe.json").read_text()) if (sess / "update-probe.json").exists() else {}
    lines += [f"- update.cgi?id={probe.get('after')}: {probe.get('status', probe.get('held'))}, "
              f"{probe.get('seconds', '')}s, `{str(probe.get('body', ''))[:300]}`", ""]
    tool = camctl()
    if tool:
        out = subprocess.run([tool, "arri", "--from", str(sess)], capture_output=True, text=True, timeout=60)
        lines += ["## What Tiles reads (camctl arri --from)", "", "```", out.stdout.strip() or out.stderr.strip(), "```", ""]
    else:
        lines += ["## What Tiles reads", "", "camctl not found here: run `camctl arri --from <this dir>` where it's built.", ""]
    lines += ["## Commands", ""] + [f"- `{name}`  {cid}" for cid, name in sorted(cmds.items(), key=lambda x: (x[1], x[0]))] + [""]
    lines += ["## Variables to look at for Tiles' guesses", ""]
    for n in sorted(v):
        if any(w in n.lower() for w in WORDS):
            x = v[n] if isinstance(v[n], dict) else {"value": v[n]}
            lines.append(f"- `{n}` = {show(n, x.get('value'), enums)}  ({x.get('type')}{', ro' if x.get('readonly') else ''})")
    lines += ["", "## Every variable", "", "| name | type | value | range / choices | ro |", "|---|---|---|---|---|"]
    for n in sorted(v):
        x = v[n] if isinstance(v[n], dict) else {"value": v[n]}
        if x.get("type") == "enumint" and enums.type_of.get(n):
            rng = " / ".join(enums.options(n, x)[:16])
        elif "min" in x:
            rng = f"{x.get('min')}…{x.get('max')}"
        else:
            rng = ""
        lines.append(f"| `{n}` | {x.get('type')} | {show(n, x.get('value'), enums)[:60]} | {rng[:160]} | "
                     f"{'ro' if x.get('readonly') else ''} |")
    (sess / "report.md").write_text("\n".join(lines) + "\n")


def cmd_report(a) -> int:
    sess = session(a.dir)
    write_report(sess)
    print(sess / "report.md")
    return 0


# ----------------------------------------------------------------------------------------------------------- watch


def keep_awake(pid: int) -> None:
    if shutil.which("caffeinate"):
        subprocess.Popen(["caffeinate", "-i", "-s", "-w", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def detach(sess: Path, name: str, argv: list[str]) -> int:
    log = open(sess / f"{name}.log", "a")
    p = subprocess.Popen([sys.executable, str(Path(__file__).resolve())] + argv, stdout=log, stderr=log,
                         start_new_session=True)
    (sess / f"{name}.pid").write_text(str(p.pid))
    keep_awake(p.pid)
    print(f"{name} running (pid {p.pid}); log {sess / (name + '.log')}; `arri.py stop` ends it")
    return 0


def cmd_watch(a) -> int:
    sess = session() if not a.new else new_session(a.host)
    if a.detach:
        return detach(sess, "watch", ["watch", a.host])
    (sess / "watch.pid").write_text(str(os.getpid()))
    keep_awake(os.getpid())
    enums = load_enums(sess)
    stop = {"now": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True))
    cam = Session(a.host, sess)
    print(f"{stamp()} watching {a.host} as the camera's own page does (Ctrl-C or `arri.py stop`)")
    while not stop["now"]:
        try:
            if cam.id is None:
                cam.connect()
                print(f"{stamp()} all.cgi: {len(cam.model)} variables, session {cam.id}")
            for n, (old, new) in sorted(cam.poll().items()):
                if not any(n.startswith(p) for p in NOISY):
                    print(f"{stamp()}  {n}  {show(n, old, enums)} → {show(n, new, enums)}")
        except KeyboardInterrupt:
            break
        except Exception as e:
            # As the page: a failed read waits 3 s, then starts again with all.cgi (a new session).
            print(f"{stamp()} {type(e).__name__}: {str(e)[:200]}")
            event(sess, {"kind": "error", "error": str(e)[:300]})
            cam.id = None
            time.sleep(3)
    cam.save(force=True)
    event(sess, {"kind": "watch-stop"})
    return 0


# Variables that move by themselves several times a second: kept in the model and the raw log, not printed.
NOISY = ("LevelRoll", "LevelTilt", "SensorTemperature", "SystemDate", "Timecode", "AudioRec", "Bat1LevelVolt",
         "Bat2LevelVolt", "PreRecordDurationActive", "OperatingTime", "FocusAssistResult", "FocusAnalysis")


class Session:
    """One client of the Web Remote, speaking it as the camera's own page does (all-dg.min.js): all.cgi gives every
    variable and a session `id`; update.cgi?id= then answers only what changed for that session, each with the fields
    that moved (value, min, max, properties, readonly); "Invalid id" means the session is gone, so all.cgi again.
    The page polls again as soon as an answer lands, with a 3 s timeout. The model it builds is kept in model.json,
    which `snap` reads instead of asking the camera for another all.cgi."""

    def __init__(self, host: str, sess: Path):
        self.host, self.sess, self.s = host, sess, http()
        self.id: int | None = None
        self.model: dict[str, dict] = {}
        self.saved = 0.0

    def connect(self) -> None:
        r = self.s.get(f"{base(self.host)}/all.cgi", timeout=10)
        r.raise_for_status()
        doc = r.json()
        self.model = fields(doc)
        self.id = doc.get("id")
        event(self.sess, {"kind": "session", "id": self.id, "bytes": len(r.content)})
        # Each new session's full read is kept: after a sensor-format or codec reload it's the only place the new
        # ranges are whole.
        keep = self.sess / "sessions"
        keep.mkdir(exist_ok=True)
        (keep / f"{dt.datetime.now():%H%M%S}-{self.id}.json").write_bytes(r.content)
        self.save(force=True)

    def poll(self, timeout: float = 3) -> dict[str, tuple]:
        t = time.time()
        r = self.s.get(f"{base(self.host)}/update.cgi", params={"id": self.id}, timeout=timeout)
        body = r.json()
        event(self.sess, {"kind": "update-raw", "status": r.status_code, "bytes": len(r.content),
                          "ms": int((time.time() - t) * 1000), "body": r.text[:200000]})
        if not isinstance(body.get("variables"), dict):
            if "Invalid id" in str(body.get("ERROR", "")):
                self.id = None
            else:
                time.sleep(1)  # the page logs this and stops; keep listening, gently
            return {}
        moved = {}
        for n, entry in body["variables"].items():
            entry = entry if isinstance(entry, dict) else {"value": entry}
            was = dict(self.model.get(n, {}))
            self.model.setdefault(n, {}).update(entry)
            if was.get("value") != entry.get("value", was.get("value")):
                moved[n] = (was.get("value"), entry.get("value"))
                if not any(n.startswith(p) for p in NOISY):
                    event(self.sess, {"kind": "change", "name": n, "old": was.get("value"), "new": entry.get("value")})
            other = {k: v for k, v in entry.items() if k not in ("value", "type") and was.get(k) != v}
            if other and was:
                event(self.sess, {"kind": "fields", "name": n, "was": {k: was.get(k) for k in other}, "now": other})
        self.save()
        return moved

    def save(self, force: bool = False) -> None:
        if force or time.time() - self.saved > 1:
            tmp = self.sess / ".model.tmp"
            tmp.write_text(json.dumps({"id": self.id, "t": time.time(), "variables": self.model}))
            os.replace(tmp, self.sess / "model.json")
            self.saved = time.time()


def cmd_note(a) -> int:
    sess = session()
    evs = events(sess)
    since = max((e["t"] for e in evs if e.get("kind") == "note"), default=0)
    changes = [e for e in evs if e.get("kind") == "change" and e["t"] > since]
    proxied = [e for e in evs if e.get("kind") == "proxy" and e["t"] > since and "/update.cgi" not in e.get("path", "")]
    enums = load_enums(sess)
    print(f"since the last note: {len(changes)} changes, {len(proxied)} page calls")
    for e in changes:
        print(f"  {stamp(e['t'])}  {e['name']}  {show(e['name'], e['old'], enums)} → {show(e['name'], e['new'], enums)}")
    for e in proxied:
        print(f"  {stamp(e['t'])}  {e['method']} {e['path']}  {str(e.get('request', ''))[:160]}  → {str(e.get('response', ''))[:120]}")
    event(sess, {"kind": "note", "text": a.text, "changes": len(changes)})
    print(f"noted: {a.text}")
    if not a.no_snap:
        try:
            moved = snap(sess, a.text, values=False)
            print(f"snap: {len(moved)} variables changed range, choices or read-only" + (":" if moved else ""))
            if moved:
                print("\n".join(moved))
        except Exception as e:
            print(f"snap skipped ({type(e).__name__}: {e})")
    return 0


def cmd_diff(a) -> int:
    sess = session()
    enums = load_enums(sess)

    def values(p):
        d = json.loads(Path(p).read_text())
        return {n: (x.get("value") if isinstance(x, dict) else x) for n, x in d.get("variables", {}).items()}

    first = values(a.a) if a.a else values(sess / "start.json")
    if a.b:
        second = values(a.b)
    else:
        doc, _ = get_all((sess / "host").read_text())
        (sess / "now.json").write_text(json.dumps(doc, sort_keys=True))
        second = {n: (x.get("value") if isinstance(x, dict) else x) for n, x in doc.get("variables", {}).items()}
    diffs = [n for n in sorted(set(first) | set(second)) if first.get(n) != second.get(n)]
    print(f"{len(diffs)} differ (start → now); put back what isn't a clock, meter or counter:")
    for n in diffs:
        mark = "   " if any(w in n for w in METERS) else "→ "
        print(f"{mark}{n}: {show(n, first.get(n), enums)} → {show(n, second.get(n), enums)}")
    return 0


# ----------------------------------------------------------------------------------------------------------- snaps
# all.cgi carries each variable's range (min / max), its selectable enum choices (properties & 3 == 3) and its
# read-only flag as they are NOW: for this sensor mode, codec and frame rate, recording or not. The long poll may
# only carry values, so a snap after each change is how the ranges per mode get read.

METERS = ("Timecode", "Remaining", "Voltage", "Battery", "Temperature", "Time", "Date", "Count", "Version",
          "ClipName", "CameraState", "Playback")
KEY_VARIABLES = ("FPSNominal", "FPSEffective", "ShutterNominal", "ExposurePreferenceIsAngle", "ExposureIndex",
                 "NDFilterPosition", "WBCurrentKelvin", "WBCurrentColorComp")


def fields(doc: dict) -> dict[str, dict]:
    return {n: (x if isinstance(x, dict) else {"value": x}) for n, x in doc.get("variables", {}).items()}


def selectable(x: dict) -> set[int] | None:
    flags = x.get("properties")
    if not isinstance(flags, list):
        return None
    return {i for i, f in enumerate(flags) if isinstance(f, int) and f & 3 == 3}


def allowed(n: str, x: dict, enums: Enums) -> str:
    """What the camera lets a variable be now: its selectable choices, or its range; "ro" when it's read-only."""
    ok = selectable(x)
    if ok is not None:
        text = "{" + ", ".join(enums.label(n, i) or str(i) for i in sorted(ok)) + "}"
    elif "min" in x or "max" in x:
        text = f"{x.get('min')}…{x.get('max')}"
    else:
        text = ""
    return f"{text} ro".strip() if x.get("readonly") else text


def changes(old: dict, new: dict, enums: Enums, values: bool = True) -> list[str]:
    """Variables whose range, choices or read-only flag differ between two all.cgi reads (and, unless values=False,
    whose value does, meters and clocks aside), plus any that appeared or went."""
    out = []
    for n in sorted(set(old) | set(new)):
        a, b = old.get(n), new.get(n)
        if a is None or b is None:
            x = b if a is None else a
            out.append(f"  {'+' if a is None else '-'} {n} = {show(n, x.get('value'), enums)}  {allowed(n, x, enums)}")
            continue
        bits = []
        if values and a.get("value") != b.get("value") and not any(w in n for w in METERS):
            bits.append(f"{show(n, a.get('value'), enums)} → {show(n, b.get('value'), enums)}")
        if (a.get("min"), a.get("max")) != (b.get("min"), b.get("max")):
            bits.append(f"range {a.get('min')}…{a.get('max')} → {b.get('min')}…{b.get('max')}")
        sa, sb = selectable(a), selectable(b)
        if sa is not None and sb is not None and sa != sb:
            gained = [enums.label(n, i) or str(i) for i in sorted(sb - sa)]
            lost = [enums.label(n, i) or str(i) for i in sorted(sa - sb)]
            bits.append("choices" + (f" +{gained}" if gained else "") + (f" -{lost}" if lost else ""))
        if bool(a.get("readonly")) != bool(b.get("readonly")):
            bits.append("now read-only" if b.get("readonly") else "now writable")
        if bits:
            out.append(f"    {n}: " + "; ".join(bits))
    return out


def snaps(sess: Path) -> list[Path]:
    return sorted((sess / "snaps").glob("*.json")) if (sess / "snaps").exists() else []


def snap(sess: Path, label: str, values: bool = True) -> list[str]:
    """Saves the camera's variables as snaps/NNN-label.json; returns what changed since the last snap (or the
    session's start). With `watch` running its model is the source, so no extra all.cgi (each one is a new session
    and ~260 KB on an ALEXA Mini)."""
    live = sess / "model.json"
    if running(sess).get("watch") and live.exists() and time.time() - live.stat().st_mtime < 30:
        doc, size = json.loads(live.read_text()), 0
    else:
        doc, size = get_all((sess / "host").read_text())
    taken = snaps(sess)
    last = taken[-1] if taken else sess / "start.json"
    slug = re.sub(r"[^A-Za-z0-9.]+", "-", label).strip("-")[:60] or "snap"
    path = sess / "snaps" / f"{len(taken) + 1:03d}-{slug}.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps({"label": label, "t": time.time(), **doc}, sort_keys=True))
    event(sess, {"kind": "snap", "file": path.name, "label": label, "bytes": size, "id": doc.get("id")})
    old = fields(json.loads(last.read_text())) if last.exists() else {}
    return changes(old, fields(doc), load_enums(sess), values=values)


def cmd_snap(a) -> int:
    sess = session()
    try:
        lines = snap(sess, a.label)
    except Exception as e:
        print(f"snap failed ({type(e).__name__}: {e})")
        return 1
    print(f"snap '{a.label}': {len(lines)} variables differ from the last read" + (":" if lines else ""))
    if lines:
        print("\n".join(lines))
    return 0


def cmd_ranges(a) -> int:
    sess = session()
    enums = load_enums(sess)
    reads = [("start", fields(json.loads((sess / "start.json").read_text())))] if (sess / "start.json").exists() else []
    for p in snaps(sess):
        doc = json.loads(p.read_text())
        reads.append((doc.get("label") or p.stem, fields(doc)))
    if not reads:
        print("nothing read yet: run `arri.py go HOST`, then `arri.py snap LABEL` after each mode change")
        return 1
    names = list(a.names)
    if not names:
        every = sorted(set().union(*(set(r) for _, r in reads)))
        moved = [n for n in every if len({allowed(n, r[n], enums) for _, r in reads if n in r}) > 1]
        names = [n for n in KEY_VARIABLES if any(n in r for _, r in reads)] + [n for n in moved if n not in KEY_VARIABLES]
    width = max(len(label) for label, _ in reads)
    lines = [f"# Ranges per snap: {sess.name}", "", "Value, then what the camera allowed at that moment.", ""]
    for n in names:
        lines += [f"## {n}", "", "```"]
        for label, r in reads:
            x = r.get(n)
            lines.append(f"{label:<{width}}  " + (f"{show(n, x.get('value'), enums)}  {allowed(n, x, enums)}" if x else "—"))
        lines += ["```", ""]
    (sess / "ranges.md").write_text("\n".join(lines))
    print("\n".join(lines))
    print(f"→ {sess / 'ranges.md'}")
    return 0


# ----------------------------------------------------------------------------------------------------------- proxy


def cmd_proxy(a) -> int:
    sess = session()
    if a.detach:
        return detach(sess, "proxy", ["proxy", a.host, "--port", str(a.port)])
    from aiohttp import ClientSession, ClientTimeout, web

    target = base(a.host)
    (sess / "proxy.pid").write_text(str(os.getpid()))
    keep_awake(os.getpid())

    async def handle(request: web.Request) -> web.StreamResponse:
        body = await request.read()
        headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "accept-encoding", "content-length")}
        t = time.time()
        async with ClientSession(timeout=ClientTimeout(total=None, sock_read=90)) as cs:
            async with cs.request(request.method, target + request.path_qs, data=body, headers=headers) as r:
                data = await r.read()
                out = {k: v for k, v in r.headers.items()
                       if k.lower() not in ("content-length", "content-encoding", "transfer-encoding", "connection")}
                text = data.decode("utf-8", "replace")
                rec = {"kind": "proxy", "method": request.method, "path": request.path_qs, "status": r.status,
                       "bytes": len(data), "ms": int((time.time() - t) * 1000),
                       "request": body.decode("utf-8", "replace")[:4000] if body else ""}
                if "json" in r.headers.get("Content-Type", "") or request.path.endswith(".cgi"):
                    rec["response"] = text[:8000] if request.path != "/all.cgi" else f"<{len(data)} bytes>"
                event(sess, rec)
                if request.path != "/update.cgi" or len(data) > 2:
                    print(f"{stamp()} {request.method} {request.path_qs} {rec['request'][:200]} → {r.status} "
                          f"{len(data)}B {rec.get('response', '')[:200]}")
                return web.Response(body=data, status=r.status, headers=out)

    app = web.Application(client_max_size=64 * 1024 * 1024)
    app.router.add_route("*", "/{tail:.*}", handle)
    print(f"proxy for {target} on http://localhost:{a.port}/ (log: {sess}/events.jsonl)")
    web.run_app(app, port=a.port, print=None)
    return 0


# ------------------------------------------------------------------------------------------------------------ pokes


def parse_value(text: str):
    if text in ("true", "false"):
        return text == "true"
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        return text


def logged(kind: str, rec: dict) -> None:
    try:
        event(session(), {"kind": kind, **rec})
    except SystemExit:
        pass


def cmd_set(a) -> int:
    if NEVER.search(a.pair):
        print(f"refused, never sent ({NEVER.search(a.pair).group(0)}): {a.pair}")
        return 1
    name, _, raw = a.pair.partition("=")
    body = {name: parse_value(raw)}
    r = http().post(f"{base(a.host)}/set.cgi", json=body, timeout=8)
    print(f"set {body} → {r.status_code} {r.text[:300]}")
    logged("set", {"body": body, "status": r.status_code, "response": r.text[:1000]})
    return 0 if r.ok and '"result": 1' in r.text.replace('"result":1', '"result": 1') else 1


def cmd_call(a) -> int:
    s = http()
    saved = CURRENT / "all.cgi.json"
    doc = json.loads(saved.read_text()) if saved.exists() else get_all(a.host, s)[0]  # the IDs don't change
    cmds = doc.get("commands", {})
    cid = a.command if a.command in cmds else next((k for k, n in sorted(cmds.items()) if n == a.command), None)
    if not cid:
        print(f"no command {a.command}; the camera has: {', '.join(sorted(set(cmds.values())))}")
        return 1
    asked = f"{a.command} {cmds.get(cid, '')} {a.json or ''}"
    if NEVER.search(asked):
        print(f"refused, never sent ({NEVER.search(asked).group(0)}): {asked.strip()}")
        return 1
    body = {"command": cid, "set": json.loads(a.json) if a.json else {}}
    r = s.post(f"{base(a.host)}/call.cgi", json=body, timeout=8)
    print(f"call {cmds[cid]} {body} → {r.status_code} {r.text[:300]}")
    logged("call", {"name": cmds[cid], "body": body, "status": r.status_code, "response": r.text[:1000]})
    return 0


# Each control Tiles drives, written once through set.cgi and put back: what the camera answers, how long until the
# change comes back on its own session, and what else moved with it. Then two writes it should refuse, for the
# refusal's shape. Nothing that records, plays, loads, formats, reloads or renames.
EXERCISE = ("ExposureIndex", "NDFilterPosition", "WBCurrentKelvin", "WBCurrentColorComp", "ShutterNominal",
            "ExposurePreferenceIsAngle", "ExposureTimeNominal", "FPSNominal", "LensSqueezeFactor",
            "SDIFramelinesAreOn", "EVFFramelinesAreOn", "MonitorFramelineIsOn", "SDIExposureToolIsOn",
            "EVFExposureToolIsOn", "SDIExposureTool", "SDIPeakingIsOn", "EVFPeakingIsOn", "SDIStatusInfo1IsOn",
            "EVFStatusInfo1IsOn", "SDI1PathProcessing", "EVFMonitorPathProcessing", "SDIAnamorphicDesqueezeIsActive",
            "EVFMonitorAnamorphicDesqueezeIsActive", "SDI1TestImageIsActive", "EVFTestImageIsActive")


def trial_value(n: str, x: dict):
    """A different value the camera allows now, close to the current one."""
    v, t = x.get("value"), x.get("type")
    if t == "bool":
        return not v
    ok = selectable(x)
    if ok is not None:
        later = [i for i in sorted(ok) if i > v] or [i for i in sorted(ok) if i != v]
        return later[0] if later else None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        lo, hi = x.get("min", -1e9), x.get("max", 1e9)
        steps = {"WBCurrentKelvin": 300, "WBCurrentColorComp": 1.0, "ShutterNominal": -90, "FPSNominal": 1,
                 "ExposureTimeNominal": 2}
        step = steps.get(n, 1)
        for cand in (round(v + step, 3), round(v - step, 3)):
            if lo <= cand <= hi:
                return cand
    return None


def cmd_exercise(a) -> int:
    sess = session()
    cam = Session(a.host, sess)
    cam.connect()
    out = sess / "exercise.jsonl"
    names = a.only or list(EXERCISE)
    for n in [n for n in names if NEVER.search(n)]:
        print(f"refused, never sent ({NEVER.search(n).group(0)}): {n}")
    names = [n for n in names if not NEVER.search(n)]
    print(f"session {cam.id}; {len(names)} controls; results → {out}")

    def write(n, value) -> dict:
        t = time.time()
        r = cam.s.post(f"{base(a.host)}/set.cgi", json={n: value}, timeout=5)
        rec = {"status": r.status_code, "ms": int((time.time() - t) * 1000), "response": r.text[:500]}
        seen, moved, t1 = None, {}, time.time()
        while time.time() - t1 < 4:
            for k, (old, new) in cam.poll().items():
                if k == n:
                    seen = new
                elif not any(k.startswith(p) for p in NOISY):
                    moved[k] = [old, new]
            if seen is not None and seen == value or (isinstance(seen, float) and isinstance(value, (int, float))
                                                       and abs(seen - value) < 1e-3):
                break
        rec.update({"confirmed": seen == value or (isinstance(seen, (int, float)) and isinstance(value, (int, float))
                                                   and abs(seen - value) < 1e-3),
                    "seen": seen, "confirm_ms": int((time.time() - t) * 1000), "also": moved})
        return rec

    for n in names:
        x = cam.model.get(n)
        if not x:
            print(f"  {n}: not on this camera")
            continue
        if x.get("readonly"):
            print(f"  {n}: read-only now")
            continue
        was, to = x.get("value"), trial_value(n, x)
        if to is None:
            print(f"  {n}: no other value allowed now")
            continue
        go_ = write(n, to)
        back = write(n, was)
        rec = {"name": n, "type": x.get("type"), "from": was, "to": to, "set": go_, "restore": back, "t": time.time()}
        with open(out, "a") as f:
            f.write(json.dumps(rec) + "\n")
        print(f"  {n}: {was} → {to}  {go_['response'].strip()[:40]}  seen {go_['seen']} in {go_['confirm_ms']} ms"
              f"{'  also ' + ', '.join(go_['also']) if go_['also'] else ''};  back {'ok' if back['confirmed'] else back}")
    # Refusals: past the range, and a read-only variable.
    for n, value in (("FPSNominal", (cam.model.get("FPSNominal", {}).get("max") or 50) + 100),
                     ("FPSEffective", 25)):
        r = cam.s.post(f"{base(a.host)}/set.cgi", json={n: value}, timeout=5)
        with open(out, "a") as f:
            f.write(json.dumps({"name": n, "refusal": True, "to": value, "status": r.status_code,
                                "response": r.text[:500], "t": time.time()}) + "\n")
        print(f"  refusal {n}={value}: {r.status_code} {r.text.strip()[:120]}")
    return 0


def cmd_raw(a) -> int:
    asked = f"{a.path} {a.json or ''}"
    if NEVER.search(asked):
        print(f"refused, never sent ({NEVER.search(asked).group(0)}): {asked.strip()}")
        return 1
    s, url = http(), f"{base(a.host)}/{a.path.lstrip('/')}"
    r = s.post(url, json=json.loads(a.json), timeout=45) if a.json else s.get(url, timeout=45)
    print(f"{r.status_code} {len(r.content)}B {dict(r.headers)}\n{r.text[:4000]}")
    logged("raw", {"path": a.path, "request": a.json, "status": r.status_code, "response": r.text[:4000]})
    return 0


# ----------------------------------------------------------------------------------------------------------- status


def running(sess: Path) -> dict[str, int]:
    out = {}
    for name in ("watch", "proxy"):
        p = sess / f"{name}.pid"
        if p.exists():
            pid = int(p.read_text() or 0)
            try:
                os.kill(pid, 0)
                out[name] = pid
            except Exception:
                p.unlink(missing_ok=True)
    return out


def cmd_status(a) -> int:
    sess = session()
    evs = events(sess)
    print(f"{sess}\n  running: {running(sess) or 'nothing'}\n  {len(evs)} events, "
          f"{sum(1 for e in evs if e.get('kind') == 'change')} changes, {sum(1 for e in evs if e.get('kind') == 'note')} notes")
    traffic = sum(e.get("bytes", 0) for e in evs if e.get("kind") in ("update", "poll", "proxy"))
    span = (evs[-1]["t"] - evs[0]["t"]) if len(evs) > 1 else 0
    if span:
        print(f"  {traffic} bytes read over {span:.0f}s: {traffic * 8 / span / 1000:.1f} kbit/s")
    return 0


def cmd_stop(a) -> int:
    sess = session()
    for name, pid in running(sess).items():
        os.kill(pid, signal.SIGTERM)
        print(f"stopped {name} ({pid})")
        (sess / f"{name}.pid").unlink(missing_ok=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("find"); p.add_argument("--port", type=int, default=80); p.set_defaults(fn=cmd_find)
    p = sub.add_parser("go"); p.add_argument("host"); p.add_argument("--no-mirror", action="store_true")
    p.set_defaults(fn=cmd_go)
    p = sub.add_parser("watch"); p.add_argument("host"); p.add_argument("--detach", action="store_true")
    p.add_argument("--new", action="store_true", help="start a new session instead of adding to the current one")
    p.set_defaults(fn=cmd_watch)
    p = sub.add_parser("proxy"); p.add_argument("host"); p.add_argument("--port", type=int, default=8081)
    p.add_argument("--detach", action="store_true"); p.set_defaults(fn=cmd_proxy)
    p = sub.add_parser("note"); p.add_argument("text"); p.add_argument("--no-snap", action="store_true")
    p.set_defaults(fn=cmd_note)
    p = sub.add_parser("snap"); p.add_argument("label"); p.set_defaults(fn=cmd_snap)
    p = sub.add_parser("ranges"); p.add_argument("names", nargs="*"); p.set_defaults(fn=cmd_ranges)
    p = sub.add_parser("diff"); p.add_argument("a", nargs="?"); p.add_argument("b", nargs="?"); p.set_defaults(fn=cmd_diff)
    p = sub.add_parser("set"); p.add_argument("host"); p.add_argument("pair"); p.set_defaults(fn=cmd_set)
    p = sub.add_parser("call"); p.add_argument("host"); p.add_argument("command"); p.add_argument("json", nargs="?")
    p.set_defaults(fn=cmd_call)
    p = sub.add_parser("exercise"); p.add_argument("host"); p.add_argument("--only", nargs="+")
    p.set_defaults(fn=cmd_exercise)
    p = sub.add_parser("raw"); p.add_argument("host"); p.add_argument("path"); p.add_argument("json", nargs="?")
    p.set_defaults(fn=cmd_raw)
    p = sub.add_parser("status"); p.set_defaults(fn=cmd_status)
    p = sub.add_parser("stop"); p.set_defaults(fn=cmd_stop)
    p = sub.add_parser("report"); p.add_argument("dir", nargs="?"); p.set_defaults(fn=cmd_report)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
