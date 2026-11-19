// End-to-end check of the real Tiles Control API (twcc-api-demo) against the contract.
// Usage: start the harness (cd Packages/CameraKit && TWCC_API_TOKEN=demo-token swift run twcc-api-demo), then
//   node scripts/api-e2e.mjs
// Uses the `ws` package from the Companion module (npm install there once), or from WS_FROM.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const defaultWS = new URL('../integrations/companion-module/node_modules/', import.meta.url);
const require = createRequire(process.env.WS_FROM ? process.env.WS_FROM + '/' : fileURLToPath(defaultWS));
const WebSocket = require('ws');

const HOST = '127.0.0.1', WS = `ws://${HOST}:51800/`, HTTP = `http://${HOST}:51801`, TOKEN = 'demo-token';
const results = [];
const check = (name, ok, detail = '') => { results.push([ok ? 'PASS' : 'FAIL', name, ok ? '' : detail]); };

function open() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    const inbox = [];
    const waiters = [];
    ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      inbox.push(m);
      for (const w of [...waiters]) if (w.pred(m)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(m); }
    });
    ws.on('open', () => resolve({
      ws, inbox,
      send: (o) => ws.send(JSON.stringify(o)),
      wait: (pred, ms = 7000) => new Promise((res, rej) => {
        const hit = inbox.find(pred); if (hit) return res(hit);
        const w = { pred, resolve: res }; waiters.push(w);
        setTimeout(() => { const i = waiters.indexOf(w); if (i >= 0) { waiters.splice(i, 1); rej(new Error('timeout')); } }, ms);
      }),
      closed: new Promise((res) => ws.on('close', () => res(true))),
    }));
    ws.on('error', reject);
  });
}
const http = async (method, path, body, token = TOKEN) => {
  const r = await fetch(HTTP + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { 'X-TWCC-Token': token } : {}) },
                                       body: body ? JSON.stringify(body) : undefined });
  let j = null; try { j = await r.json(); } catch {}
  return { status: r.status, json: j };
};
let n = 0; const id = () => String(++n);

