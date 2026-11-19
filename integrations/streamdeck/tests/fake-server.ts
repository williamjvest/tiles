// Fake Tiles Control API server — used for unit tests only

import { WebSocketServer, WebSocket } from 'ws'

export const DEMO_TOKEN = 'test-token'
export const BAD_TOKEN  = 'wrong-token'

// ─── Minimal contract types (inlined so tests don't need the src/ module) ─────

export interface ChoiceField<T = unknown> {
  value: T; options: T[]; writable: boolean; pending?: T
}
export interface LevelField {
  value: number; min: number; max: number; step: number; writable: boolean; pending?: number
}
export interface RecordField {
  value: 'idle' | 'recording' | 'unknown'; writable: boolean; startedAt?: string; request?: string; failure?: string
}
export type AnyField = ChoiceField | LevelField | RecordField

export interface PlaybackStatus {
  clip?: string; clipNumber?: number; clipCount?: number; position?: number; duration?: number; commands: string[]
}

export interface Camera {
  id: string; label: string; model: string; color: string; demo: boolean
  connection: 'connected' | 'disconnected' | 'connecting' | 'stale' | string
  latencyMs: number; battery: number; mediaMinutes: number
  fields: Record<string, AnyField>
  playback?: PlaybackStatus
}

export interface Page {
  id: string; name: string; cameras: string[]; linking: boolean; links: string[]; current: boolean
}

export interface ResultEntry {
  camera: string; status: string; field?: string; value?: unknown; error?: string
}

// ─── Builder helpers ──────────────────────────────────────────────────────────

export function makeCamera(id: string, label: string, connected = true): Camera {
  return {
    id, label,
    model: 'ILME-FX3', color: 'blue', demo: true,
    connection: connected ? 'connected' : 'disconnected',
    latencyMs: 38, battery: 76, mediaMinutes: 142,
    fields: {
      record:          { value: connected ? 'idle' : 'unknown', writable: connected } as RecordField,
      iso:             { value: 800, options: [400, 800, 1600, 3200, 6400], writable: connected } as ChoiceField<number>,
      baseISO:         { value: 800, options: [800, 2500], writable: connected } as ChoiceField<number>,
      shutterMode:     { value: 'angle', options: ['angle', 'speed'], writable: connected } as ChoiceField<string>,
      shutterAngle:    { value: 180, options: [45, 90, 135, 180, 270, 360], writable: connected } as ChoiceField<number>,
      shutterSpeed:    { value: '1/50', options: ['1/25', '1/50', '1/100', '1/200'], writable: connected } as ChoiceField<string>,
      wbPreset:        { value: 'daylight', options: ['daylight', 'cloudy', 'tungsten', 'fluorescent'], writable: connected } as ChoiceField<string>,
      kelvin:          { value: 5600, min: 2500, max: 9900, step: 100, writable: connected } as LevelField,
      tint:            { value: 0, min: -150, max: 150, step: 1, writable: connected } as LevelField,
      iris:            { value: 2.8, options: [1.4, 2.0, 2.8, 4.0, 5.6, 8.0], writable: connected } as ChoiceField<number>,
      variableND:      { value: 2, min: 0, max: 10, step: 1, writable: connected } as LevelField,
      ndPreset:        { value: 'ND0.3', options: ['ND0.3', 'ND0.6', 'ND0.9', 'ND1.2'], writable: connected } as ChoiceField<string>,
      frameRate:       { value: '24', options: ['24', '25', '30', '48', '50', '60'], writable: connected } as ChoiceField<string>,
      look:            { value: false, options: [false, true], writable: connected } as ChoiceField<boolean>,
      falseColor:      { value: false, options: [false, true], writable: connected } as ChoiceField<boolean>,
      timecodeDuration:{ value: false, options: [false, true], writable: connected } as ChoiceField<boolean>,
      playing:         { value: false, options: [false, true], writable: connected } as ChoiceField<boolean>,
      playbackMode:    { value: 'live', options: ['live', 'review'], writable: connected } as ChoiceField<string>,
    },
    playback: connected ? {
      commands: ['togglePlay', 'play', 'pause', 'stop', 'next', 'previous', 'fastForward', 'rewind', 'review', 'live', 'skip'],
    } : undefined,
  }
}

export function makePage(id: string, name: string, cameraIds: string[], current = true): Page {
  return { id, name, cameras: cameraIds, linking: false, links: [], current }
}

// ─── Fake server ──────────────────────────────────────────────────────────────

export interface FakeServerOptions { port: number; token?: string }

