#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["aiohttp>=3.9"]
# ///
"""A fake ARRI Web Remote (ALEXA Mini by default), for dry-running arri.py and Tiles without a camera.

It serves what the Swift backend expects, in the shapes the real cameras use:
GET /all.cgi (id, variables with value/type/min/max/readonly/properties, commands by opaque ID), GET /update.cgi?id=N
(a long poll), GET /js/all-dg.min.js (each enum's tokens and English labels, with an ETag), POST /set.cgi
({name: value} → {"result": 1}), POST /call.cgi ({"command": id, "set": {…}} → {"result": n}). The variable names
beyond the verified ones (CameraState, Timecode, the per-output switches…) are the backend's guesses, not the camera's.

  mock_alexa.py [--port 18081] [--model "ALEXA Mini" | "ALEXA Mini LF" | "ALEXA 35"] [--update sessions|missing]
                [--no-script]
  GET /_mock/body?name=WBCurrentKelvin&value=3200   a change made on the camera body
"""
import argparse
import asyncio
import json
import time

from aiohttp import web

STATE: dict = {"id": 1, "changes": [], "variables": {}, "commands": {}, "script": "", "cond": None, "sessions": {},
                "next_session": 0}

EIS_MINI = [160, 200, 250, 320, 400, 500, 640, 800, 1000, 1280, 1600, 2000, 2560, 3200]
SPEEDS = ("REV_512 REV_256 REV_128 REV_64 REV_32 REV_16 REV_8 REV_4 REV_2 REV_1 PAUSE "
          "FWD_1 FWD_2 FWD_4 FWD_8 FWD_16 FWD_32 FWD_64 FWD_128 FWD_256 FWD_512").split()
LETTERS = [chr(c) for c in range(65, 91)]


def body(model: str) -> dict:
    """Per-model lists (ARRI's published ones): EI, ND filters, the fastest sensor rate, the outputs."""
    is35, lf = "35" in model, "LF" in model.upper()
    eis = EIS_MINI + ([4000, 5120, 6400] if is35 else [])
    if is35:
        nd = [("CLEAR", "ND  -"), ("ZERO_POINT_SIX", "ND 0.6"), ("ONE_POINT_TWO", "ND 1.2"), ("ONE_POINT_EIGHT", "ND 1.8"),
              ("TWO_POINT_FOUR", "ND 2.4")]
    else:
        nd = [("CLEAR", "ND  -"), ("ZERO_POINT_SIX", "ND 0.6"), ("ONE_POINT_TWO", "ND 1.2"),
              ("TWO_POINT_ONE", "ND 1.8" if lf else "ND 2.1")]
    fps_max = 120 if is35 else 90 if lf else 200
    outputs = ["Sdi1", "Sdi2", "Evf"] + (["Mon"] if is35 or lf else [])
    modes = {"ALEXA 35": ["4.6K 3:2 Open Gate", "4.6K 16:9", "4K 16:9", "3.3K 6:5"],
             "ALEXA Mini LF": ["LF Open Gate", "LF 16:9", "LF 2.39:1", "S35 2.8K 16:9"]}.get(
        model, ["3.4K Open Gate", "4:3 2.8K", "16:9 HD", "16:9 3.2K", "4K UHD"])
    return {"eis": eis, "nd": nd, "fps_max": fps_max, "outputs": outputs, "modes": modes}


