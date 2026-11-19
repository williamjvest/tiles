import { InstanceBase, InstanceStatus } from '@companion-module/base'
import type { SomeCompanionConfigField, CompanionVariableValues } from '@companion-module/base'
import { TwccClient } from './client.js'
import type { TwccClientConfig } from './client.js'
import {
	createState,
	applySnapshot,
	applyChanges,
	applyPagesUpdate,
	applyCamerasUpdate,
	markAllUnknown,
} from './state.js'
import type { TwccState } from './state.js'
import { buildActions, LensDrives } from './actions.js'
import { buildFeedbacks } from './feedbacks.js'
import { buildVariableDefinitions, buildVariableValues, formatRecTime } from './variables.js'
import { buildPresets } from './presets.js'
import type { ClientMessage, ServerMessage } from './protocol.js'
import type { TwccConfig, TwccTypes } from './types.js'

export type { TwccConfig } from './types.js'

const DEFAULT_PORT = 51800

export default class TwccModule extends InstanceBase<TwccTypes> {
	private config: TwccConfig = { host: '', port: DEFAULT_PORT, token: '' }
	private client: TwccClient | null = null
	private state: TwccState = createState()
	private recTimerInterval: ReturnType<typeof setInterval> | null = null
	private readonly drives = new LensDrives()

	async init(config: TwccConfig, _isFirstInit: boolean): Promise<void> {
		this.config = config
		this.updateStatus(InstanceStatus.Connecting)
		this._rebuildAll()
		this._connect()
	}

	async configUpdated(config: TwccConfig): Promise<void> {
		this.config = config
		this._teardown()
		this.state = createState()
		this.updateStatus(InstanceStatus.Connecting)
		this._rebuildAll()
		this._connect()
	}

	async destroy(): Promise<void> {
		this._teardown()
	}

	getConfigFields(): SomeCompanionConfigField[] {
		return [
			{ type: 'textinput', id: 'host', label: 'Host / IP Address', default: '', width: 8 },
			{ type: 'number', id: 'port', label: 'WebSocket Port', default: DEFAULT_PORT, min: 1, max: 65535, width: 4 },
			{
				type: 'textinput',
				id: 'token',
				label: 'Pairing Token (from Tiles Settings → Control API)',
				default: '',
				width: 12,
			},
		]
	}

	private _send(msg: ClientMessage): void {
		this.client?.send(msg)
	}

	private _rebuildAll(): void {
		this.setActionDefinitions(buildActions(this.state, (msg) => this._send(msg), this.drives))
		this.setFeedbackDefinitions(buildFeedbacks(this.state))
		this.setVariableDefinitions(buildVariableDefinitions(this.state))
		const { structure, presets } = buildPresets(this.state)
		this.setPresetDefinitions(structure, presets)
		this.setVariableValues(buildVariableValues(this.state))
	}

	private _connect(): void {
		if (!this.config.host || !this.config.token) {
			this.updateStatus(InstanceStatus.BadConfig, 'Host and token required')
			return
		}
		const cfg: TwccClientConfig = {
			host: this.config.host,
			port: this.config.port || DEFAULT_PORT,
			token: this.config.token,
		}
		this.client = new TwccClient(cfg)

		this.client.on('connected', () => {
			this.updateStatus(InstanceStatus.Ok)
			this._startRecTimer()
		})
		this.client.on('disconnected', () => {
			this.updateStatus(InstanceStatus.Connecting)
			this._stopRecTimer()
			this.drives.stopAll()
			markAllUnknown(this.state)
			this.setVariableValues(buildVariableValues(this.state))
			this.checkAllFeedbacks()
		})
		this.client.on('authFailed', () => {
			this.updateStatus(InstanceStatus.ConnectionFailure, 'Auth failed — check token in Tiles → Settings → Control API')
		})
		this.client.on('problem', (text: string) => {
			this.log('debug', `Tiles connection: ${text}`)
		})
		this.client.on('message', (msg: ServerMessage) => {
			this._handleMessage(msg)
		})
		this.client.connect()
	}

	private _handleMessage(msg: ServerMessage): void {
		switch (msg.type) {
			case 'hello':
				applySnapshot(this.state, msg.cameras, msg.pages, msg.radio, msg.locked)
				this._rebuildAll()
				break

			case 'snapshot':
				applySnapshot(this.state, msg.cameras, msg.pages, msg.radio, msg.locked)
				this._rebuildAll()
				break

			case 'changes':
				applyChanges(this.state, msg.cameraID, msg.update, msg.removed)
				this.setVariableValues(buildVariableValues(this.state))
				this.checkFeedbacks(
					'recording',
					'rec_unknown',
					'rec_pending',
					'camera_connected',
					'camera_not_connected',
					'field_equals',
					'field_writable',
					'playing',
					'in_review',
				)
				break

			case 'pages':
				// The page choices in the actions, and every feedback that follows the current page.
				applyPagesUpdate(this.state, msg.pages)
				this._rebuildAll()
				this.checkAllFeedbacks()
				break

			case 'radio':
				this.state.radio = msg.radio
				this.setVariableValues(buildVariableValues(this.state))
				this.checkFeedbacks('radio_bars_below')
				break

			case 'cameras':
				applyCamerasUpdate(this.state, msg.cameras)
				this._rebuildAll()
				break

			case 'lock':
				this.state.locked = msg.locked
				this.setVariableValues(buildVariableValues(this.state))
				this.checkFeedbacks('controls_locked')
				break

			case 'error':
				if (msg.code !== 'auth') this.log('warn', `Tiles turned a request down (${msg.code}): ${msg.message}`)
				break

			case 'result':
				for (const entry of msg.results) {
					// Superseded is a later press taking over: nothing went wrong.
					if (entry.status !== 'confirmed' && entry.status !== 'accepted' && entry.status !== 'superseded') {
						this.log(
							'warn',
							`Tiles: ${entry.field ?? 'command'} on ${entry.camera} ${entry.status}${entry.error ? `: ${entry.error}` : ''}`,
						)
					}
				}
				break

			default:
				break // pong
		}
	}

	private _startRecTimer(): void {
		this._stopRecTimer()
		this.recTimerInterval = setInterval(() => {
			const vals: CompanionVariableValues = {}
			for (const [, cam] of this.state.cameras) {
				const recField = cam.fields.record
				if (recField?.value === 'recording') {
					const startedAt = 'startedAt' in recField ? recField.startedAt : undefined
					if (startedAt) {
						vals[`${cam.label}_rec_time`] = formatRecTime(startedAt)
					}
				}
			}
			if (Object.keys(vals).length > 0) this.setVariableValues(vals)
		}, 1000)
	}

	private _stopRecTimer(): void {
		if (this.recTimerInterval !== null) {
			clearInterval(this.recTimerInterval)
			this.recTimerInterval = null
		}
	}

	private _teardown(): void {
		this._stopRecTimer()
		this.drives.stopAll()
		if (this.client) {
			this.client.destroy()
			this.client = null
		}
	}
}
