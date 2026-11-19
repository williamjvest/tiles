"""mitmproxy addon for `venice.py proxy`: a reverse proxy in front of the camera's Web Remote that logs every request
and WebSocket frame into the capture session's events.jsonl, so any browser (the laptop's, a phone's) can drive the
page while everything is recorded. Loaded by mitmdump; uses only the standard library and mitmproxy's API.

It rewrites Origin and Referer to the camera's own origin on the way in (a camera may refuse a WebSocket from a foreign
origin), and Location headers and absolute self-links in pages and scripts on the way out, so the browser stays on the
proxy. Bodies are otherwise untouched.
"""
import base64
import json
import time
from urllib.parse import urlsplit

from mitmproxy import ctx, http


class VeniceLog:
    def __init__(self):
        self.f = None
        self.run = "proxy"
        self.up = ""

    def load(self, loader):
        loader.add_option("venice_session", str, "", "capture session folder")
        loader.add_option("venice_upstream", str, "", "camera base URL, e.g. http://192.168.2.50")
        loader.add_option("venice_run", str, "proxy1", "run name in events.jsonl")

    def configure(self, updated):
        if "venice_session" in updated and ctx.options.venice_session:
            self.f = open(f"{ctx.options.venice_session}/events.jsonl", "a", buffering=1, encoding="utf-8")
            self.run = ctx.options.venice_run
            self.up = ctx.options.venice_upstream.rstrip("/")
            self.log("run_start", kind="proxy", upstream=self.up)

    def log(self, type_, **kw):
        if self.f:
            rec = {"t": round(time.time(), 4), "run": self.run, **kw, "type": type_}
            self.f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")

    @staticmethod
    def public(flow) -> str:
        host, port = flow.client_conn.sockname[:2]
        return f"{host}:{port}"

    def request(self, flow: http.HTTPFlow):
        up = urlsplit(self.up)
        for h in ("Origin", "Referer"):
            v = flow.request.headers.get(h)
            if v:
                u = urlsplit(v)
                flow.request.headers[h] = f"{up.scheme}://{up.netloc}{u.path if h == 'Referer' else ''}" + \
                    (f"?{u.query}" if h == "Referer" and u.query else "")
        if flow.websocket is None and "upgrade" not in flow.request.headers.get("Connection", "").lower():
            rec = {"method": flow.request.method, "url": flow.request.url, "rtype": "proxy"}
            if flow.request.content:
                rec["post"] = flow.request.get_text(strict=False)[:65536]
            self.log("http_req", **rec)

    def response(self, flow: http.HTTPFlow):
        up = urlsplit(self.up)
        pub = self.public(flow)
        loc = flow.response.headers.get("Location")
        if loc and up.netloc in loc:
            flow.response.headers["Location"] = loc.replace(up.netloc, pub)
        ctype = flow.response.headers.get("Content-Type", "")
        if flow.websocket is not None or flow.response.status_code == 101:
            self.log("ws_handshake", url=flow.request.url, request=dict(flow.request.headers),
                     status=flow.response.status_code, response=dict(flow.response.headers))
            return
        rec = {"method": flow.request.method, "url": flow.request.url, "status": flow.response.status_code,
               "rtype": "proxy", "ctype": ctype, "len": len(flow.response.raw_content or b"")}
        if any(t in ctype for t in ("html", "javascript", "json", "text")) and flow.response.content:
            text = flow.response.get_text(strict=False)
            if up.netloc and up.netloc in text:
                flow.response.set_text(text.replace(up.netloc, pub))
                rec["rewrote_self_links"] = True
            if "json" in ctype or "text/plain" in ctype:
                rec["body"] = text[:65536]
        self.log("http_resp", **rec)

    def websocket_start(self, flow: http.HTTPFlow):
        self.log("ws_open", url=flow.request.url)

    def websocket_message(self, flow: http.HTTPFlow):
        m = flow.websocket.messages[-1]
        if m.is_text:
            payload = {"bin": False, "len": len(m.text), "text": m.text}
        else:
            payload = {"bin": True, "len": len(m.content), "b64": base64.b64encode(m.content).decode(),
                       "hex": m.content[:64].hex()}
        self.log("ws_send" if m.from_client else "ws_recv", url=flow.request.url, **payload)

    def websocket_end(self, flow: http.HTTPFlow):
        self.log("ws_close", url=flow.request.url, code=flow.websocket.close_code)


addons = [VeniceLog()]
