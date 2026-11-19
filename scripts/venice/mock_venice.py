#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["aiohttp>=3.9", "msgpack>=1.0"]
# ///
"""A fake VENICE Web Remote, for dry-running venice.py without a camera.

Its /linear WebSocket speaks Sony Savona MessagePack-RPC (requests [0,id,method,params], responses [1,id,error,result],
notifications [2,name,data]). By default it behaves like the real VENICE 2 (--savona-auth
venice2: one client, the page's SHA-256 login, silence for the wrong shape, batched frames, menu values; docs/venice.md);
the older guesses (nonce/digest, basic) stay behind --savona-auth. Its browser WebSocket protocol is INVENTED: JSON over a WebSocket behind HTTP Digest, with {name, value} records. Only the shape
matters: pages that load scripts (one of them dynamically), a script that opens a WebSocket, a state dump on
connect, a timecode and a battery value that change by themselves, delayed REC feedback, and /_mock/body?name=…&value=…
to fake a change made on the camera body.

  mock_venice.py [--port 18080] [--user admin] [--password test1234] [--no-ws-auth]
"""
import argparse
import asyncio
import base64
import hashlib
import json
import os
import re
import time

from aiohttp import WSMsgType, web

REALM = "VENICE2 mock"
NONCES: set[str] = set()
LOG: list[dict] = []
SOCKETS: set = set()
STATE = {
    "Camera.Shutter.Mode": "Angle", "Camera.Shutter.Value": "180.0", "Camera.NDFilter.Value": 1,
    "Camera.Gain.ExposureIndex.Value": "800", "Camera.Gain.ISOValue": 0,
    "Camera.WhiteBalance.ColorTemperature.Value.Venice": 5600, "Camera.WhiteBalance.Tint.Value": 0,
    "Camera.SlowAndQuickMotion.Enabled": False, "Clip.Recorder": "Stop", "Clip.Mediabox.TimeCode.Value": "01:00:00:00",
    "System.Battery.Active.Remain.Voltage": 15.6, "System.CameraID": "A", "Output.SensorFlip.Enabled": False,
    "Output.Monitor.FalseColor.Enabled": False, "Output.Desqueeze.Ratio": "1.0x",
    "P.System.Menu.WebInfo.Media.AXSA": "62%", "Assign1_Name": "Sensor Flip", "Assign2_Name": "Color Bars",
}
TICK = {"frame": 0}

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>VENICE 2 Web Remote (mock)</title>
<link rel="stylesheet" href="css/rm.css"><script src="js/lib/util.min.js"></script>
<script src="js/rm.js?v=3.1"></script></head><body><div id="APP"><header><img src="img/logo.svg" alt="">
<span id="LABEL_MODEL">VENICE 2</span></header><main id="CAMERA_SCREEN"></main></div></body></html>"""

UTIL_JS = "/* util */ var Util={fmt:function(v){return String(v)},lang:'en'};"

RM_JS = r"""
var PROPS = {shutter: "Camera.Shutter.Value", nd: "Camera.NDFilter.Value", ei: "Camera.Gain.ExposureIndex.Value",
  wb: "Camera.WhiteBalance.ColorTemperature.Value.Venice", rec: "Clip.Recorder", tc: "Clip.Mediabox.TimeCode.Value"};
var ND_OPTIONS = ["Clear", "0.3", "0.6", "0.9", "1.2", "1.5", "1.8", "2.1", "2.4"];
var State = {}, RM = {};
function send(o) { RM.ws.send(JSON.stringify(o)); }
function set(name, value) { send({cmd: "set", name: name, value: value}); }
function key(k) { send({cmd: "key", key: k}); }
function el(tag, attrs, text) { var e = document.createElement(tag); for (var k in attrs) e.setAttribute(k, attrs[k]);
  if (text) e.textContent = text; return e; }