def build(model: str) -> None:
    b = body(model)

    def enumint(value, count, flags=None, ro=False):
        return {"value": value, "type": "enumint", "min": 0, "max": count - 1,
                "properties": flags or [3] * count, "readonly": 1 if ro else 0}

    def num(value, lo, hi, kind="float", ro=False):
        return {"value": value, "type": kind, "min": lo, "max": hi, "readonly": 1 if ro else 0}

    def flag(value, ro=False):
        return {"value": value, "type": "bool", "readonly": 1 if ro else 0}

    def text(value):
        return {"value": value, "type": "string", "readonly": 1}

    def ro_int(value):
        return {"value": value, "type": "int", "readonly": 1}

    v = {
        "SystemCameraType": text(model), "SystemCameraSerial": text("K1.71234"),
        # Each body's latest SUP: the original Mini stops at 6.1.2 (2022); 7.x is the Mini LF's.
        "SystemSupVersion": text({"ALEXA Mini LF": "SUP 7.3", "ALEXA 35": "SUP 6.2"}.get(model, "SUP 6.1.2")),
        "CameraState": enumint(0, 3, ro=True), "Timecode": text("14:22:01:00"),
        # The camera's own screen: an ALEXA Mini's PlayBackPrepare puts it on its playback page (2), and PlayBackEnd
        # leaves it there ("No clip selected") until the page writes NORMAL (0), as its own exit does.
        "GuiMode": enumint(0, 4),
        "ClipName": text("A004C012_261022_R1AB"), "ClipNameReelCount": num(4, 1, 999, "int"),
        "SystemCameraIndex": enumint(0, 26), "ExposureIndex": enumint(b["eis"].index(800), len(b["eis"])),
        "ActExposureIndexIso": ro_int(800),
        "NDFilterPosition": enumint(0, len(b["nd"])), "NDFilterPositionEffective": enumint(0, len(b["nd"]), ro=True),
        "WBCurrentKelvin": num(5600, 2000, 11000), "WBCurrentColorComp": num(0, -16, 16),
        "ShutterNominal": num(172.8, 5, 356), "ExposurePreferenceIsAngle": flag(True),
        "FPSNominal": num(24, 0.75, b["fps_max"]), "FPSEffective": num(24, 0.75, b["fps_max"], ro=True),
        "SensorMode": enumint(0, len(b["modes"])), "RecCodec": enumint(0, 3, flags=[3, 3, 1]),
        "LookFile": enumint(0, 3), "TestImage": enumint(0, 2),
        "LensIris": ro_int(3000), "LensModelName": text("Signature Prime 47mm"),
        "BatteryVoltage": num(15.2, 0, 36, ro=True), "RemainingRecTime": ro_int(38),
        "PlaybackSpeedEnum": enumint(10, 21), "PlaybackSpeed": ro_int(0), "_PlaybackControlsAreActive": flag(False),
        "PlaybackClipIndex": ro_int(-1), "ClipCountCardA": ro_int(11), "ClipCountCardB": ro_int(0),
        "ClipTableCardAVersion": ro_int(3), "ClipTableCardBVersion": ro_int(1),
    }
    for out in b["outputs"]:
        v[f"LookSwitch{out}"] = flag(True)
        v[f"Framelines{out}"] = flag(out != "Sdi1")
        v[f"ExposureTool{out}"] = enumint(0, 3)
        v[f"FocusTool{out}"] = enumint(0, 2)
        v[f"Overlays{out}"] = flag(out != "Sdi1")
        v[f"ZebraLevel{out}"] = num(70, 0, 100, "int")
    STATE["variables"] = v
    STATE["commands"] = {
        "_mockRecordingStart": "RecordingStart", "_mockRecordingStop": "RecordingStop",
        "_EeUkIwIBEeSgptigTra4vQ": "PlayBackPrepare", "_7q_F4cHREeStK8NH8ZPGbQ": "PlayBackGo",
        "__WRr68HREeStK8NH8ZPGbQ": "PlayBackStop", "_cCCFscHSEeStK8NH8ZPGbQ": "PlayBackEnd",
        "_1cxyMfk0EeaWP7LWENrtWw": "PlayBackEnd",  # the Mini's LOCK button's, which sorts first
        "_BJbzscJjEeSbpa7lQ8OAJw": "PlayBackSkipClip", "_H_V7l8JjEeSbpa7lQ8OAJw": "PlayBackSkipClip",
        "_mockAutoWhiteBalance": "AutoWhiteBalance",
    }

    declared = {"ExposureIndex": "ExposureIndex", "NDFilterPosition": "NDFilter",
                "NDFilterPositionEffective": "NDFilter", "PlaybackSpeedEnum": "PlaybackSpeed",
                "SensorMode": "SensorMode", "RecCodec": "RecCodec", "LookFile": "LookFile",
                "SystemCameraIndex": "CameraIndex", "CameraState": "CameraState", "TestImage": "TestImage",
                "GuiMode": "GuiMode"}
    for out in b["outputs"]:
        declared[f"ExposureTool{out}"] = "ExposureTool"
        declared[f"FocusTool{out}"] = "FocusTool"
    enums = {
        "ExposureIndex": [f"EI_{e}" for e in b["eis"]], "NDFilter": [t for t, _ in b["nd"]], "PlaybackSpeed": SPEEDS,
        "SensorMode": [f"MODE_{i}" for i in range(len(b["modes"]))], "RecCodec": ["ARRIRAW", "PRORES_4444", "PRORES_422_HQ"],
        "LookFile": ["L0", "L1", "L2"], "CameraIndex": LETTERS, "CameraState": ["STANDBY", "RECORDING", "PLAYBACK"],
        "ExposureTool": ["OFF", "FALSE_COLOR", "ZEBRA"], "FocusTool": ["OFF", "PEAKING"], "TestImage": ["OFF", "COLOR_BARS"],
        "GuiMode": ["NORMAL", "OVERLAY_MENU", "PLAYBACK", "ERASE"],
    }
    labels = {f"ExposureIndex_EI_{e}": str(e) for e in b["eis"]}
    labels.update({f"NDFilter_{t}": label for t, label in b["nd"]})
    labels.update({f"SensorMode_MODE_{i}": m for i, m in enumerate(b["modes"])})
    labels.update({"RecCodec_ARRIRAW": "ARRIRAW", "RecCodec_PRORES_4444": "ProRes 4444",
                   "RecCodec_PRORES_422_HQ": "ProRes 422 HQ", "LookFile_L0": "ARRI 709",
                   "LookFile_L1": "Toldwell Show Look", "LookFile_L2": "Night Int",
                   "CameraState_STANDBY": "Standby", "CameraState_RECORDING": "Recording",
                   "CameraState_PLAYBACK": "Playback", "ExposureTool_OFF": "Off", "ExposureTool_FALSE_COLOR": "False Color",
                   "ExposureTool_ZEBRA": "Zebra", "FocusTool_OFF": "Off", "FocusTool_PEAKING": "Peaking",
                   "TestImage_OFF": "Off", "TestImage_COLOR_BARS": "Color Bars", "GuiMode_NORMAL": "NORMAL",
                   "GuiMode_OVERLAY_MENU": "OVERLAY", "GuiMode_PLAYBACK": "PLAY", "GuiMode_ERASE": "ERASE"})
    labels.update({f"CameraIndex_{c}": c for c in LETTERS})
    labels.update({f"PlaybackSpeed_{s}": (s.split("_")[1] + "x") for s in SPEEDS if s not in ("PAUSE", "FWD_1", "REV_1")})
    lines = ["var b = {};"]
    lines += [f'b.{n}={{name:"{n}",value:"?",type:"{t}"}};' for n, t in declared.items()]
    lines.append("var enums = {" + ",".join(
        f'{t}:"{" ".join(tokens)}".split(" ")' if i % 2 else f"{t}:{json.dumps(tokens)}"
        for i, (t, tokens) in enumerate(enums.items())) + "};")
    lines.append("var a = {en:{}};")
    lines += [f'a.en.ENUM_{k}={json.dumps(label)};' for k, label in labels.items()]
    STATE["script"] = "\n".join(lines) + "\n"


