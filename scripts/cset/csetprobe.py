#!/usr/bin/env python3
"""Checks, on a real camera, what Tiles relies on when it changes a setting through a preset
(docs/pyxis-controls.md, Presets): a preset of one section, whole, changes that section and nothing else, and the
fields Tiles writes are where it thinks. Run it after a camera software update, before adding the version to
BlackmagicCameraBackend.checkedSoftware. Each step compares the camera's whole state before and after, and the original
state is loaded back at the end, whatever happens. Not during a take (it refuses).

    scripts/cset/csetprobe.py <camera address>        e.g. 172.27.250.13 over USB-C

NEVER send a preset with an empty section: on a PYXIS (Camera 10.3.1) that reset part of the camera (zebra and frame
guides on, an output on clean feed, lens values) and put a placeholder (0xDEAD1212) in its exposure settings, which only
the next whole-state load cleared."""
import json, os, ssl, sys, time, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cset import parse
from csetpatch import serialize, enc_varint

B = f'https://{sys.argv[1] if len(sys.argv) > 1 else "172.27.250.13"}/control/api/v1'
CTX = ssl._create_unverified_context()

def req(method, path, data=None, headers=None):
    r = urllib.request.Request(B + path, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def save():
    req('DELETE', '/presets/ProbeRead.cset')
    req('PUT', '/presets/ProbeRead.cset')
    for _ in range(80):
        st, body = req('GET', '/presets/ProbeRead.cset')
        if st == 200:
            break
        time.sleep(0.05)
    else:
        raise SystemExit('no preset from the camera')
    req('DELETE', '/presets/ProbeRead.cset')
    assert parse(body), 'unreadable save'
    return body

def load(data):
    st, body = req('POST', '/presets', data, {'Content-Type': 'application/octet-stream',
                                               'Content-Disposition': 'attachment; filename="ProbeLoad.cset"'})
    assert st == 200, (st, body)
    added = json.loads(body)['presetAdded']
    t = time.time()
    st2, body2 = req('PUT', '/presets/active', json.dumps({'preset': added + '.cset'}).encode(),
                     {'Content-Type': 'application/json'})
    took = time.time() - t
    time.sleep(1.2)
    req('DELETE', f'/presets/{added}.cset')
    return st2, body2, took

def secs(data):
    out = []
    for f, wt, v in parse(data):
        if f == 10:
            e = parse(v)
            out.append((dict((a, c) for a, _, c in e)[1].decode(), dict((a, c) for a, _, c in e).get(2, b'')))
    return out

def flatten(b, path=''):
    out, seen = {}, {}
    for field, wt, v in parse(b) or []:
        seen[field] = seen.get(field, 0) + 1
        p = f'{path}.{field}' if path else str(field)
        if seen[field] > 1:
            p += f'[{seen[field] - 1}]'
        if wt == 2:
            nested = parse(v) if v else None
            try:
                printable = bool(v) and v.decode('utf-8').isprintable()
            except UnicodeDecodeError:
                printable = False
            if nested and not printable:
                out.update(flatten(v, p))
            else:
                out[p] = v.hex()
        else:
            out[p] = v if wt == 0 else v.hex()
    return out

def diff(a, b):
    sa, sb = dict(secs(a)), dict(secs(b))
    out = []
    for name in sorted(set(sa) | set(sb)):
        fa, fb = flatten(sa.get(name, b'')), flatten(sb.get(name, b''))
        for k in sorted(set(fa) | set(fb)):
            if fa.get(k) != fb.get(k):
                out.append(f'{name} {k}: {fa.get(k)} -> {fb.get(k)}')
    return out

def build(sections, header=True):
    """A preset: the header field (1: 1) and the given (name, settings bytes) sections."""
    fields = [(1, 0, 1)] if header else []
    for name, body in sections:
        fields.append((10, 2, serialize([(1, 2, name.encode()), (2, 2, body)])))
    return serialize(fields)

def with_section(data, name, body):
    return build([(n, body if n == name else b) for n, b in secs(data)])

def drop_field(body, field):
    return serialize([x for x in parse(body) if x[0] != field])

def set_field(body, field, value):
    return serialize([(f, wt, value if f == field else v) for f, wt, v in parse(body)])



def metering_with(meter, index, field, value):
    """The metering section with output `index`'s `field` set (the rest as they are)."""
    out, i = [], 0
    for f, wt, v in parse(meter):
        if f == 32:
            if i == index:
                v = set_field(v, field, value) if field in [x for x, _, _ in parse(v)] else v + serialize([(field, 0, value)])
            i += 1
        out.append((f, wt, v))
    return serialize(out)

def run(label, make, changes, ignored=False):
    """make(current sections) -> preset bytes; changes: (section, csetdiff key, new value) it should make."""
    before = save()
    cur = dict(secs(before))
    fb = {n: flatten(b) for n, b in secs(before)}
    expect = [] if ignored else [f'{s} {k}: {fb[s].get(k)} -> {v}' for s, k, v in changes if fb[s].get(k) != v]
    preset = make(cur)
    st, resp, took = load(preset)
    after = save()
    d = diff(before, after)
    ok = sorted(d) == sorted(expect)
    print(f'{"PASS" if ok else "FAIL"} {label}  [{len(preset)} B, load {st}]')
    for line in d:
        print('     ', line)
    if not ok:
        print('      expected:', expect or 'no change')
        raise SystemExit('stopping')

st, rec = req('GET', '/transports/0/record')
if st != 200 or json.loads(rec).get('recording') is not False:
    raise SystemExit(f'not idle ({st} {rec!r}): nothing loaded')
A = save()
m, tr = flatten(dict(secs(A))['metering']), flatten(dict(secs(A))['transport'])
sdi8, sdi14, ds = m.get('32[3].8'), m.get('32[3].14'), tr.get('92')
print(f'camera: SDI status text {sdi8}, shows {sdi14}, de-squeeze {ds}')
try:
    run('the whole state, de-squeeze 1.5x (Tiles without a de-squeeze field)',
        lambda c: build([(n, set_field(b, 92, 2) if n == 'transport' else b) for n, b in c.items()]),
        [('transport', '92', 2)])
    run('a section left out stays: no audio sections, SDI status text flipped',
        lambda c: build([(n, metering_with(b, 3, 8, 1 - sdi8) if n == 'metering' else b) for n, b in c.items()
                         if n not in ('audioMete', 'audio2')]),
        [('metering', '32[3].8', 1 - sdi8)])
    run('transport alone, whole: de-squeeze back',
        lambda c: build([('transport', set_field(c['transport'], 92, ds))]), [('transport', '92', ds)])
    run('a section with one setting alone is ignored: transport {92: 1.5x}',
        lambda c: build([('transport', serialize([(92, 0, 2)]))]), [], ignored=True)
    run('metering alone, whole: SDI status text back',
        lambda c: build([('metering', metering_with(c['metering'], 3, 8, sdi8))]), [('metering', '32[3].8', sdi8)])
    run('metering alone, whole: SDI for the director' if sdi14 != 4 else 'metering alone, whole: SDI for the cinematographer',
        lambda c: build([('metering', metering_with(c['metering'], 3, 14, 4 if sdi14 != 4 else 3))]),
        [('metering', '32[3].14', 4 if sdi14 != 4 else 3)])
finally:
    load(A)
    R = save()
    d = diff(A, R)
    print('RESTORED' if not d else f'RESTORE DIFFERS {d}')
    st, lst = req('GET', '/presets')
    print('presets on the camera:', lst.decode().replace(' ', '').replace('\n', ''))