function build() {
  var m = document.getElementById("CAMERA_SCREEN");
  var rec = el("button", {id: "BUTTON_REC_BUTTON"}, "REC"); rec.onclick = function () { key("Rec"); }; m.appendChild(rec);
  var nd = el("select", {id: "SELECT_ND_FILTER"});
  ND_OPTIONS.forEach(function (t, i) { nd.appendChild(el("option", {value: String(1 << i)}, t)); });
  nd.onchange = function () { set(PROPS.nd, parseInt(nd.value, 10)); }; m.appendChild(nd);
  var wb = el("input", {id: "INPUT_WB_KELVIN", type: "number", min: "2000", max: "15000", step: "10"});
  wb.onchange = function () { set(PROPS.wb, parseInt(wb.value, 10)); }; m.appendChild(wb);
  for (var i = 1; i <= 2; i++) (function (i) {
    var b = el("button", {id: "BUTTON_ASSIGN_" + i}, "Assign " + i); b.onclick = function () { key("Assign" + i); };
    m.appendChild(b); })(i);
  m.appendChild(el("span", {id: "LABEL_TC"}, ""));
}
function render() {
  document.getElementById("LABEL_TC").textContent = State[PROPS.tc] || "";
  document.getElementById("BUTTON_REC_BUTTON").className = State[PROPS.rec] === "Rec" ? "rec on" : "rec";
  document.getElementById("INPUT_WB_KELVIN").value = State[PROPS.wb];
}
function connect() {
  RM.ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
  RM.ws.onopen = function () { send({cmd: "subscribe", topics: ["Camera", "Clip", "System", "Output"]}); };
  RM.ws.onmessage = function (e) { var msg = JSON.parse(e.data);
    (msg.props || []).forEach(function (p) { State[p.name] = p.value; }); render(); };
}
document.addEventListener("DOMContentLoaded", function () {
  build();
  fetch("data/lang_en.json").then(function (r) { return r.json(); }).then(function (j) { RM.lang = j; connect(); });
});
"""


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


def challenge() -> str:
    n = os.urandom(16).hex()
    NONCES.add(n)
    return f'Digest realm="{REALM}", qop="auth", nonce="{n}", opaque="5ccc069c", algorithm=MD5'


def authorized(req, user: str, pw: str) -> bool:
    h = req.headers.get("Authorization", "")
    if not h.startswith("Digest "):
        return False
    parts = {k: (a or b) for k, a, b in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]*))', h[7:])}
    if parts.get("username") != user or parts.get("nonce") not in NONCES:
        return False
    ha1 = md5(f"{user}:{REALM}:{pw}")
    ha2 = md5(f"{req.method}:{parts.get('uri', '')}")
    if parts.get("qop"):
        want = md5(f"{ha1}:{parts['nonce']}:{parts.get('nc', '')}:{parts.get('cnonce', '')}:{parts['qop']}:{ha2}")
    else:
        want = md5(f"{ha1}:{parts['nonce']}:{ha2}")
    return parts.get("response") == want


async def broadcast(props: dict, kind: str = "notify"):
    msg = json.dumps({"type": kind, "props": [{"name": k, "value": v} for k, v in props.items()]})
    for ws in list(SOCKETS):
        try:
            await ws.send_str(msg)
        except Exception:
            SOCKETS.discard(ws)


async def ticker():
    import msgpack
    while True:
        await asyncio.sleep(1)
        TICK["frame"] += 24
        f = TICK["frame"]
        tc = f"01:{f // 1440 % 60:02d}:{f // 24 % 60:02d}:{f % 24:02d}"
        STATE["Clip.Mediabox.TimeCode.Value"] = tc
        SAVONA_PROPS["P.Clip.Mediabox.TimeCode.Value"] = tc
        await broadcast({"Clip.Mediabox.TimeCode.Value": tc})
        frame = [2, "Notify.Property.Value.Changed", [{"P.Clip.Mediabox.TimeCode.Value": tc}]]
        for s in list(LINEAR):
            try:
                await s.send_bytes(msgpack.packb(frame, use_bin_type=True))
            except Exception:
                LINEAR.discard(s)
        if f % 96 == 0:
            STATE["System.Battery.Active.Remain.Voltage"] = round(STATE["System.Battery.Active.Remain.Voltage"] - 0.1, 1)
            await broadcast({"System.Battery.Active.Remain.Voltage": STATE["System.Battery.Active.Remain.Voltage"]})


SAVONA_PROPS = {
    "Camera.Shutter.Mode": "Angle", "Camera.Shutter.Angle": "180.0", "Camera.Shutter.Speed": "1/48",
    "Camera.Gain.ExposureIndex.Value": "800EI", "Camera.Gain.ISOValue": 0,
    "Camera.NDFilter.Value": {"cam": 4}, "Camera.WhiteBalance.ColorTemperature.Value": 5600,
    "Camera.Iris.FValueFraction": {"cam": {"numerator": 560, "denominator": 100}},
    "Clip.Recorder": "Stop", "P.Clip.Mediabox.Status": "Standby", "P.Clip.Mediabox.TimeCode.Value": "01:00:00:00",
    "System.Battery.Active.Remain.Voltage": 15.6, "System.CameraID": "A",
    "Button.Assign": {"Assignable.1": ["Sensor Flip", "On"], "Assignable.2": ["Color Bars", "Off"]},
    "Output.Monitor.FalseColor.Enabled": False,
    "System.ModelName": "MPC-3628", "Clip.Mediabox.ClipName": "A005C003",
    "Clip.Mediabox.AllClipPosition": 2, "Clip.Mediabox.AllTotalClips": 3,
    "System.Menu.CamImagermode": "8.6K 3:2", "System.Menu.SxsOutputDeSqueeze": "Off",
    "System.Menu.MarkerSdiOnoff": "Off", "System.Menu.MarkerMonitorOnoff": "On", "System.Menu.MarkerVfOnoff": "On",
    "Output.Video.SDI.LUT.Value": "Log", "Output.Video.ViewFinder.LUT.Value": "s709",
    "System.Menu.MonitorOsdDisplayInfoOnoff": "On", "System.Menu.ColorBar": "Off",
    "System.Battery.Active.Remain.Percentage": 76, "Camera.WhiteBalance.Tint.Value": 0,
    "Camera.SlowAndQuickMotion.Enabled": False, "Camera.SlowAndQuickMotion.FrameRate": 48,
}
LINEAR: set = set()


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


async def linear_handler(req):
    import msgpack
    ws = web.WebSocketResponse(autoping=True)
    await ws.prepare(req)
    authed = req.app["savona_auth"] == "open"
    LINEAR.add(ws)
    LOG.append({"t": time.time(), "linear": "open"})

    async def reply(frame):
        await ws.send_bytes(msgpack.packb(frame, use_bin_type=True))

    async def notify_changed(props: dict):
        frame = [2, "Notify.Property.Value.Changed", [{k: v for k, v in props.items()}]]
        for s in list(LINEAR):
            try:
                await s.send_bytes(msgpack.packb(frame, use_bin_type=True))
            except Exception:
                LINEAR.discard(s)

    async for m in ws:
        if m.type != WSMsgType.BINARY:
            continue
        try:
            frame = msgpack.unpackb(m.data, raw=False)
        except Exception:
            continue
        LOG.append({"t": time.time(), "linear_recv": str(frame)[:200]})
        if not isinstance(frame, list) or len(frame) != 4 or frame[0] != 0 or not isinstance(frame[2], str):
            await reply([1, frame[1] if isinstance(frame, list) and len(frame) > 1 else 0, [400, "bad frame"], None])
            continue
        _t, mid, method, params = frame
        p0 = params[0] if isinstance(params, list) and params else params

        if method == "Alternate.Authentication.GetNonce":
            if req.app["savona_auth"] == "digest":
                await reply([1, mid, None, {"nonce": os.urandom(16).hex()}])
            else:
                await reply([1, mid, [403, "use basic"], None])
            continue
        if method == "Alternate.Authentication.Digest":
            d = p0 if isinstance(p0, dict) else (p0[0] if isinstance(p0, list) and p0 else {})
            ha1 = md5(f"{req.app['user']}:{REALM}:{req.app['pw']}")
            want = md5(f"{ha1}:{req.app.get('sav_nonce', '')}:{d.get('cnonce', '')}")
            authed = d.get("response") == want
            req.app["sav_authed"] = authed
            await reply([1, mid, None if authed else [403, "auth failed"], None])
            continue
        if method == "Alternate.Authentication.Basic":
            d = p0 if isinstance(p0, dict) else (p0[0] if isinstance(p0, list) and p0 else {})
            authed = req.app["savona_auth"] == "basic" and d.get("username") == "savuser" and d.get("password") == "savpass"
            req.app["sav_authed"] = authed
            await reply([1, mid, None if authed else [403, "auth failed"], None])
            continue
        if not (authed or req.app.get("sav_authed")):
            await reply([1, mid, [403, "auth required"], None])
            continue

        if method == "System.GetVersion":
            await reply([1, mid, None, {"model": "VENICE 2 (mock)", "savona": "2.6.4"}])
        elif method == "System.GetProperties":
            await reply([1, mid, None, [sorted(SAVONA_PROPS)]])
        elif method == "Notify.Subscribe":
            await reply([1, mid, None, None])
        elif method == "Property.GetValue":
            keys = p0 if isinstance(p0, dict) else {}
            out = {}
            for k in keys:
                if k in SAVONA_PROPS:
                    out[k] = SAVONA_PROPS[k]
                elif k == "Button.Assign":
                    out[k] = SAVONA_PROPS[k]
            await reply([1, mid, None, out if out else [404, "no such property"]])
        elif method == "Property.SetValue":
            keys = p0 if isinstance(p0, dict) else {}
            for k, v in keys.items():
                if k not in SAVONA_PROPS:
                    await reply([1, mid, [404, f"no such property {k}"], None])
                    break
                SAVONA_PROPS[k] = v
                if k == "Clip.Recorder":
                    SAVONA_PROPS["P.Clip.Mediabox.Status"] = "Recording" if v == "Rec" else "Standby"
                    await notify_changed({"P.Clip.Mediabox.Status": SAVONA_PROPS["P.Clip.Mediabox.Status"]})
                await notify_changed({k: v})
            else:
                await reply([1, mid, None, None])
        elif method == "Capability.GetValue":
            keys = p0 if isinstance(p0, list) else [p0]
            out = [[k, "Enum", (["Clear", "0.3", "0.6", "0.9", "1.2", "1.5", "1.8", "2.1", "2.4"]
                                if k == "Camera.NDFilter.Value" else [])] for k in keys]
            await reply([1, mid, None, out])
        elif method == "Button.SendKeys":
            key = p0[0] if isinstance(p0, list) else p0
            if key == "Rec":
                SAVONA_PROPS["Clip.Recorder"] = "Rec" if SAVONA_PROPS["Clip.Recorder"] == "Stop" else "Stop"
                await notify_changed({"Clip.Recorder": SAVONA_PROPS["Clip.Recorder"]})
                await reply([1, mid, None, None])
            elif key == "Assignable.1":
                SAVONA_PROPS["Button.Assign"]["Assignable.1"][1] = \
                    "On" if SAVONA_PROPS["Button.Assign"]["Assignable.1"][1] == "Off" else "Off"
                await notify_changed({"Button.Assign": SAVONA_PROPS["Button.Assign"]})
                await reply([1, mid, None, None])
            else:
                await reply([1, mid, [5001, f"unknown key {key}"], None])
        else:
            await reply([1, mid, [404, f"no such method {method}"], None])
    LINEAR.discard(ws)
    LOG.append({"t": time.time(), "linear": "close"})
    return ws



# ---------------------------------------------------------------------------------------------------------------------
# The real VENICE 2's Savona (FW V4.00, savona-2.9.4), documented in docs/venice.md ("The real
# VENICE 2"): one client at a time; the page's own login (getsavonacred.cgi -> SHA-256 pair -> Basic [{...}]); no
# answer at all to GetNonce, System.GetProperties or a request in the wrong shape; several messages per frame, now and
# then one split across two; menu switches as "0"/"1"; menu values as numbers; keys for REC and playback.

def sha256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


V2 = {"client": None, "refuse_until": 0.0, "stop_task": None, "ei_by_base": {}}
V2_EI = {800: ["200EI", "250EI", "320EI", "400EI", "500EI", "640EI", "800EI", "1000EI", "1250EI", "1600EI", "2000EI",
               "2500EI", "3200EI"],
         3200: ["800EI", "1000EI", "1250EI", "1600EI", "2000EI", "2500EI", "3200EI", "4000EI", "5000EI", "6400EI",
                "8000EI", "10000EI", "12800EI"]}
V2_PROPS = {
    "System.ModelName": "PXW-X180", "P.System.Menu.WebInfo.Firmware.CameraVersion": "V4.00",
    "Camera.Gain.ExposureIndex.Value": "800EI", "Camera.Gain.ISOValue": "ISO 3200",
    "Camera.Shutter.Mode": "Angle", "Camera.Shutter.Angle.DisplayValue": "180.0",
    "Camera.Shutter.Speed.DisplayValue": "1/48", "Camera.Shutter.Mode.Angle.Select": "Step",
    "Camera.Shutter.Mode.Speed.Select": "Step",
    "Camera.NDFilter.Enabled": {"cam": True}, "Camera.NDFilter.Mode": {"cam": "Preset"}, "Camera.NDFilter.Value": {"cam": 16},
    "Camera.WhiteBalance.ColorTemperature.Value": "3800", "Camera.WhiteBalance.ColorTemperature.Tint.Value": "0",
    "Camera.WhiteBalance.ColorTemperature.Type": "User",
    "Camera.SlowAndQuickMotion.Enabled": False, "Camera.SlowAndQuickMotion.FrameRate": 24,
    "P.Clip.Mediabox.Video.Format.FrameRate": "23.98", "System.Frequency": 23.976024627685547,
    "P.System.Menu.SystemFrequency": "5", "P.System.Menu.CamImagermode": "17", "P.System.Menu.AxsRecformatSelect": "3",
    "P.System.Menu.ShutterMode": "1", "P.System.Menu.FlipImage": "0", "P.System.Menu.FalseColor": "0",
    "P.System.Menu.ColorBar": "0", "Camera.ColorBar.Enabled": False,
    "P.System.Menu.RecOutDeanamoScaleSelect": "5", "P.System.Menu.SxsOutputDeSqueeze.Visiable": "1",
    "P.System.Menu.MarkerSdi12Onoff": "1", "P.System.Menu.MarkerSdi34Onoff": "1", "P.System.Menu.MarkerMonitorOnoff": "1",
    "P.System.Menu.MarkerVfOnoff": "1", "P.System.Menu.MarkerHdmiOnoff": "1",
    "P.System.Menu.SdiOsdDisplayInfoOnoff": "1", "P.System.Menu.MonitorOsdDisplayInfoOnoff": "1",
    "P.System.Menu.VfOsdDisplayInfoOnoff": "1", "P.System.Menu.HdmiOsdDisplayInfoOnoff": "1",
    "P.System.Menu.EvfZebraOnoff": "1", "P.System.Menu.PeakingOnoff": "0",
    # Every output's LUT, one map entry each; the look (user 3D LUT 5) and the lists behind it.
    "Output.Video.SDI.LUT.Value": {"sdi1": "Look", "sdi3": "Log"},
    "Output.Video.ViewFinder.LUT.Value": {"hdmi": "Look", "monitor": "Look", "vf": "s709"},
    "Output.Video.SDI.LUT.Value.LockStatus": {"sdi1": "Unlocked", "sdi3": "Unlocked"},
    "Output.Video.ViewFinder.LUT.Value.LockStatus": {"hdmi": "Unlocked", "monitor": "Unlocked", "vf": "Unlocked"},
    "LUT.Mode": {"cam": "User3D"}, "LUT.Preset": {"cam": "s709"},
    "LUT.User3DLUT.FileID": {"cam": 5}, "LUT.User3DLUT.FileName": {"cam": "2383_v2025_117.A004C005_130101_A1W5.cube"},
    "LUT.ART.FileID": {"cam": 1}, "LUT.ART.FileName": {"cam": "s709"},
    # HDMI shows the same as the Monitor (Const.js OUTPUT_FORMAT_INFO_*: 2 = Same as Monitor, 4 = its own).
    "P.System.Menu.OutputFormat.Info.Sdi34": "4", "P.System.Menu.OutputFormat.Info.Moni": "4",
    "P.System.Menu.OutputFormat.Info.Hdmi": "2", "P.System.Menu.MonitorOutSource": "0",
    "P.System.Menu.ClipnamingCameraid": "66", "P.System.Menu.ClipnamingReelNum": "24",
    "P.System.Menu.ClipnamingCameraposition": "0", "P.System.Menu.TimecodeDispTc": "3",
    "Storage.Media.Recording": {"media.1": "NotRecording", "media.2": "NotRecording", "media.4": "NotRecording",
                                "media.5": "NotRecording"},
    "Storage.Media.AvailableTime": {"media.1": 0, "media.2": 0, "media.4": 0, "media.5": 2770},
    "P.Clip.Mediabox.Status": "Standby", "P.Clip.Mediabox.Speed": 0.0, "P.Clip.Mediabox.TimeCode.Value": "16:54:18:08",
    "Clip.Mediabox.ClipName": {"main": "B020C005\u0000"}, "P.Clip.Mediabox.ClipName": "B020C005\u0000",
    "System.Battery.Active.Remain.Percentage": -1.0, "System.Battery.Active.Remain.Voltage": 14.6,
    "System.CameraID": {"cam": "B\u0000\u0000\u0000"},
    # The assignable buttons as the real one had them: false color (Exposure Assist) on Assignable.2 and VF B.
    "Button.Assign": {"Assignable.0": ["None", "Off"], "Assignable.1": ["Sdi34MlutBypass", "Off"],
                      "Assignable.2": ["FalseColorMonitor", "Off"], "Assignable.3": ["HAndVFlip", "Off"],
                      "Assignable.4": ["HAndVFlip", "Off"], "Assignable.5": ["None", "Off"],
                      "Assignable.6": ["None", "Off"], "Assignable.7": ["None", "Off"],
                      "VFAssignable.A": ["None", "Off"], "VFAssignable.B": ["FalseColorVF", "Off"],
                      "VFAssignable.C": ["FocusMagnifier", "Off"]},
    "Network.Connection.KeepAlive": {"cam": True},
}
V2_USER_LUTS = ["MAM_Level_1_Base.cube", "MAM_Level_2_Night.cube", "SD_Level_3_Creatures.cube", "JA_Sony_Cinema.cube",
                "2383_v2025_117.A004C005_130101_A1W5.cube", "071409_GK_SLOG3_Rec709_FC.cube"] + ["s709.cube"] * 5 + ["s709"] * 5
# Property.GetStatus: what's locked now (the real one had its color bars menu item locked, and no lens).
V2_STATUS = {"P.System.Menu.ColorBar.MenuItem": "Locked", "Camera.Iris.Value": "Locked"}
# The menu item behind a menu property, where its lock is reported under another name (VeniceMenu.menuLocks).
V2_MENU_LOCKS = {"P.System.Menu.CamImagermode": "P.System.Menu.ProjectImagerMode.MenuItem",
                 "P.System.Menu.AxsRecformatSelect": "P.System.Menu.AxsrecformatSet.MenuItem",
                 "P.System.Menu.SystemFrequency": "P.System.Menu.FrequencySet.MenuItem",
                 "P.System.Menu.RecOutDeanamoScaleSelect": "P.System.Menu.SxsOutputDeSqueeze.MenuItem",
                 "P.System.Menu.ColorBar": "P.System.Menu.ColorBar.MenuItem"}


def v2_locked(name: str) -> bool:
    return V2_STATUS.get(name) == "Locked" or V2_STATUS.get(V2_MENU_LOCKS.get(name, ""), "") == "Locked"


def v2_capability(name: str):
    base = 3200 if V2_PROPS["Camera.Gain.ISOValue"] == "ISO 3200" else 800
    lists = {
        "Camera.Gain.ExposureIndex.Value": V2_EI[base],
        "Camera.Shutter.Angle": ["360.0", "180.0", "172.8", "144.0", "90.0", "45.0", "22.5", "11.2", "5.6"],
        "Camera.SlowAndQuickMotion.FrameRate": list(range(8 if base == 3200 else 1, 31)),
        "P.System.Menu.L3_IMAGER_MODE": [str(i) for i in range(13, 24)],
        "P.System.Menu.L3_SYSTEM_FRAME_RATE": ["0", "1", "2", "3"],
        "P.System.Menu.L3_AXS_MAIN_REC_FORMAT": ["1", "3", "4", "5", "6", "7", "8", "9", "10"],
        "P.System.Menu.SxsOutputDeSqueeze.HighLightList": [str(i) for i in range(7)],
        "Output.Video.SDI.LUT.Value.SDI1": ["Log", "Log(Legal)", "Look"],
        "Output.Video.SDI.LUT.Value.SDI3": ["Log", "Log(Legal)", "Look"],
        "Output.Video.ViewFinder.LUT.Value.Monitor": ["Log", "Log(Legal)", "s709", "R709_800%", "Look"],
        "Output.Video.ViewFinder.LUT.Value.HDMI": ["Log", "s709", "R709_800%", "Look", "HLG"],
        "Output.Video.ViewFinder.LUT.Value.VF": ["Log", "s709", "R709_800%", "Look"],
        "LUT.Mode": ["PresetLook", "User3D", "ART"],
        "LUT.Preset": ["s709", "R709_800%", "S-Gamut3.Cine/SLog3", "S-Gamut3/SLog3"],
        "LUT.User3DLUT.LoadedList": V2_USER_LUTS,
        "LUT.ART.FileList": ["s709"] * 16,
    }
    return [True, "", lists[name]] if name in lists else None


async def venice2_linear(req):
    import msgpack
    if V2["client"] is not None or time.time() < V2["refuse_until"]:
        # The camera takes one client; the next is turned away (and for a few seconds after the last one goes).
        LOG.append({"t": time.time(), "linear": "refused"})
        return web.Response(status=503, text="busy")
    ws = web.WebSocketResponse(autoping=True)
    await ws.prepare(req)
    V2["client"] = ws
    authed = False
    LOG.append({"t": time.time(), "linear": "open (venice2)"})
    tick = {"n": 0}

    async def send(*messages):
        await ws.send_bytes(b"".join(msgpack.packb(m, use_bin_type=True) for m in messages))

    async def reply(mid, error=None, result=None):
        await send([1, mid, error, result])

    async def changed(props: dict, *extra):
        await send([2, "Notify.Property.Value.Changed", [props]], *extra)

    async def ticker():
        # Timecode and the audio meter, two messages per frame; every tenth frame split across two frames.
        while not ws.closed:
            await asyncio.sleep(0.5)
            tick["n"] += 1
            f = tick["n"] * 12
            tc = f"16:{54 + f // 1440 % 6:02d}:{f // 24 % 60:02d}:{f % 24:02d}"
            V2_PROPS["P.Clip.Mediabox.TimeCode.Value"] = tc
            data = b"".join(msgpack.packb(m, use_bin_type=True) for m in (
                [2, "Notify.Property.Value.Changed", [{"Clip.Mediabox.TimeCode.Value": {"main": tc},
                                                        "P.Clip.Mediabox.TimeCode.Value": tc}]],
                [2, "Notify.Property.Value.Changed", [{"Output.Audio.dBLevel": {"ch.1": 1, "ch.2": 1}}]]))
            try:
                if tick["n"] % 10 == 0:
                    await ws.send_bytes(data[:7])
                    await ws.send_bytes(data[7:])
                else:
                    await ws.send_bytes(data)
            except Exception:
                return

    ticking = None
    unpacker = msgpack.Unpacker(raw=False, strict_map_key=False)
    try:
        async for m in ws:
            if m.type != WSMsgType.BINARY:
                continue
            unpacker.feed(m.data)
            for frame in unpacker:
                LOG.append({"t": time.time(), "linear_recv": str(frame)[:200]})
                if not (isinstance(frame, list) and len(frame) == 4 and frame[0] == 0 and isinstance(frame[2], str)):
                    continue  # the camera says nothing to a malformed request
                _t, mid, method, params = frame
                if not isinstance(params, list):
                    continue  # params are always an array; a bare map gets no answer
                p0 = params[0] if params else None
                if method == "Alternate.Authentication.Basic":
                    if not isinstance(p0, dict):
                        continue
                    ok = p0.get("username") == sha256(req.app["user"]) and p0.get("password") == sha256(req.app["pw"])
                    authed = authed or ok
                    await reply(mid, None if ok else [403, "Authentication Failed"])
                    continue
                if method in ("Alternate.Authentication.GetNonce", "System.GetProperties"):
                    continue  # not on savona-2.9.4: no answer
                if method == "System.GetVersion":
                    await reply(mid, None, {"sign": "c996fb65193e33661e26fb0300145f5e31e44310", "version": "savona-2.9.4"})
                    continue
                if not authed:
                    await reply(mid, [401, "Unauthorized"])
                    continue
                if method == "Notify.Subscribe":
                    if isinstance(p0, list):
                        await reply(mid, None, p0)
                        if ticking is None:
                            ticking = asyncio.create_task(ticker())
                    continue
                if method == "Property.GetStatus":
                    if not isinstance(p0, dict):
                        continue
                    await reply(mid, None, {k: V2_STATUS.get(k, "Unlocked") for k in p0
                                            if k in V2_PROPS or k in V2_STATUS or k.endswith(".MenuItem")})
                    continue
                if method == "Property.GetValue":
                    if not isinstance(p0, dict):
                        continue
                    found = {k: V2_PROPS[k] for k in p0 if k in V2_PROPS}
                    missing = [k for k in p0 if k not in V2_PROPS]
                    await reply(mid, None, found)
                    for k in missing:
                        await send([2, "Notify.Property.ErrorOccurred", [{k: [3003, "Property Not Found"]}]])
                    continue
                if method == "Capability.GetValue":
                    if not isinstance(p0, list):
                        continue
                    await reply(mid, None, {k: v2_capability(k) for k in p0 if v2_capability(k) is not None})
                    continue
                if method == "Property.SetValue":
                    if not isinstance(p0, dict):
                        continue
                    if any(k.startswith("P.System.Menu.") and not isinstance(v, str) for k, v in p0.items()):
                        continue  # a menu switch takes "0"/"1"; a bool gets no answer
                    await reply(mid)
                    out = {}
                    for k, v in p0.items():
                        if v2_locked(k):
                            continue  # a locked item takes the write and changes nothing
                        if k.startswith("Camera.NDFilter."):
                            V2_PROPS[k] = {"cam": v}
                        elif isinstance(v, dict) and isinstance(V2_PROPS.get(k), dict) and "cam" not in V2_PROPS[k]:
                            V2_PROPS[k] = {**V2_PROPS[k], **v}  # a map written, and reported, one entry at a time
                            out[k] = v
                            continue
                        else:
                            V2_PROPS[k] = v
                        out[k] = V2_PROPS[k]
                    if "P.System.Menu.ShutterMode" in p0:
                        V2_PROPS["Camera.Shutter.Mode"] = "Angle" if p0["P.System.Menu.ShutterMode"] == "1" else "Speed"
                        out["Camera.Shutter.Mode"] = V2_PROPS["Camera.Shutter.Mode"]
                    if "P.System.Menu.FlipImage" in p0:
                        V2_PROPS["Button.Assign"]["Assignable.4"][1] = "On" if p0["P.System.Menu.FlipImage"] != "0" else "Off"
                    if "P.System.Menu.ColorBar" in out:
                        V2_PROPS["Camera.ColorBar.Enabled"] = out["P.System.Menu.ColorBar"] == "1"
                        out["Camera.ColorBar.Enabled"] = V2_PROPS["Camera.ColorBar.Enabled"]
                    if "LUT.User3DLUT.FileID" in out:
                        n = V2_PROPS["LUT.User3DLUT.FileID"]["cam"]
                        V2_PROPS["LUT.User3DLUT.FileName"] = {"cam": V2_USER_LUTS[n - 1] if 1 <= n <= 16 else ""}
                        out["LUT.User3DLUT.FileName"] = V2_PROPS["LUT.User3DLUT.FileName"]
                    if out:
                        await changed(out)
                    if "Camera.Gain.ISOValue" in p0:
                        # The real one puts the EI back where it last was on that base, or the bottom of the range the
                        # first time (2500 at base 800 reads 800EI after the switch to 3200); it doesn't go to the base.
                        base = 3200 if p0["Camera.Gain.ISOValue"] == "ISO 3200" else 800
                        V2["ei_by_base"][3200 if base == 800 else 800] = V2_PROPS["Camera.Gain.ExposureIndex.Value"]
                        ei = V2["ei_by_base"].get(base) or V2_EI[base][0]
                        V2_PROPS["Camera.Gain.ExposureIndex.Value"] = ei
                        await changed({"Camera.Gain.ExposureIndex.Value": ei},
                                      [2, "Notify.Capability.Value.Changed",
                                       [{"Camera.Gain.ExposureIndex.Value": v2_capability("Camera.Gain.ExposureIndex.Value")}]])
                    continue
                if method == "Property.UpdateValue":
                    if isinstance(p0, dict) and "Camera.Shutter.Value" in p0:
                        angle = float(V2_PROPS["Camera.Shutter.Angle.DisplayValue"]) + float(p0["Camera.Shutter.Value"])
                        V2_PROPS["Camera.Shutter.Angle.DisplayValue"] = f"{angle:.1f}"
                        await reply(mid)
                        await changed({"Camera.Shutter.Angle.DisplayValue": f"{angle:.1f}"})
                    continue
                if method == "Button.SendKeys":
                    key = p0[0] if isinstance(p0, list) and p0 else None
                    await reply(mid)
                    media = V2_PROPS["Storage.Media.Recording"]
                    if key == "Rec":
                        if media["media.5"] == "Recording":
                            async def stop_later():
                                await asyncio.sleep(2)  # the camera takes ~2 s to close the clip
                                media["media.5"] = "NotRecording"
                                n = int(V2_PROPS["P.Clip.Mediabox.ClipName"][5:8]) + 1
                                name = f"B020C{n:03d}"
                                V2_PROPS["P.Clip.Mediabox.ClipName"] = name
                                await changed({"Storage.Media.Recording": dict(media)})
                                await changed({"Clip.Mediabox.ClipName": {"main": name}, "P.Clip.Mediabox.ClipName": name})
                            V2["stop_task"] = asyncio.create_task(stop_later())
                        else:
                            media["media.5"] = "Recording"
                            await changed({"Storage.Media.Recording": dict(media)})
                    elif key in ("InsideClips", "Home"):
                        V2_PROPS["P.Clip.Mediabox.Status"] = "Playing" if key == "InsideClips" else "Standby"
                        V2_PROPS["P.Clip.Mediabox.Speed"] = 0.0
                        await changed({"P.Clip.Mediabox.Status": V2_PROPS["P.Clip.Mediabox.Status"], "P.Clip.Mediabox.Speed": 0.0})
                    elif key in ("Play", "Stop", "Forward", "Rewind") and V2_PROPS["P.Clip.Mediabox.Status"] == "Playing":
                        speed = {"Stop": 0.0, "Forward": 4.0, "Rewind": -4.0}.get(key, 0.0 if V2_PROPS["P.Clip.Mediabox.Speed"] else 1.0)
                        V2_PROPS["P.Clip.Mediabox.Speed"] = speed
                        await changed({"P.Clip.Mediabox.Speed": speed})
                    elif key in V2_PROPS["Button.Assign"]:
                        # An assignable button: its function toggles, and Button.Assign reports that slot alone.
                        function, state = V2_PROPS["Button.Assign"][key]
                        on = state != "On"
                        V2_PROPS["Button.Assign"][key] = [function, "On" if on else "Off"]
                        extra = []
                        if function == "HAndVFlip":
                            V2_PROPS["P.System.Menu.FlipImage"] = "3" if V2_PROPS["P.System.Menu.FlipImage"] == "0" else "0"
                            extra.append([2, "Notify.Property.Value.Changed",
                                          [{"P.System.Menu.FlipImage": V2_PROPS["P.System.Menu.FlipImage"]}]])
                        if function == "ColorBar":
                            V2_PROPS["Camera.ColorBar.Enabled"] = on
                            extra.append([2, "Notify.Property.Value.Changed", [{"Camera.ColorBar.Enabled": on}]])
                        await changed({"Button.Assign": {key: V2_PROPS["Button.Assign"][key]}}, *extra)
                    continue
                # anything else: no answer, as on the camera
    finally:
        if ticking:
            ticking.cancel()
        V2["client"] = None
        V2["refuse_until"] = time.time() + 3
        LOG.append({"t": time.time(), "linear": "close (venice2)"})
    return ws


async def v2_notify(name: str, data: dict):
    """A notification to the connected client, if there is one."""
    import msgpack
    ws = V2["client"]
    if ws is not None and not ws.closed:
        await ws.send_bytes(msgpack.packb([2, name, [data]], use_bin_type=True))


async def upload_cgi(req):
    """The page's LUT upload form (rmt.html HIDDEN_FORM_BIG6_UPLOAD_LUT_FILE): csrf, DestinationID, FileName."""
    if not authorized(req, req.app["user"], req.app["pw"]):
        return web.Response(status=401, headers={"WWW-Authenticate": challenge()}, text="401")
    form = await req.post()
    slot = int(form.get("DestinationID", "0") or 0)
    upload = form.get("FileName")
    if not (1 <= slot <= 16) or upload is None or len(str(form.get("csrf", "")).split(",")) != 4:
        return web.Response(status=400, text="bad form")
    size = len(upload.file.read())
    V2_USER_LUTS[slot - 1] = upload.filename
    LOG.append({"t": time.time(), "upload": upload.filename, "slot": slot, "bytes": size})
    await v2_notify("Notify.Capability.Value.Changed", {"LUT.User3DLUT.LoadedList": [True, "", V2_USER_LUTS]})
    return web.Response(text="OK")