def change(name: str, value) -> None:
    STATE["variables"][name]["value"] = value
    STATE["id"] += 1
    STATE["changes"].append((STATE["id"], name))
    del STATE["changes"][:-500]
    for pending in STATE["sessions"].values():
        pending.add(name)
    STATE["cond"].notify_all()


async def notify(name: str, value) -> None:
    async with STATE["cond"]:
        change(name, value)


INDEX = """<!doctype html><title>ALEXA Web Remote (mock)</title>
<script src="/js/all-dg.min.js"></script>
<script src="/js/remote.js"></script>
<body style="font: 14px -apple-system; background: #111; color: #ddd"><h1>ALEXA (mock)</h1><pre id=v></pre></body>"""

REMOTE_JS = """(async function () {
  let doc = await (await fetch('/all.cgi')).json(), id = doc.id;
  const show = () => document.getElementById('v').textContent = JSON.stringify(
    Object.fromEntries(Object.entries(doc.variables).map(([k, v]) => [k, v.value])), null, 1);
  show();
  for (;;) {
    try {
      const u = await (await fetch('/update.cgi?id=' + id)).json();
      for (const [k, v] of Object.entries(u.variables || {})) doc.variables[k] = Object.assign(doc.variables[k] || {}, v);
      id = u.id; show();
    } catch (e) { await new Promise(r => setTimeout(r, 1000)); }
  }
})();"""


