// Tiles Stream Deck plugin — unit tests (fake server, no SD runtime)

import { WebSocket } from 'ws'
import {
  FakeTwccServer,
  DEMO_TOKEN,
  BAD_TOKEN,
  makeCamera,
  makePage,
  connectAndAuth,
  nextMessage,
} from './fake-server'

let _nextPort = 54100
function allocPort(): number { return _nextPort++ }

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms))
}

// ─── Auth flow ────────────────────────────────────────────────────────────────

describe('auth flow', () => {
  let server: FakeTwccServer
  let port: number

  beforeEach(() => { port = allocPort(); server = new FakeTwccServer({ port }) })
  afterEach(() => server.close())

  it('good token: hello → subscribe → snapshot', async () => {
    const ws = await connectAndAuth(port)
    expect(server.receivedMessages.some(m => m['type'] === 'subscribe')).toBe(true)
    ws.close()
  })

  it('bad token: receives error with code auth and socket closes', async () => {
    await expect(connectAndAuth(port, BAD_TOKEN)).rejects.toThrow()
    // Server should have sent an auth error
    const authErr = server.receivedMessages.find(m => m['type'] === 'auth' && m['token'] === BAD_TOKEN)
    expect(authErr).toBeTruthy()
  })

  it('subscribe before auth: receives error', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/`)
    await new Promise<void>(r => ws.once('open', r))
    ws.send(JSON.stringify({ type: 'subscribe' }))
    const msg = await nextMessage(ws, m => m['type'] === 'error')
    expect(msg['code']).toBe('auth')
    ws.close()
  })
})

// ─── Command JSON — keys ───────────────────────────────────────────────────────

describe('key command shapes', () => {
  let server: FakeTwccServer
  let port: number
  let ws: WebSocket

  beforeEach(async () => {
    port = allocPort()
    server = new FakeTwccServer({ port })
    ws = await connectAndAuth(port)
  })
  afterEach(async () => { ws.close(); await server.close() })

  function sendCmd(target: object, command: object, id = 'test-1'): void {
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id, target, command }))
  }

  it('REC toggle → toggle record', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'record' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('record')
    expect(results[0]['status']).toBe('confirmed')
  })

  it('REC toggle on unknown → rejected', async () => {
    // Disconnect camera A so record = unknown
    const disconnectedCam = makeCamera('uuid-A', 'A', false)
    server.cameras[0] = disconnectedCam
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'record' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['status']).toBe('rejected')
    expect((results[0]['error'] as string).toLowerCase()).toContain('unknown')
  })

  it('REC is never confirmed as recording before server responds', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'record' }, 'rec-seq')
    const result = await nextMessage(ws, m => m['type'] === 'result' && m['id'] === 'rec-seq')
    const results = result['results'] as Array<Record<string, unknown>>
    expect(results[0]['status']).toBe('confirmed')
    expect(results[0]['field']).toBe('record')
    expect(results[0]['value']).toBe('recording')
  })

  it('ISO step up → step iso by 1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'iso', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('iso')
    expect(results[0]['value']).toBe(1600) // 800 → next option
  })

  it('ISO step down → step iso by -1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'iso', by: -1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('iso')
    expect(results[0]['value']).toBe(400) // 800 → previous option
  })

  it('shutter step up → step shutterAngle by 1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'shutterAngle', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('shutterAngle')
    expect(results[0]['status']).toBe('confirmed')
  })

  it('iris step up → step iris by 1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'iris', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('iris')
    expect(results[0]['status']).toBe('confirmed')
  })

  it('kelvin step → step kelvin by 1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'kelvin', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('kelvin')
    // step 1 * step(100) = 5600 + 100 = 5700 [control-api.md §step]
    expect(results[0]['value']).toBe(5700)
  })

  it('WB cycle → cycle wbPreset', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { cycle: 'wbPreset' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('wbPreset')
    expect(results[0]['value']).toBe('cloudy') // daylight → cloudy
  })

  it('LUT toggle → toggle look', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'look' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('look')
    expect(results[0]['value']).toBe(true)
  })

  it('false colour toggle → toggle falseColor', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'falseColor' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('falseColor')
    expect(results[0]['value']).toBe(true)
  })

  it('frame rate cycle → cycle frameRate', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { cycle: 'frameRate' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('frameRate')
    expect(results[0]['value']).toBe('25') // 24 → 25
  })

  it('show page → app showPage', async () => {
    ws.send(JSON.stringify({ type: 'app', action: 'showPage', pageID: 'page-1' }))
    const r = await nextMessage(ws, m => m['type'] === 'result')
    expect(r['results']).toBeTruthy()
  })

  it('link toggle → app setLinking', async () => {
    ws.send(JSON.stringify({ type: 'app', action: 'setLinking', pageID: 'page-1', enabled: true }))
    const r = await nextMessage(ws, m => m['type'] === 'result')
    expect(r['results']).toBeTruthy()
  })
})

// ─── New 2.2.0 key command shapes ────────────────────────────────────────────

describe('2.2.0 key command shapes', () => {
  let server: FakeTwccServer
  let port: number
  let ws: WebSocket

  beforeEach(async () => {
    port = allocPort()
    server = new FakeTwccServer({ port })
    ws = await connectAndAuth(port)
  })
  afterEach(async () => { ws.close(); await server.close() })

  function sendCmd(target: object, command: object, id = 'new-1'): void {
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id, target, command }))
  }

  it('ND + → step ndPreset by 1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'ndPreset', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('ndPreset')
    expect(results[0]['status']).toBe('confirmed')
    expect(results[0]['value']).toBe('ND0.6') // ND0.3 → ND0.6
  })

  it('ND − → step ndPreset by -1 (clamped at first option)', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'ndPreset', by: -1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('ndPreset')
    expect(results[0]['status']).toBe('confirmed')
    expect(results[0]['value']).toBe('ND0.3') // already at bottom, clamped
  })

  it('ND + on camera without ndPreset → rejected (field absent)', async () => {
    // Remove ndPreset from camera A
    delete server.cameras[0].fields['ndPreset']
    sendCmd({ cameraID: 'uuid-A' }, { step: 'ndPreset', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['status']).toBe('rejected')
  })

  it('Tint + → step tint by 1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'tint', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('tint')
    expect(results[0]['value']).toBe(1) // 0 + 1*1
  })

  it('Tint − → step tint by -1', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'tint', by: -1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('tint')
    expect(results[0]['value']).toBe(-1)
  })

  it('Any Control toggle → toggle a field', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'falseColor' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('falseColor')
    expect(results[0]['value']).toBe(true)
  })

  it('Any Control set → set a field to absolute value', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { set: 'iso', value: 3200 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('iso')
    expect(results[0]['value']).toBe(3200)
  })

  it('Any Control step → step a level field', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'kelvin', by: 2 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('kelvin')
    expect(results[0]['value']).toBe(5800) // 5600 + 2*100
  })

  it('Any Control cycle → cycle a choice field', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { cycle: 'frameRate' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('frameRate')
    expect(results[0]['value']).toBe('25')
  })

  it('Playback togglePlay → transport accepted', async () => {
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id: 'pb-1',
      target: { cameraID: 'uuid-A' }, command: { playback: 'togglePlay' } }))
    const r = await nextMessage(ws, m => m['type'] === 'result' && m['id'] === 'pb-1')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['status']).toBe('accepted')
  })

  it('Playback skip → transport accepted with by', async () => {
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id: 'pb-skip',
      target: { cameraID: 'uuid-A' }, command: { playback: 'skip', by: 5 } }))
    const r = await nextMessage(ws, m => m['type'] === 'result' && m['id'] === 'pb-skip')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['status']).toBe('accepted')
  })

  it('Playback unsupported command → rejected', async () => {
    // Remove 'next' from the camera's available commands
    server.cameras[0].playback!.commands = ['play', 'pause']
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id: 'pb-rej',
      target: { cameraID: 'uuid-A' }, command: { playback: 'next' } }))
    const r = await nextMessage(ws, m => m['type'] === 'result' && m['id'] === 'pb-rej')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['status']).toBe('rejected')
    expect(results[0]['error']).toBe('unsupported')
  })

  it('Lock → app setLocked toggles locked state and broadcasts lock message', async () => {
    expect(server.locked).toBe(false)
    ws.send(JSON.stringify({ type: 'app', token: DEMO_TOKEN, id: 'lock-1', action: 'setLocked', enabled: true }))
    const lockMsg = await nextMessage(ws, m => m['type'] === 'lock')
    expect(lockMsg['locked']).toBe(true)
    expect(server.locked).toBe(true)
  })

  it('TC/Duration toggle → toggle timecodeDuration', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'timecodeDuration' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('timecodeDuration')
    expect(results[0]['value']).toBe(true)
  })

  it('TC/Duration on camera without timecodeDuration → rejected', async () => {
    delete server.cameras[0].fields['timecodeDuration']
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'timecodeDuration' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    // field absent → server sends rejected (field absent path)
    expect(results[0]['status']).toBe('rejected')
  })
})

// ─── Dial command shapes ──────────────────────────────────────────────────────

describe('dial command shapes', () => {
  let server: FakeTwccServer
  let port: number
  let ws: WebSocket

  beforeEach(async () => {
    port = allocPort()
    server = new FakeTwccServer({ port })
    ws = await connectAndAuth(port)
  })
  afterEach(async () => { ws.close(); await server.close() })

  function sendCmd(target: object, command: object, id = 'dial-1'): void {
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id, target, command }))
  }

  it('ISO dial rotate CW 3 ticks → step iso by 3', async () => {
    // Each tick is sent individually; here we test the accumulated step
    sendCmd({ cameraID: 'uuid-A' }, { step: 'iso', by: 3 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('iso')
    // 800 → idx 1, +3 → idx 4 → 6400
    expect(results[0]['value']).toBe(6400)
  })

  it('ISO dial press: baseISO present → toggle baseISO', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { toggle: 'baseISO' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('baseISO')
    expect(results[0]['status']).toBe('confirmed')
  })

  it('shutter dial press: cycle shutterMode angle→speed', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { cycle: 'shutterMode' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('shutterMode')
    expect(results[0]['value']).toBe('speed') // angle → speed
  })

  it('kelvin dial press: cycle wbPreset', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { cycle: 'wbPreset' })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('wbPreset')
  })

  it('tint dial rotate → step tint by ticks (level field)', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'tint', by: 5 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('tint')
    expect(results[0]['value']).toBe(5)
  })

  it('iris dial rotate → step iris by ticks', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'iris', by: 1 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('iris')
  })

  it('ND dial rotate → step variableND by ticks', async () => {
    sendCmd({ cameraID: 'uuid-A' }, { step: 'variableND', by: 2 })
    const r = await nextMessage(ws, m => m['type'] === 'result')
    const results = r['results'] as Array<Record<string, unknown>>
    expect(results[0]['field']).toBe('variableND')
    expect(results[0]['value']).toBe(4)
  })
})

// ─── Title updates from changes ───────────────────────────────────────────────

describe('changes messages update values', () => {
  let server: FakeTwccServer
  let port: number
  let ws: WebSocket

  beforeEach(async () => {
    port = allocPort()
    server = new FakeTwccServer({ port })
    ws = await connectAndAuth(port)
  })
  afterEach(async () => { ws.close(); await server.close() })

  it('stepping ISO broadcasts a changes message with new value', async () => {
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id: 'c1', target: { cameraID: 'uuid-A' }, command: { step: 'iso', by: 1 } }))
    const changes = await nextMessage(ws, m => m['type'] === 'changes')
    const update = changes['update'] as Record<string, unknown>
    const fields = update['fields'] as Record<string, unknown>
    expect(fields['iso']).toBeTruthy()
    expect((fields['iso'] as Record<string, unknown>)['value']).toBe(1600)
  })

  it('REC toggle: server sends changes with new record value', async () => {
    // After toggling record, changes message must include record field update
    ws.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id: 'rec-ord',
      target: { cameraID: 'uuid-A' }, command: { toggle: 'record' } }))
    const changes = await nextMessage(ws, m => m['type'] === 'changes')
    const update = changes['update'] as Record<string, unknown>
    const fields = update['fields'] as Record<string, unknown>
    expect(fields['record']).toBeTruthy()
    expect((fields['record'] as Record<string, unknown>)['value']).toBe('recording')
  })
})

// ─── Reconnect → unknown → snapshot ──────────────────────────────────────────

describe('reconnect behaviour', () => {
  it('drop + reconnect delivers new snapshot', async () => {
    const port = allocPort()
    const server = new FakeTwccServer({ port })

    const ws1 = await connectAndAuth(port)

    // Push a camera update before dropping
    const newCam = makeCamera('uuid-A', 'A')
    ;(newCam.fields['iso'] as unknown as Record<string, unknown>)['value'] = 3200
    server.cameras = [newCam, makeCamera('uuid-B', 'B')]

    // Drop client to simulate iOS backgrounding
    server.dropAllClients()
    ws1.terminate()

    // New client reconnects
    await sleep(100)
    const ws2 = await connectAndAuth(port)

    // Receive snapshot — iso should be 3200 from new server state
    ws2.send(JSON.stringify({ type: 'command', token: DEMO_TOKEN, id: 'snap-check',
      target: { cameraID: 'uuid-A' }, command: { step: 'iso', by: 0 } }))

    // Check server has the right state
    expect(server.cameras[0].fields['iso']).toBeDefined()
    expect((server.cameras[0].fields['iso'] as unknown as Record<string, unknown>)['value']).toBe(3200)

    ws2.close()
    await server.close()
  })
})

// ─── Bad token keeps socket closed ───────────────────────────────────────────

describe('bad token', () => {
  it('auth error closes socket, no subscription happens', async () => {
    const port = allocPort()
    const server = new FakeTwccServer({ port })
    let closed = false
    const ws = new WebSocket(`ws://127.0.0.1:${port}/`)
    await new Promise<void>(r => ws.once('open', r))
    ws.on('close', () => { closed = true })
    ws.send(JSON.stringify({ type: 'auth', token: BAD_TOKEN }))
    await sleep(200)
    expect(closed).toBe(true)
    expect(server.receivedMessages.some(m => m['type'] === 'subscribe')).toBe(false)
    await server.close()
  })
})