async def lock_change(req):
    """/_mock/lock?name=P.System.Menu.ColorBar.MenuItem&state=Unlocked: a lock changing on the camera."""
    name, state = req.query.get("name", ""), req.query.get("state", "Locked")
    V2_STATUS[name] = state
    await v2_notify("Notify.Property.Status.Changed", {name: state})
    return web.json_response({"ok": True, name: state})


async def digest_cgi(req):
    if not authorized(req, req.app["user"], req.app["pw"]):
        return web.Response(status=401, headers={"WWW-Authenticate": challenge()}, text="401")
    nonce = req.query.get("nonce", "")
    req.app["sav_nonce"] = nonce
    ha1 = md5(f"{req.app['user']}:{REALM}:{req.app['pw']}")
    cnonce = os.urandom(8).hex()
    resp = md5(f"{ha1}:{nonce}:{cnonce}")
    return web.Response(text=f"cnonce={cnonce}\nresponse={resp}")


async def cred_cgi(req):
    if req.app["savona_auth"] == "venice2":
        if not authorized(req, req.app["user"], req.app["pw"]):
            return web.Response(status=401, headers={"WWW-Authenticate": challenge()}, text="401")
        return web.Response(text=f"{sha256(req.app['user'])}:{sha256(req.app['pw'])}")
    h = req.headers.get("Authorization", "")
    want = "Basic " + base64.b64encode(f"{req.app['user']}:{req.app['pw']}".encode()).decode()
    if h != want:
        return web.Response(status=401, headers={"WWW-Authenticate": 'Basic realm="VENICE2 mock"'}, text="401")
    return web.Response(text="savuser:savpass")