export class FakeTwccServer {
  readonly port: number
  private wss: WebSocketServer
  private token: string
  cameras: Camera[]
  pages: Page[]
  receivedMessages: Record<string, unknown>[] = []
  clients: Set<WebSocket> = new Set()
  locked = false
  /** A link gone quiet: sockets stay open, nothing is answered. */
  silent = false

  constructor(opts: FakeServerOptions) {
    this.port   = opts.port
    this.token  = opts.token ?? DEMO_TOKEN
    this.cameras = [makeCamera('uuid-A', 'A'), makeCamera('uuid-B', 'B')]
    this.pages   = [makePage('page-1', 'A', ['uuid-A']), makePage('page-2', 'A+B', ['uuid-A', 'uuid-B'], false)]
    this.wss = new WebSocketServer({ port: this.port })
    this._setup()
  }

  private _setup(): void {
    this.wss.on('connection', (ws: WebSocket) => {
      this.clients.add(ws)
      let authed = false

      ws.on('message', (raw: Buffer) => {
        if (this.silent) return
        let msg: Record<string, unknown>
        try { msg = JSON.parse(raw.toString()) as Record<string, unknown> }
        catch { return }
        this.receivedMessages.push(msg)

        if (msg['type'] === 'auth') {
          if (msg['token'] !== this.token) {
            this._send(ws, { type: 'error', id: msg['id'], code: 'auth', message: 'Invalid token' })
            ws.close()
            return
          }
          authed = true
          this._send(ws, { type: 'hello', id: msg['id'], api: 1, app: 'Tiles', appVersion: '1.0.0',
            cameras: this.cameras, pages: this.pages, locked: this.locked })
          return
        }

        if (!authed) {
          this._send(ws, { type: 'error', code: 'auth', message: 'Not authenticated' })
          return
        }

        if (msg['type'] === 'subscribe') {
          this._send(ws, { type: 'snapshot', cameras: this.cameras, pages: this.pages, locked: this.locked })
          return
        }

        if (msg['type'] === 'ping') {
          this._send(ws, { type: 'pong', id: msg['id'] })
          return
        }

        if (msg['type'] === 'command') {
          this._handleCommand(ws, msg)
          return
        }

        if (msg['type'] === 'app') {
          const appMsg = msg as Record<string, unknown>
          if (appMsg['action'] === 'setLocked') {
            this.locked = appMsg['enabled'] as boolean
            // broadcast lock message to all clients
            for (const c of this.clients) this._send(c, { type: 'lock', locked: this.locked })
          }
          this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: 'app', status: 'confirmed' }] })
          return
        }
      })

      ws.on('close', () => { this.clients.delete(ws) })
    })
  }

  private _resolveCamera(target: Record<string, unknown>): Camera | undefined {
    if ('cameraID' in target) return this.cameras.find(c => c.id === target['cameraID'])
    if ('camera' in target) return this.cameras.find(c => c.label === target['camera'])
    if ('currentPage' in target || 'pageID' in target) return this.cameras[0]
    return this.cameras[0]
  }

  private _handleCommand(ws: WebSocket, msg: Record<string, unknown>): void {
    const target = msg['target'] as Record<string, unknown>
    const cmd    = msg['command'] as Record<string, unknown>

    const cam = this._resolveCamera(target)
    if (!cam) {
      this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: '?', status: 'rejected', error: 'Unknown target' }] })
      return
    }

    if ('set' in cmd) {
      const field = cam.fields[cmd['set'] as string]
      if (!field) {
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'rejected', field: cmd['set'], error: 'Field absent' }] })
        return
      }
      ;(field as unknown as Record<string, unknown>)['value'] = cmd['value']
      this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'confirmed', field: cmd['set'], value: cmd['value'] }] })
      this._broadcastChanges(cam, { [cmd['set'] as string]: { value: cmd['value'] } })
      return
    }

    if ('step' in cmd) {
      const fieldName = cmd['step'] as string
      const field = cam.fields[fieldName]
      if (!field) {
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'rejected', field: fieldName, error: 'Field absent' }] })
        return
      }
      const by = cmd['by'] as number
      if ('options' in field) {
        const opts = (field as ChoiceField).options
        const idx = opts.indexOf((field as ChoiceField).value)
        const newIdx = Math.max(0, Math.min(opts.length - 1, idx + by))
        ;(field as ChoiceField).value = opts[newIdx]
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'confirmed', field: fieldName, value: opts[newIdx] }] })
        this._broadcastChanges(cam, { [fieldName]: { value: opts[newIdx] } })
      } else if ('min' in field) {
        const lf = field as LevelField
        const newVal = Math.max(lf.min, Math.min(lf.max, lf.value + by * lf.step))
        lf.value = newVal
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'confirmed', field: fieldName, value: newVal }] })
        this._broadcastChanges(cam, { [fieldName]: { value: newVal } })
      }
      return
    }

    if ('toggle' in cmd) {
      const fieldName = cmd['toggle'] as string
      const field = cam.fields[fieldName]
      if (!field) {
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'rejected', field: fieldName, error: 'Field absent' }] })
        return
      }
      const cur = (field as unknown as Record<string, unknown>)['value']
      // REC unknown → rejected
      if (fieldName === 'record' && cur === 'unknown') {
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'rejected', field: fieldName, error: 'REC unknown' }] })
        return
      }
      const newVal = fieldName === 'record' ? (cur === 'recording' ? 'idle' : 'recording') : !cur
      ;(field as unknown as Record<string, unknown>)['value'] = newVal
      this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'confirmed', field: fieldName, value: newVal }] })
      this._broadcastChanges(cam, { [fieldName]: { value: newVal } })
      return
    }

    if ('cycle' in cmd) {
      const fieldName = cmd['cycle'] as string
      const field = cam.fields[fieldName] as ChoiceField
      if (!field || !('options' in field)) return
      const opts = field.options
      const idx = opts.indexOf(field.value)
      const newVal = opts[(idx + 1) % opts.length]
      field.value = newVal
      this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'confirmed', field: fieldName, value: newVal }] })
      this._broadcastChanges(cam, { [fieldName]: { value: newVal } })
      return
    }

    if ('playback' in cmd) {
      const pbCmd = cmd['playback'] as string
      const available = cam.playback?.commands ?? []
      const transportCmd = pbCmd === 'skip' ? 'skip' : pbCmd
      if (!available.includes(transportCmd)) {
        this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'rejected', error: 'unsupported' }] })
        return
      }
      this._send(ws, { type: 'result', id: msg['id'], results: [{ camera: cam.label, status: 'accepted' }] })
      return
    }
  }

  private _broadcastChanges(cam: Camera, fields: Record<string, unknown>): void {
    const msg = { type: 'changes', camera: cam.label, cameraID: cam.id, update: { fields } }
    for (const ws of this.clients) this._send(ws, msg)
  }

  /** Push a camera update to all clients (for reconnect tests). */
  pushCameras(cameras: Camera[]): void {
    this.cameras = cameras
    const msg = { type: 'cameras', cameras }
    for (const ws of this.clients) this._send(ws, msg)
  }

  /** Push one camera's changes to all clients, as the app does when its link to the camera changes. */
  pushChanges(cameraID: string, update: Record<string, unknown>): void {
    const cam = this.cameras.find(c => c.id === cameraID)
    const msg = { type: 'changes', camera: cam?.label ?? '?', cameraID, update }
    for (const ws of this.clients) this._send(ws, msg)
  }

  /** Simulate the server going away (triggers client reconnect logic). */
  dropAllClients(): void {
    for (const ws of this.clients) ws.terminate()
  }

  private _send(ws: WebSocket, msg: unknown): void {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg))
  }

  close(): Promise<void> {
    return new Promise(resolve => {
      for (const ws of this.clients) ws.close()
      this.wss.close(() => resolve())
    })
  }
}