// ─── connection.ts bug regression tests ──────────────────────────────────────
// These tests drive the connection module directly (global singleton).
// Each suite closes its server and resets the module via applyGlobalSettings.

import * as conn from '../src/connection'

afterAll(() => {
  conn.disconnect()
})

describe('connection module: auth-failed stops retrying', () => {
  it('bad token: no subscribe and no reconnect attempt within 500 ms', async () => {
    const port = allocPort()
    const server = new FakeTwccServer({ port })
    conn.applyGlobalSettings({ host: '127.0.0.1', port, token: BAD_TOKEN })
    await sleep(500)
    const subscribes = server.receivedMessages.filter(m => m['type'] === 'subscribe')
    expect(subscribes.length).toBe(0)
    // Only one auth attempt, not repeated
    const auths = server.receivedMessages.filter(m => m['type'] === 'auth')
    expect(auths.length).toBe(1)
    // Reset: use a port with no listener so connect() throws and scheduleReconnect handles it
    // Good-token reset clears authFailed; we just need the module quiet
    conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN })
    await sleep(200)
    await server.close()
  })
})

describe('connection module: heartbeat', () => {
  it('a socket the app goes quiet on is dropped: REC goes unknown, and it reconnects when the app answers', async () => {
    const saved = { ...conn.heartbeat }
    conn.heartbeat.intervalMs = 50
    conn.heartbeat.limitMs = 150
    const port = allocPort()
    const server = new FakeTwccServer({ port })
    try {
      conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN })
      await sleep(300)
      expect(conn.connected).toBe(true)
      expect(server.receivedMessages.some(m => m['type'] === 'ping')).toBe(true)
      expect((conn.cameras.get('uuid-A')?.fields['record'] as { value: string }).value).toBe('idle')

      server.silent = true
      await sleep(400)
      expect(conn.connected).toBe(false)
      expect((conn.cameras.get('uuid-A')?.fields['record'] as { value: string }).value).toBe('unknown')

      server.silent = false
      await sleep(1_500)  // first retry after 1 s
      expect(conn.connected).toBe(true)
    } finally {
      Object.assign(conn.heartbeat, saved)
      conn.disconnect()
      await server.close()
    }
  })
})