async def ws_handler(req):
    ws = web.WebSocketResponse()
    await ws.prepare(req)
    SOCKETS.add(ws)
    LOG.append({"t": time.time(), "ws": "open"})
    async for m in ws:
        if m.type != WSMsgType.TEXT:
            continue
        LOG.append({"t": time.time(), "recv": m.data})
        try:
            c = json.loads(m.data)
        except Exception:
            continue
        if c.get("cmd") == "subscribe":
            await ws.send_str(json.dumps({"type": "all", "props": [{"name": k, "value": v} for k, v in STATE.items()]}))
        elif c.get("cmd") == "set" and c.get("name") in STATE:
            STATE[c["name"]] = c.get("value")
            await broadcast({c["name"]: c.get("value")})
        elif c.get("cmd") == "key" and c.get("key") == "Rec":
            await asyncio.sleep(0.3)  # delayed feedback, like the real one is said to have
            STATE["Clip.Recorder"] = "Stop" if STATE["Clip.Recorder"] == "Rec" else "Rec"
            await broadcast({"Clip.Recorder": STATE["Clip.Recorder"]})
        elif c.get("cmd") == "key" and c.get("key") == "Assign1":
            STATE["Output.SensorFlip.Enabled"] = not STATE["Output.SensorFlip.Enabled"]
            await broadcast({"Output.SensorFlip.Enabled": STATE["Output.SensorFlip.Enabled"]})
    SOCKETS.discard(ws)
    LOG.append({"t": time.time(), "ws": "close"})
    return ws