try {
  // HTTP auth + snapshot
  check('HTTP GET /state without token → 401', (await http('GET', '/state', null, null)).status === 401);
  const st = await http('GET', '/state');
  check('HTTP GET /state → 200 snapshot', st.status === 200 && Array.isArray(st.json?.cameras), JSON.stringify(st.json)?.slice(0, 200));

  // Bad token closes
  const bad = await open();
  bad.send({ type: 'auth', token: 'nope', id: id() });
  const err = await bad.wait((m) => m.type === 'error').catch(() => null);
  check('WS bad token → error code auth', err?.code === 'auth', JSON.stringify(err));
  check('WS bad token → socket closed', await Promise.race([bad.closed, new Promise((r) => setTimeout(() => r(false), 3000))]));

  // Good auth, hello shape
  const c = await open();
  c.send({ type: 'subscribe', id: 'early' });
  const early = await c.wait((m) => m.id === 'early').catch(() => null);
  check('subscribe before auth → error auth', early?.type === 'error' && early?.code === 'auth', JSON.stringify(early));
  c.send({ type: 'auth', token: TOKEN, id: 'a' });
  const hello = await c.wait((m) => m.type === 'hello');
  check('hello api 1 with cameras and pages', hello.api === 1 && hello.cameras?.length >= 1 && hello.pages?.length >= 1);
  const cam = hello.cameras.find((x) => x.label === 'C') ?? hello.cameras[0];
  const f = cam.fields ?? {};
  check('camera has id/label/model/connection', !!(cam.id && cam.label && 'model' in cam && cam.connection), JSON.stringify(cam).slice(0, 200));
  check('iso is a choice with options + writable', Array.isArray(f.iso?.options) && typeof f.iso?.writable === 'boolean', JSON.stringify(f.iso));
  check('kelvin is a level with min/max/step', ['min', 'max', 'step'].every((k) => typeof f.kelvin?.[k] === 'number'), JSON.stringify(f.kelvin));
  check('record field present with value', typeof f.record?.value === 'string', JSON.stringify(f.record));
  console.log('fields on', cam.label, Object.keys(f).join(','));

  c.send({ type: 'subscribe', id: id() });
  await c.wait((m) => m.type === 'snapshot');
  check('subscribe → snapshot', true);

  // set ISO → changes before confirmed result
  const opts = f.iso.options, cur = f.iso.value;
  const target = opts.find((v) => v !== cur);
  const before = c.inbox.length;
  const sid = id();
  c.send({ type: 'command', id: sid, target: { cameraID: cam.id }, command: { set: 'iso', value: target } });
  const r1 = await c.wait((m) => m.type === 'result' && m.id === sid);
  const e1 = r1.results?.[0];
  check('set iso → confirmed with value', e1?.status === 'confirmed' && e1?.value === target, JSON.stringify(r1));
  const rIdx = c.inbox.indexOf(r1);
  const changeIdx = c.inbox.findIndex((m, i) => i >= before && m.type === 'changes' && m.cameraID === cam.id && m.update?.fields?.iso?.value === target);
  check('changes with the confirmed value arrive before the result', changeIdx >= 0 && changeIdx < rIdx, `change@${changeIdx} result@${rIdx}`);

  // same value → confirmed, nothing sent
  const sameId = id();
  c.send({ type: 'command', id: sameId, target: { cameraID: cam.id }, command: { set: 'iso', value: target } });
  const rs = await c.wait((m) => m.type === 'result' && m.id === sameId);
  check('set to current value → confirmed at once', rs.results?.[0]?.status === 'confirmed', JSON.stringify(rs));

  // invalid value → rejected
  const invId = id();
  c.send({ type: 'command', id: invId, target: { cameraID: cam.id }, command: { set: 'iso', value: 123457 } });
  const ri = await c.wait((m) => m.type === 'result' && m.id === invId);
  check('value not in options → rejected', ri.results?.[0]?.status === 'rejected', JSON.stringify(ri));

  // missing target → error
  const ntId = id();
  c.send({ type: 'command', id: ntId, command: { set: 'iso', value: target } });
  const nt = await c.wait((m) => m.id === ntId);
  check('no target → error', nt.type === 'error', JSON.stringify(nt));

  // step +1 → next option
  const stepId = id();
  const idx = opts.indexOf(target);
  c.send({ type: 'command', id: stepId, target: { cameraID: cam.id }, command: { step: 'iso', by: 1 } });
  const rst = await c.wait((m) => m.type === 'result' && m.id === stepId);
  const expectStep = opts[Math.min(idx + 1, opts.length - 1)];
  check('step iso +1 → next option, confirmed', rst.results?.[0]?.status === 'confirmed' && rst.results?.[0]?.value === expectStep, JSON.stringify(rst));

  // coalescing: 5 fast steps land 5 options on
  const start = rst.results?.[0]?.value ?? expectStep;
  const ids5 = [1, 2, 3, 4, 5].map(() => id());
  for (const sid5 of ids5) c.send({ type: 'command', id: sid5, target: { cameraID: cam.id }, command: { step: 'iso', by: 1 } });
  const last5 = await c.wait((m) => m.type === 'result' && m.id === ids5[4], 15000);
  const want5 = opts[Math.min(opts.indexOf(start) + 5, opts.length - 1)];
  check('5 fast steps → ends 5 options on', last5.results?.[0]?.value === want5 && last5.results?.[0]?.status === 'confirmed', JSON.stringify(last5));
  const statuses5 = await Promise.all(ids5.map((x) => c.wait((m) => m.type === 'result' && m.id === x, 15000).then((m) => m.results?.[0]?.status)));
  console.log('5 fast steps statuses:', statuses5.join(','));
  check('fast steps: no timeout or failed (superseded or confirmed)', statuses5.every((x) => x === 'superseded' || x === 'confirmed'), statuses5.join(','));
  const burstValues = new Set(c.inbox.filter((m) => m.type === 'changes' && m.cameraID === cam.id && m.update?.fields?.iso && 'value' in m.update.fields.iso)
    .map((m) => m.update.fields.iso.value).filter((v) => opts.indexOf(v) > opts.indexOf(start)));
  check('fast steps: camera passes through at most 2 values (coalesced)', burstValues.size <= 2, [...burstValues].join(','));

  // REC set in the field's own words
  const rw1 = id();
  c.send({ type: 'command', id: rw1, link: false, target: { cameraID: cam.id }, command: { set: 'record', value: 'recording' } });
  const rwr1 = await c.wait((m) => m.type === 'result' && m.id === rw1, 10000);
  check('set record "recording" → confirmed recording', rwr1.results?.[0]?.status === 'confirmed' && rwr1.results?.[0]?.value === 'recording', JSON.stringify(rwr1));
  const rw2 = id();
  c.send({ type: 'command', id: rw2, link: false, target: { cameraID: cam.id }, command: { set: 'record', value: 'idle' } });
  const rwr2 = await c.wait((m) => m.type === 'result' && m.id === rw2, 10000);
  check('set record "idle" → confirmed idle', rwr2.results?.[0]?.status === 'confirmed' && rwr2.results?.[0]?.value === 'idle', JSON.stringify(rwr2));

  // REC toggle on, double press rejected, toggle off
  const recId = id(), rec2 = id();
  c.send({ type: 'command', id: recId, target: { cameraID: cam.id }, command: { toggle: 'record' } });
  c.send({ type: 'command', id: rec2, target: { cameraID: cam.id }, command: { toggle: 'record' } });
  const rr2 = await c.wait((m) => m.type === 'result' && m.id === rec2);
  check('second REC while one is pending → rejected', rr2.results?.[0]?.status === 'rejected', JSON.stringify(rr2));
  const rr = await c.wait((m) => m.type === 'result' && m.id === recId, 10000);
  check('REC toggle → confirmed recording', rr.results?.[0]?.status === 'confirmed' && rr.results?.[0]?.value === 'recording', JSON.stringify(rr));
  const startedSeen = c.inbox.some((m) => m.type === 'changes' && m.cameraID === cam.id && m.update?.fields?.record?.startedAt);
  check('changes carry record.startedAt', startedSeen);
  const offId = id();
  c.send({ type: 'command', id: offId, target: { cameraID: cam.id }, command: { set: 'record', value: false } });
  const off = await c.wait((m) => m.type === 'result' && m.id === offId, 10000);
  check('REC set false → confirmed idle', off.results?.[0]?.status === 'confirmed', JSON.stringify(off));

  // pages
  const page = hello.pages.find((p) => !p.current) ?? hello.pages[0];
  const pgId = id();
  c.send({ type: 'app', id: pgId, action: 'showPage', pageID: page.id });
  const pr = await c.wait((m) => m.id === pgId);
  check('showPage → result', pr.type === 'result', JSON.stringify(pr));
  const pagesMsg = await c.wait((m) => m.type === 'pages' && m.pages.some((p) => p.id === page.id && p.current)).catch(() => null);
  check('pages message marks the new current page', !!pagesMsg);
  const lkId = id();
  c.send({ type: 'app', id: lkId, action: 'setLinking', pageID: page.id, enabled: !page.linking });
  const lr = await c.wait((m) => m.id === lkId);
  check('setLinking → result', lr.type === 'result', JSON.stringify(lr));

  // inline token on an unauthenticated socket
  const s2 = await open();
  const inId = id();
  s2.send({ type: 'command', id: inId, token: TOKEN, target: { camera: cam.label }, command: { cycle: 'wbPreset' } });
  const inr = await s2.wait((m) => m.id === inId, 10000).catch(() => null);
  check('inline-token command on an unauthenticated socket → result', inr?.type === 'result', JSON.stringify(inr));

  // HTTP command: wait=false → accepted; wait → confirmed
  const h1 = await http('POST', '/command', { target: { cameraID: cam.id }, command: { step: 'iso', by: -1 }, wait: false });
  check('HTTP POST /command wait:false → accepted', h1.status === 200 && JSON.stringify(h1.json).includes('accepted'), JSON.stringify(h1));
  // only pause if the accepted command is still in flight
  if (h1.status === 200) await new Promise((r) => setTimeout(r, 1500));
  const h2 = await http('POST', '/command', { target: { cameraID: cam.id }, command: { step: 'iso', by: -1 } });
  check('HTTP POST /command → confirmed', h2.status === 200 && JSON.stringify(h2.json).includes('confirmed'), JSON.stringify(h2));
  const h3 = await http('POST', '/command', { target: { cameraID: cam.id }, command: { step: 'iso', by: 1 } }, 'nope');
  check('HTTP bad token → 401', h3.status === 401);
  const h4 = await http('POST', '/command', '{not json');
  check('HTTP malformed → 400', h4.status === 400, JSON.stringify(h4));

  // message sizes
  const ch = c.inbox.filter((m) => m.type === 'changes').map((m) => JSON.stringify(m).length);
  console.log(`changes messages: ${ch.length}, median ${ch.sort((a, b) => a - b)[Math.floor(ch.length / 2)]} B, snapshot ${JSON.stringify(st.json).length} B`);
  c.ws.close(); s2.ws.close();
} catch (e) {
  check('script', false, String(e?.stack ?? e));
}
for (const [s, name, d] of results) console.log(s, name, d ? '— ' + d.slice(0, 300) : '');
const passed = results.filter((r) => r[0] === 'PASS').length;
console.log(`${passed}/${results.length} passed`);
process.exit(passed === results.length ? 0 : 1);
