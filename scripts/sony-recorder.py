#!/usr/bin/env python3
"""Pose as a Sony camera on the LAN and record what a remote app (Monitor & Control) sends it.

The recorder answers as a second camera at --bind: SSDP NOTIFY every 3 s and answers to M-SEARCH, the camera's own
dd.xml and DigitalImagingDesc.xml with this address, a new UUID and " (recorder)" on its name, and an SSH server on
--bind:22 that takes any login (keyboard-interactive, as the camera's own does, or password). Each direct-tcpip channel
the app opens (Sony's remote runs PTP/IP through `-L 15740:localhost:15740`) is opened on a real SSH session to the
camera with its login, and every byte both ways goes to --out as camctl --record JSONL (timestamp, channel, direction
sent|received, hex), which the docs' decoders read. Channels are labelled command / event
from their PTP/IP init packet (type 1 / 3), and "#n" from the second SSH session on.

Made to see how Sony's Monitor & Control app changes an FX5's frame rate (it can't either: docs/fx5-controls.md).
What it took:
  - A LAN address of its own with port 22 free. On a Mac: sudo ifconfig en10 alias 192.0.2.249 netmask 255.255.255.255
    (and -alias after), and run it as root (binding port 22 on an address needs it).
  - Host keys ECDSA nistp256 (the camera's own) and Ed25519: Monitor & Control refused RSA ("no acceptable host key").
  - In the app: disconnect from the real camera, pick the one at --bind, Manual input with the camera's login (its QR
    code points at the real camera), and accept the new fingerprint.
Checked end to end with camctl and a paramiko client through it; Monitor & Control reached it and was refused over RSA,
and after the fix connected to the real camera instead, so a full app session hasn't been recorded yet.

    sudo -E uv run --with paramiko scripts/sony-recorder.py --bind 192.0.2.249 --camera 192.0.2.254 --out mc.jsonl
    (the camera's login from CAMCTL_SSH_USER / CAMCTL_SSH_PASSWORD; --work holds the keys and descriptions)
"""
import argparse, json, os, re, socket, struct, subprocess, sys, tempfile, threading, time, urllib.request, uuid
import http.server
import paramiko

ap = argparse.ArgumentParser()
ap.add_argument('--bind', required=True)
ap.add_argument('--camera', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--work', default=os.path.join(tempfile.gettempdir(), 'sony-recorder'))
ap.add_argument('--tag', default=' (recorder)')
args = ap.parse_args()
USER = os.environ.get('CAMCTL_SSH_USER'); PASSWORD = os.environ.get('CAMCTL_SSH_PASSWORD')
if not USER or not PASSWORD: sys.exit('CAMCTL_SSH_USER / CAMCTL_SSH_PASSWORD needed')

lock = threading.Lock()
out = open(args.out, 'a')


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def rec(channel, direction, data):
    with lock:
        out.write(json.dumps({'timestamp': time.time(), 'channel': channel, 'direction': direction,
                              'hex': data.hex()}) + '\n')
        out.flush()


# ---- the camera's description files, as this address -------------------------------------------------------------
DESC = os.path.join(args.work, 'desc')
os.makedirs(DESC, exist_ok=True)
FILES = {}
for name in ('dd.xml', 'DigitalImagingDesc.xml'):
    path = os.path.join(DESC, name)
    if not os.path.exists(path):
        with urllib.request.urlopen(f'http://{args.camera}:64321/{name}', timeout=5) as r, open(path, 'wb') as f:
            f.write(r.read())
    FILES['/' + name] = open(path, 'rb').read()
real_uuid = re.search(rb'uuid:([0-9a-fA-F-]{36})', FILES['/dd.xml']).group(1).decode()
fake_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, 'tiles-recorder-' + real_uuid))
for k, v in list(FILES.items()):
    v = v.replace(args.camera.encode(), args.bind.encode()).replace(real_uuid.encode(), fake_uuid.encode())
    v = re.sub(rb'(<friendlyName>)(.*?)(</friendlyName>)', lambda m: m.group(1) + m.group(2) + args.tag.encode() + m.group(3), v)
    FILES[k] = v
log('real uuid', real_uuid, '-> fake', fake_uuid)


class Desc(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = FILES.get(self.path.split('?')[0])
        log('http', self.client_address[0], self.path, 'ok' if body else '404')
        if body is None:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', 'text/xml; charset="utf-8"')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


threading.Thread(target=http.server.ThreadingHTTPServer((args.bind, 64321), Desc).serve_forever, daemon=True).start()

# ---- SSDP: NOTIFY alive every 3 s, and answers to M-SEARCH -----------------------------------------------------------
NTS = [f'uuid:{fake_uuid}', 'upnp:rootdevice', 'urn:schemas-sony-com:service:DigitalImaging:1']
HDR = ('CACHE-CONTROL: max-age=1800\r\nLOCATION: http://{ip}:64321/dd.xml\r\nSERVER: UPnP/1.0 SonyImagingDevice/1.0\r\n'
       'X-AV-Server-Info: av=5.0; hn=""; cn="Sony Corporation"; mn="SonyImagingDevice"; mv="1.0";\r\n')


def usn(nt):
    return f'uuid:{fake_uuid}' if nt.startswith('uuid:') else f'uuid:{fake_uuid}::{nt}'


def notifier():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.bind))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.bind((args.bind, 0))
    while True:
        for nt in NTS:
            msg = (f'NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n' + HDR.format(ip=args.bind) +
                   f'NT: {nt}\r\nNTS: ssdp:alive\r\nUSN: {usn(nt)}\r\n\r\n')
            s.sendto(msg.encode(), ('239.255.255.250', 1900))
        time.sleep(3)