async def all_cgi(_):
    # As an ALEXA Mini: each all.cgi opens a session (a few slots, the oldest given up), and its id is what
    # update.cgi?id= is asked with; the camera keeps what changed per session.
    sid = STATE["next_session"]
    STATE["next_session"] = (sid + 1) % 4
    STATE["sessions"][sid] = set()
    return web.json_response({"id": sid, "variables": STATE["variables"], "commands": STATE["commands"]})


async def script(request):
    if not ARGS.script:
        return web.json_response({"ERROR": "not found"}, status=404)
    if request.headers.get("If-None-Match") == '"mock-1"':
        return web.Response(status=304, headers={"ETag": '"mock-1"'})
    return web.Response(text=STATE["script"], content_type="application/javascript", headers={"ETag": '"mock-1"'})


async def update(request):
    if ARGS.update == "missing":
        return web.json_response({"ERROR": "not found"}, status=404)
    sid = int(request.query.get("id", "-1") or -1)
    if sid not in STATE["sessions"]:
        return web.json_response({"ERROR": "Invalid id"})
    deadline = time.monotonic() + 2
    async with STATE["cond"]:
        while not STATE["sessions"].get(sid) and time.monotonic() < deadline:
            try:
                await asyncio.wait_for(STATE["cond"].wait(), deadline - time.monotonic())
            except asyncio.TimeoutError:
                break
    pending = STATE["sessions"].get(sid, set())
    changed = {n: STATE["variables"][n] for n in sorted(pending)}
    pending.clear()
    return web.json_response({"id": sid, "variables": changed})


def check(name, value):
    v = STATE["variables"].get(name)
    if v is None:
        return f"Unknown {name}"
    if v.get("readonly"):
        return f"{name} is read only"
    if v["type"] == "bool":
        return None if isinstance(value, bool) else f"{name} needs true or false"
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return f"{name} needs a number"
    if not v.get("min", value) <= value <= v.get("max", value):
        return f"{name} out of range"
    if v["type"] == "enumint" and not (0 <= int(value) < len(v["properties"]) and v["properties"][int(value)] & 3 == 3):
        return f"{name} {value} is disabled"
    return None


async def set_cgi(request):
    data = await request.json()
    for name, value in data.items():
        if (why := check(name, value)):
            print(f"set refused: {why}")
            return web.json_response({"result": 0, "error": why})
    async with STATE["cond"]:
        for name, value in data.items():
            change(name, value)
    print(f"set {data}")
    return web.json_response({"result": 1})


