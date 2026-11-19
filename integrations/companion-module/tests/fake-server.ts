// Fake Tiles Control API server — used for unit tests only

import { WebSocketServer, WebSocket } from 'ws'
import type { Camera, Page, ServerMessage, ClientMessage, RadioStatus, PlaybackState } from '../src/protocol.js'

export const DEMO_TOKEN = 'test-token'
export const BAD_TOKEN = 'wrong-token'

export function makeDemoCamera(id: string, label: string, connected = true): Camera {
	return {
		id,
		label,
		model: 'ILME-FX3',
		color: 'blue',
		demo: true,
		connection: connected ? 'connected' : 'disconnected',
		latencyMs: 38,
		battery: 76,
		mediaMinutes: 142,
		fields: {
			record: { value: connected ? 'idle' : 'unknown', writable: connected },
			iso: { value: 800, options: [400, 800, 1600, 3200, 6400], writable: connected },
			wbPreset: { value: 'daylight', options: ['daylight', 'cloudy', 'tungsten', 'fluorescent'], writable: connected },
			kelvin: { value: 5600, min: 2500, max: 9900, step: 100, writable: connected },
			falseColor: { value: false, options: [false, true], writable: connected },
			look: { value: false, options: [false, true], writable: connected },
			colorBars: { value: false, options: [false, true], writable: connected },
			imageFlip: { value: false, options: [false, true], writable: connected },
			iris: { value: 2.8, options: [1.4, 2.0, 2.8, 4.0, 5.6, 8.0], writable: connected },
			shutterAngle: { value: 180, options: [45, 90, 135, 180, 270, 360], writable: connected },
		},
	}
}

export function makeDemoPage(id: string, name: string, cameraIds: string[], current = true): Page {
	return { id, name, cameras: cameraIds, linking: false, links: [], current }
}

export interface FakeServerOptions {
	port: number
	token?: string
}

export class FakeTwccServer {
	public readonly port: number
	private wss: WebSocketServer
	private token: string
	public cameras: Camera[]
	public pages: Page[]
	public radio: RadioStatus | undefined
	public locked: boolean = false
	public receivedMessages: ClientMessage[] = []
	public clients: Set<WebSocket> = new Set()

	constructor(opts: FakeServerOptions) {
		this.port = opts.port
		this.token = opts.token ?? DEMO_TOKEN
		this.cameras = [
			makeDemoCamera('uuid-A', 'A'),
			makeDemoCamera('uuid-B', 'B'),
		]
		this.pages = [
			makeDemoPage('page-uuid-1', 'A', ['uuid-A']),
			makeDemoPage('page-uuid-2', 'A+B', ['uuid-A', 'uuid-B'], false),
		]
		this.wss = new WebSocketServer({ port: this.port })
		this._setup()
	}