def make_app(user: str, pw: str, ws_auth: bool, savona_auth: str = "venice2") -> web.Application:
    @web.middleware
    async def auth(req, handler):
        if req.path.startswith(("/_mock/", "/linear", "/cgi-bin/")) or (req.path == "/ws" and not ws_auth):
            return await handler(req)
        if not authorized(req, user, pw):
            LOG.append({"t": time.time(), "401": req.path})
            return web.Response(status=401, headers={"WWW-Authenticate": challenge()}, text="401")
        return await handler(req)

    async def page(_):
        return web.Response(text=PAGE, content_type="text/html")

    async def body_change(req):
        name, value = req.query.get("name"), req.query.get("value")
        try:
            value = json.loads(value)
        except Exception:
            pass
        if savona_auth == "venice2":
            # /_mock/body?name=P.System.Menu.OutputFormat.Info.Sdi34&value="2": a change on the camera body.
            V2_PROPS[name] = value
            await v2_notify("Notify.Property.Value.Changed", {name: value})
            return web.json_response({"ok": True})
        STATE[name] = value
        await broadcast({name: value})
        return web.json_response({"ok": True})

    async def log(_):
        return web.json_response(LOG[-200:])

    async def start_ticker(app):
        app["ticker"] = asyncio.create_task(ticker())

    app = web.Application(middlewares=[auth])
    app["savona_auth"] = savona_auth
    app["user"], app["pw"] = user, pw
    app.router.add_get("/", lambda r: web.HTTPFound("/rm.html"))
    app.router.add_get("/rm.html", page)
    app.router.add_get("/rmt.html", page)
    app.router.add_get("/js/rm.js", lambda r: web.Response(text=RM_JS, content_type="application/javascript"))
    app.router.add_get("/js/lib/util.min.js", lambda r: web.Response(text=UTIL_JS, content_type="application/javascript"))
    app.router.add_get("/css/rm.css", lambda r: web.Response(text="body{background:#111;color:#eee}"
                                                             " .logo{background:url(../img/bg.png)}", content_type="text/css"))
    app.router.add_get("/img/logo.svg", lambda r: web.Response(text="<svg xmlns='http://www.w3.org/2000/svg'/>",
                                                               content_type="image/svg+xml"))
    app.router.add_get("/img/bg.png", lambda r: web.Response(body=b"\x89PNG\r\n\x1a\n", content_type="image/png"))
    app.router.add_get("/data/lang_en.json", lambda r: web.json_response({"REC": "REC", "ND": "ND Filter"}))
    app.router.add_get("/ws", ws_handler)
    app.router.add_get("/linear", venice2_linear if savona_auth == "venice2" else linear_handler)
    app.router.add_get("/cgi-bin/getsavonadigest.cgi", digest_cgi)
    app.router.add_get("/cgi-bin/getsavonacred.cgi", cred_cgi)
    app.router.add_post("/cgi-bin/upload.cgi", upload_cgi)
    app.router.add_get("/_mock/body", body_change)
    app.router.add_get("/_mock/lock", lock_change)
    app.router.add_get("/_mock/log", log)
    app.on_startup.append(start_ticker)
    return app


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="test1234")
    ap.add_argument("--no-ws-auth", action="store_true")
    ap.add_argument("--savona-auth", choices=["venice2", "digest", "basic", "open"], default="venice2",
                    help="venice2: the real VENICE 2 (default); the others: older guesses")
    a = ap.parse_args()
    web.run_app(make_app(a.user, a.password, not a.no_ws_auth, a.savona_auth), host=a.host, port=a.port, print=None)