def responder():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(('', 1900))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                 struct.pack('4s4s', socket.inet_aton('239.255.255.250'), socket.inet_aton(args.bind)))
    reply = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    reply.bind((args.bind, 0))
    while True:
        data, addr = s.recvfrom(8192)
        text = data.decode(errors='replace')
        if not text.startswith('M-SEARCH'):
            continue
        st = re.search(r'(?im)^ST:\s*(.+?)\s*$', text)
        st = st.group(1) if st else ''
        for nt in NTS:
            if st in ('ssdp:all', nt):
                log('m-search from', addr[0], st)
                msg = ('HTTP/1.1 200 OK\r\n' + HDR.format(ip=args.bind) + f'EXT:\r\nST: {nt}\r\nUSN: {usn(nt)}\r\n\r\n')
                reply.sendto(msg.encode(), addr)


threading.Thread(target=notifier, daemon=True).start()
threading.Thread(target=responder, daemon=True).start()

# ---- SSH: any login, direct-tcpip channels forwarded to the camera and recorded ---------------------------------------
# The camera's own host key is ECDSA nistp256, and Monitor & Control refused an RSA one ("no acceptable host key").
KEYS = os.path.join(args.work, 'keys')
os.makedirs(KEYS, exist_ok=True)
for kind, extra in (('ecdsa', ['-b', '256', '-m', 'PEM']), ('ed25519', [])):
    if not os.path.exists(os.path.join(KEYS, 'host_' + kind)):
        subprocess.run(['ssh-keygen', '-q', '-t', kind, *extra, '-N', '', '-f', os.path.join(KEYS, 'host_' + kind)], check=True)
HOST_KEYS = [paramiko.ECDSAKey(filename=os.path.join(KEYS, 'host_ecdsa')),
             paramiko.Ed25519Key(filename=os.path.join(KEYS, 'host_ed25519'))]
for k in HOST_KEYS:
    log('host key', k.get_name(), k.get_fingerprint().hex(':'))


class Server(paramiko.ServerInterface):
    def __init__(self):
        self.direct = {}

    def get_allowed_auths(self, username):
        return 'keyboard-interactive,password'

    def check_auth_password(self, username, password):
        log('login (password)', username)
        return paramiko.AUTH_SUCCESSFUL

    # The camera's own SSH server, and camctl, use keyboard-interactive.
    def check_auth_interactive(self, username, submethods):
        log('login (keyboard-interactive)', username)
        q = paramiko.InteractiveQuery('', '')
        q.add_prompt('Password: ', False)
        return q

    def check_auth_interactive_response(self, responses):
        return paramiko.AUTH_SUCCESSFUL

    def check_channel_request(self, kind, chanid):
        log('channel', kind, chanid)
        return paramiko.OPEN_SUCCEEDED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        log('direct-tcpip', chanid, origin, '->', destination)
        self.direct[chanid] = (origin, destination)
        return paramiko.OPEN_SUCCEEDED

    def check_channel_exec_request(self, channel, command):
        log('exec (refused)', command)
        return False

    def check_channel_subsystem_request(self, channel, name):
        log('subsystem (refused)', name)
        return False

    def check_global_request(self, kind, msg):
        log('global request', kind)
        return False


def pump(src, dst, state, direction):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if state['label'] is None and direction == 'sent' and len(data) >= 8:
                kind = struct.unpack_from('<I', data, 4)[0]
                state['label'] = {1: 'command', 3: 'event'}.get(kind, state['dest']) + state['suffix']
                log('channel', state['id'], 'is', state['label'])
            rec(state['label'] or state['dest'], direction, data)
            dst.sendall(data)
    except Exception as e:
        log('pump', state['id'], direction, 'ended:', e)
    finally:
        try:
            dst.close()
        except Exception:
            pass


SESSIONS = [0]


def session(sock, addr):
    SESSIONS[0] += 1
    suffix = '' if SESSIONS[0] == 1 else f'#{SESSIONS[0]}'
    log('client', addr, 'session', SESSIONS[0])
    t = paramiko.Transport(sock)
    for k in HOST_KEYS:
        t.add_server_key(k)
    server = Server()
    try:
        t.start_server(server=server)
    except Exception as e:
        log('ssh handshake failed:', e)
        return
    up = paramiko.SSHClient()
    up.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    up.connect(args.camera, 22, USER, PASSWORD, look_for_keys=False, allow_agent=False, timeout=10)
    upt = up.get_transport()
    upt.set_keepalive(10)
    log('upstream to', args.camera, 'open')
    while t.is_active():
        ch = t.accept(timeout=1)
        if ch is None:
            continue
        req = server.direct.get(ch.get_id())
        if req is None:
            log('channel', ch.get_id(), 'not direct-tcpip: closed')
            ch.close()
            continue
        origin, dest = req
        try:
            uch = upt.open_channel('direct-tcpip', dest, origin)
        except Exception as e:
            log('upstream channel to', dest, 'failed:', e)
            ch.close()
            continue
        state = {'id': ch.get_id(), 'dest': f'{dest[0]}:{dest[1]}', 'label': None, 'suffix': suffix}
        threading.Thread(target=pump, args=(ch, uch, state, 'sent'), daemon=True).start()
        threading.Thread(target=pump, args=(uch, ch, state, 'received'), daemon=True).start()
    log('client', addr, 'gone')
    up.close()


ls = socket.socket()
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind((args.bind, 22))
ls.listen(8)
log(f'recorder up: {args.bind} as {args.camera}, writing {args.out}')
while True:
    c, a = ls.accept()
    threading.Thread(target=session, args=(c, a), daemon=True).start()