/** Wait for a WebSocket to receive a message matching a predicate. */
export function nextMessage(ws: WebSocket, pred: (m: Record<string, unknown>) => boolean, timeoutMs = 2000): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout waiting for message')), timeoutMs)
    const handler = (raw: Buffer) => {
      try {
        const m = JSON.parse(raw.toString()) as Record<string, unknown>
        if (pred(m)) { clearTimeout(t); ws.off('message', handler); resolve(m) }
      } catch { /* ignore */ }
    }
    ws.on('message', handler)
  })
}

/** Open a WebSocket, authenticate, and subscribe. Returns when snapshot arrives. */
export async function connectAndAuth(port: number, token: string = DEMO_TOKEN): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/`)
    ws.once('error', reject)
    ws.once('open', () => {
      ws.send(JSON.stringify({ type: 'auth', token }))
    })
    ws.on('message', (raw: Buffer) => {
      try {
        const m = JSON.parse(raw.toString()) as Record<string, unknown>
        if (m['type'] === 'hello') {
          ws.send(JSON.stringify({ type: 'subscribe' }))
        }
        if (m['type'] === 'snapshot') {
          resolve(ws)
        }
        if (m['type'] === 'error') {
          reject(new Error((m['message'] as string) ?? m['code'] as string))
        }
      } catch { /* ignore */ }
    })
  })
}
