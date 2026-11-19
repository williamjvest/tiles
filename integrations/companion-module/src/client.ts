import WebSocket from 'ws'
import { EventEmitter } from 'events'
import type { ServerMessage, ClientMessage } from './protocol.js'

const MIN_BACKOFF_MS = 1_000
const MAX_BACKOFF_MS = 30_000

/**
 * A link that dies quietly (out of radio range, the app's device asleep) can keep the socket open for minutes before
 * TCP notices, with every feedback showing what it last knew. Ping this often, and drop a socket the app has said
 * nothing on for `limitMs`, as the Stream Deck plugin does.
 */
export const heartbeat = { intervalMs: 5_000, limitMs: 12_000 }

export interface TwccClientConfig {
	host: string
	port: number
	token: string
}

interface TwccClientEvents {
	message: [msg: ServerMessage]
	connected: []
	disconnected: []
	authFailed: []
	/** Something went wrong on the socket: said, not swallowed. */
	problem: [text: string]
}

export class TwccClient extends EventEmitter<TwccClientEvents> {
	private config: TwccClientConfig
	private ws: WebSocket | null = null
	private destroyed = false
	private authFailed = false
	private backoff = MIN_BACKOFF_MS
	private retryTimer: ReturnType<typeof setTimeout> | null = null
	private heartbeatTimer: ReturnType<typeof setInterval> | null = null
	private lastHeard = 0

	constructor(config: TwccClientConfig) {
		super()
		this.config = config
	}

	connect(): void {
		this.destroyed = false
		this._connect()
	}

	private _connect(): void {
		if (this.destroyed) return
		const url = `ws://${this.config.host}:${this.config.port}/`
		let ws: WebSocket
		try {
			ws = new WebSocket(url)
		} catch (err) {
			// A host the URL can't take: say so, and try again on the usual backoff.
			this.emit('problem', `can't connect to ${url}: ${(err as Error).message}`)
			this._scheduleReconnect()
			return
		}
		this.ws = ws

		ws.on('open', () => {
			this.backoff = MIN_BACKOFF_MS
			this.send({ type: 'auth', token: this.config.token })
			this._startHeartbeat(ws)
		})

		ws.on('message', (raw: Buffer | string) => {
			this.lastHeard = Date.now()
			let msg: ServerMessage
			try {
				msg = JSON.parse(raw.toString()) as ServerMessage
			} catch {
				return
			}

			if (msg.type === 'error' && msg.code === 'auth') {
				this.authFailed = true
				this.destroyed = true
				this.emit('authFailed')
				ws.close()
				return
			}

			if (msg.type === 'hello') {
				this.emit('connected')
				this.send({ type: 'subscribe' })
			}

			this.emit('message', msg)
		})

		ws.on('close', () => {
			this._stopHeartbeat()
			this.ws = null
			// skip disconnected when auth failed — authFailed already set the status
			if (!this.authFailed && !this.destroyed) {
				this.emit('disconnected')
			}
			this._scheduleReconnect()
		})

		ws.on('error', (err: Error) => {
			// 'close' follows and reconnects; the reason is still worth a line in the log.
			this.emit('problem', err.message)
		})
	}

	private _startHeartbeat(ws: WebSocket): void {
		this._stopHeartbeat()
		this.lastHeard = Date.now()
		this.heartbeatTimer = setInterval(() => {
			if (this.ws !== ws) {
				this._stopHeartbeat()
				return
			}
			// terminate() emits close, which reports the link down and reconnects.
			if (Date.now() - this.lastHeard > heartbeat.limitMs) {
				this.emit('problem', `nothing from the app in ${heartbeat.limitMs / 1000} s: reconnecting`)
				ws.terminate()
				return
			}
			if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'ping' }))
		}, heartbeat.intervalMs)
	}

	private _stopHeartbeat(): void {
		if (this.heartbeatTimer !== null) {
			clearInterval(this.heartbeatTimer)
			this.heartbeatTimer = null
		}
	}

	private _scheduleReconnect(): void {
		if (this.destroyed) return
		this.retryTimer = setTimeout(() => {
			this.retryTimer = null
			this._connect()
		}, this.backoff)
		this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF_MS)
	}

	send(msg: ClientMessage): void {
		if (this.ws && this.ws.readyState === WebSocket.OPEN) {
			this.ws.send(JSON.stringify(msg))
		}
	}

	destroy(): void {
		this.destroyed = true
		if (this.retryTimer !== null) {
			clearTimeout(this.retryTimer)
			this.retryTimer = null
		}
		this._stopHeartbeat()
		if (this.ws) {
			this.ws.removeAllListeners()
			// Closing a socket still connecting emits an error: with nothing listening, that would end the process.
			this.ws.on('error', () => {})
			this.ws.terminate()
			this.ws = null
		}
	}
}