async def rolling():
    """While recording: timecode by the second (rec run), media down a minute every 20 seconds."""
    await asyncio.sleep(0.5)
    seconds = 0
    while STATE["variables"]["CameraState"]["value"] == 1:
        await asyncio.sleep(1)
        seconds += 1
        h, m, s = (int(x) for x in STATE["variables"]["Timecode"]["value"].split(":")[:3])
        total = h * 3600 + m * 60 + s + 1
        await notify("Timecode", f"{total // 3600 % 24:02d}:{total // 60 % 60:02d}:{total % 60:02d}:00")
        if seconds % 20 == 0:
            await notify("RemainingRecTime", max(0, STATE["variables"]["RemainingRecTime"]["value"] - 1))


async def call_cgi(request):
    data = await request.json()
    name = STATE["commands"].get(data.get("command", ""))
    print(f"call {name or '?'} {data}")
    if not name:
        return web.json_response({"result": -1, "error": "Unknown command ID"})
    v = STATE["variables"]

    async def later(seconds, n, value):
        await asyncio.sleep(seconds)
        await notify(n, value)

    if name == "RecordingStart" and v["CameraState"]["value"] == 0:
        asyncio.create_task(later(0.4, "CameraState", 1))
        asyncio.create_task(rolling())
    elif name == "RecordingStop" and v["CameraState"]["value"] == 1:
        asyncio.create_task(later(0.4, "CameraState", 0))
        n = int(v["ClipName"]["value"][5:8]) + 1
        asyncio.create_task(later(0.5, "ClipName", f"A004C{n:03d}_261022_R1AB"))
        asyncio.create_task(later(0.5, "ClipCountCardA", v["ClipCountCardA"]["value"] + 1))
    elif name == "PlayBackPrepare":
        await notify("PlaybackClipIndex", 0)
        await notify("GuiMode", 2)
    elif name == "PlayBackGo":
        await notify("PlaybackSpeedEnum", 11)
    elif name == "PlayBackStop":
        await notify("PlaybackSpeedEnum", 10)
    elif name == "PlayBackEnd":
        await notify("PlaybackSpeedEnum", 10)
        await notify("PlaybackClipIndex", -1)
    elif name == "PlayBackSkipClip":
        i = v["PlaybackClipIndex"]["value"]
        await notify("PlaybackClipIndex", i + 1 if data["command"] == "_H_V7l8JjEeSbpa7lQ8OAJw" else max(i - 1, 0))
    elif name == "AutoWhiteBalance":
        asyncio.create_task(later(1.0, "WBCurrentKelvin", 4870))
    return web.json_response({"result": 0})


async def body_change(request):
    name, raw = request.query["name"], request.query["value"]
    value = json.loads(raw) if raw[:1] in "-0123456789tf[{" else raw
    await notify(name, value)
    return web.json_response({"ok": True, "id": STATE["id"]})


async def start(app):
    STATE["cond"] = asyncio.Condition()


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18081)
    ap.add_argument("--model", default="ALEXA Mini")
    ap.add_argument("--update", choices=["sessions", "missing"], default="sessions")
    ap.add_argument("--no-script", dest="script", action="store_false")
    ARGS = ap.parse_args()
    build(ARGS.model)
    app = web.Application()
    app.on_startup.append(start)
    app.router.add_get("/", lambda _: web.Response(text=INDEX, content_type="text/html"))
    app.router.add_get("/index.html", lambda _: web.Response(text=INDEX, content_type="text/html"))
    app.router.add_get("/js/remote.js", lambda _: web.Response(text=REMOTE_JS, content_type="application/javascript"))
    app.router.add_get("/all.cgi", all_cgi)
    app.router.add_get("/js/all-dg.min.js", script)
    app.router.add_get("/update.cgi", update)
    app.router.add_post("/set.cgi", set_cgi)
    app.router.add_post("/call.cgi", call_cgi)
    app.router.add_get("/wait.cgi", lambda _: web.json_response({"result": 0}))
    app.router.add_get("/_mock/body", body_change)
    print(f"mock {ARGS.model} Web Remote on :{ARGS.port} (update {ARGS.update}, script {'on' if ARGS.script else 'off'})")
    web.run_app(app, port=ARGS.port, print=None)


ARGS = None

if __name__ == "__main__":
    main()