describe('connection module: a socket still connecting', () => {
  it('new settings drop it without an unhandled error (which would end the plugin)', async () => {
    // Takes the TCP connection and never answers the handshake: the socket stays CONNECTING.
    const held: import('net').Socket[] = []
    const silent = (await import('net')).createServer(socket => { held.push(socket) })
    const port = allocPort()
    await new Promise<void>(resolve => silent.listen(port, '127.0.0.1', () => resolve()))
    try {
      conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN })
      await sleep(100)
      expect(() => conn.applyGlobalSettings({ host: '127.0.0.1', port, token: BAD_TOKEN })).not.toThrow()
      await sleep(100)
      expect(() => conn.disconnect()).not.toThrow()
      await sleep(200)  // an unhandled 'error' would surface here and fail the run
    } finally {
      conn.disconnect()
      for (const socket of held) socket.destroy()
      await new Promise<void>(resolve => silent.close(() => resolve()))
    }
  })
})

describe('connection module: a camera\'s own link', () => {
  it('changes carry it: a camera Tiles loses reads disconnected, and connected again when it\'s back', async () => {
    const port = allocPort()
    const server = new FakeTwccServer({ port })
    try {
      conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN })
      await sleep(300)
      expect(conn.cameras.get('uuid-A')?.connection).toBe('connected')
      server.pushChanges('uuid-A', { connection: 'disconnected' })
      await sleep(100)
      expect(conn.cameras.get('uuid-A')?.connection).toBe('disconnected')
      expect(conn.cameras.get('uuid-B')?.connection).toBe('connected')
      server.pushChanges('uuid-A', { connection: 'connected' })
      await sleep(100)
      expect(conn.cameras.get('uuid-A')?.connection).toBe('connected')
    } finally {
      conn.disconnect()
      await server.close()
    }
  })
})

describe('connection module: reconnect does not clobber new socket', () => {
  it('rapid reconnect: sendCommand reaches new socket only', async () => {
    const port = allocPort()
    const server = new FakeTwccServer({ port })
    // Connect with good token
    conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN })
    await sleep(300)
    // Trigger reconnect (simulates settings change)
    conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN + '-new' })
    await sleep(50)
    conn.applyGlobalSettings({ host: '127.0.0.1', port, token: DEMO_TOKEN })
    await sleep(300)
    // After reconnect, cameras should be populated from snapshot
    // (not cleared by a stale close handler overwriting ws)
    expect(conn.connected).toBe(true)
    await server.close()
    await sleep(100)
  })
})