	private _setup(): void {
		this.wss.on('connection', (ws: WebSocket) => {
			this.clients.add(ws)
			let authenticated = false

			ws.on('message', (raw: Buffer) => {
				let msg: ClientMessage
				try { msg = JSON.parse(raw.toString()) as ClientMessage }
				catch { return }
				this.receivedMessages.push(msg)

				if (msg.type === 'auth') {
					if (msg.token !== this.token) {
						this._send(ws, { type: 'error', id: msg.id, code: 'auth', message: 'Invalid token' })
						ws.close()
						return
					}
					authenticated = true
					this._send(ws, { type: 'hello', id: msg.id, api: 1, app: 'Tiles', appVersion: '1.0.0', cameras: this.cameras, pages: this.pages, locked: this.locked, ...(this.radio ? { radio: this.radio } : {}) })
					return
				}

				if (!authenticated) {
					this._send(ws, { type: 'error', code: 'auth', message: 'Not authenticated' })
					return
				}

				if (msg.type === 'subscribe') {
					this._send(ws, { type: 'snapshot', cameras: this.cameras, pages: this.pages, locked: this.locked, ...(this.radio ? { radio: this.radio } : {}) })
					return
				}

				if (msg.type === 'ping') {
					this._send(ws, { type: 'pong', id: msg.id })
					return
				}

				if (msg.type === 'command') {
					const target = msg.target
					let cam: Camera | undefined
					if ('cameraID' in target) cam = this.cameras.find((c) => c.id === target.cameraID)
					else if ('camera' in target) cam = this.cameras.find((c) => c.label === target.camera)
					else if ('currentPage' in target) cam = this.cameras[0]
					else cam = this.cameras[0]

					if (!cam) {
						this._send(ws, { type: 'result', id: msg.id, results: [{ camera: '?', status: 'rejected', error: 'Unknown target' }] })
						return
					}

					const cmd = msg.command
					if ('set' in cmd) {
						const field = cam.fields[cmd.set]
						if (!field) {
							this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'rejected', field: cmd.set, error: 'Field absent' }] })
							return
						}
						;(field as { value: unknown }).value = cmd.value
						this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'confirmed', field: cmd.set, value: cmd.value }] })
						this._broadcastChanges(cam, { [cmd.set]: { value: cmd.value } })
						return
					}
					if ('step' in cmd) {
						const field = cam.fields[cmd.step]
						if (!field || !('options' in field)) return
						const opts = (field as { options: unknown[]; value: unknown }).options
						const idx = opts.indexOf((field as { value: unknown }).value)
						const newIdx = Math.max(0, Math.min(opts.length - 1, idx + cmd.by))
						;(field as { value: unknown }).value = opts[newIdx]
						this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'confirmed', field: cmd.step, value: opts[newIdx] }] })
						return
					}
					if ('toggle' in cmd) {
						const field = cam.fields[cmd.toggle]
						if (!field) return
						const cur = (field as { value: unknown }).value
						// REC unknown → rejected
						if (cmd.toggle === 'record' && cur === 'unknown') {
							this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'rejected', field: cmd.toggle, error: 'REC unknown' }] })
							return
						}
						const newVal = cmd.toggle === 'record' ? (cur === 'recording' ? 'idle' : 'recording') : !cur
						;(field as { value: unknown }).value = newVal
						this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'confirmed', field: cmd.toggle, value: newVal }] })
						this._broadcastChanges(cam, { [cmd.toggle]: { value: newVal } })
						return
					}
					if ('cycle' in cmd) {
						const field = cam.fields[cmd.cycle]
						if (!field || !('options' in field)) return
						const opts = (field as { options: unknown[]; value: unknown }).options
						const idx = opts.indexOf((field as { value: unknown }).value)
						const newVal = opts[(idx + 1) % opts.length]
						;(field as { value: unknown }).value = newVal
						this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'confirmed', field: cmd.cycle, value: newVal }] })
						return
					}
					if ('playback' in cmd) {
						this._send(ws, { type: 'result', id: msg.id, results: [{ camera: cam.label, status: 'accepted' }] })
						return
					}
				}

				if (msg.type === 'app') {
					if (msg.action === 'setLocked') {
						this.locked = msg.enabled
						this._broadcastLock(this.locked)
					}
					this._send(ws, { type: 'result', id: msg.id, results: [{ camera: 'app', status: 'confirmed' }] })
				}
			})

			ws.on('close', () => { this.clients.delete(ws) })
		})
	}

	private _broadcastChanges(cam: Camera, fields: Record<string, unknown>): void {
		const msg: ServerMessage = {
			type: 'changes', camera: cam.label, cameraID: cam.id,
			update: { fields: fields as Parameters<typeof Object.assign>[0] },
		}
		for (const ws of this.clients) this._send(ws, msg)
	}

	pushRadio(radio: RadioStatus): void {
		this.radio = radio
		const msg: ServerMessage = { type: 'radio', radio }
		for (const ws of this.clients) this._send(ws, msg)
	}

	pushCameras(cameras: Camera[]): void {
		this.cameras = cameras
		const msg: ServerMessage = { type: 'cameras', cameras }
		for (const ws of this.clients) this._send(ws, msg)
	}

	pushPlayback(cameraId: string, playback: PlaybackState | null): void {
		const cam = this.cameras.find((c) => c.id === cameraId)
		if (!cam) return
		cam.playback = playback
		const msg: ServerMessage = {
			type: 'changes', camera: cam.label, cameraID: cam.id,
			update: { playback },
		}
		for (const ws of this.clients) this._send(ws, msg)
	}

	private _broadcastLock(locked: boolean): void {
		const msg: ServerMessage = { type: 'lock', locked }
		for (const ws of this.clients) this._send(ws, msg)
	}

	pushLock(locked: boolean): void {
		this.locked = locked
		this._broadcastLock(locked)
	}

	private _send(ws: WebSocket, msg: ServerMessage): void {
		if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg))
	}

	close(): Promise<void> {
		return new Promise((resolve) => {
			for (const ws of this.clients) ws.close()
			this.wss.close(() => resolve())
		})
	}
}
