// Tiles Companion Module — unit tests

import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals'
import { readFileSync } from 'fs'
import { createServer } from 'net'
import { fileURLToPath } from 'url'
import { WebSocketServer } from 'ws'
import { TwccClient, heartbeat } from '../src/client.js'
import { createState, applySnapshot, applyChanges, applyCamerasUpdate, markAllUnknown } from '../src/state.js'
import { buildFeedbacks } from '../src/feedbacks.js'
import { buildVariableValues, formatPlaybackTime } from '../src/variables.js'
import { ALL_FIELD_NAMES } from '../src/protocol.js'
import { BOOL_FIELDS, buildActions, LensDrives } from '../src/actions.js'
import { buildPresets } from '../src/presets.js'
import { FakeTwccServer, DEMO_TOKEN, BAD_TOKEN, makeDemoCamera, makeDemoPage } from './fake-server.js'
import type { TwccState } from '../src/state.js'

/** A port nothing here is listening on, from the system: a fixed range can collide with ports other apps hold,
 *  failing tests silently. */
async function nextPort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const probe = createServer()
		probe.on('error', reject)
		probe.listen(0, () => {
			const address = probe.address()
			const port = typeof address === 'object' && address ? address.port : 0
			probe.close(() => resolve(port))
		})
	})
}
function sleep(ms: number): Promise<void> { return new Promise((r) => setTimeout(r, ms)) }

// Helper: connect and wait for snapshot
async function connectAndSubscribe(client: TwccClient, state: TwccState, port: number): Promise<void> {
	await new Promise<void>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error('connect timeout')), 4000)
		client.on('message', (msg) => {
			if (msg.type === 'hello') {
				applySnapshot(state, msg.cameras, msg.pages, msg.radio, msg.locked)
			}
			if (msg.type === 'snapshot') {
				applySnapshot(state, msg.cameras, msg.pages, msg.radio, msg.locked)
				clearTimeout(timer)
				resolve()
			}
		})
		client.connect()
	})
}

// ---- Auth ----

describe('Auth', () => {
	it('connects with correct token', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			client.once('connected', () => { clearTimeout(timer); resolve() })
			client.connect()
		})
		client.destroy(); await server.close()
	})

	it('fires authFailed on bad token and does not subscribe', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const client = new TwccClient({ host: '127.0.0.1', port, token: BAD_TOKEN })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			client.once('authFailed', () => { clearTimeout(timer); resolve() })
			client.connect()
		})
		await sleep(300)
		expect(server.receivedMessages.filter((m) => m.type === 'subscribe').length).toBe(0)
		client.destroy(); await server.close()
	})
})

// ---- Snapshot / variables ----

describe('Snapshot and variables', () => {
	let port: number, server: FakeTwccServer, client: TwccClient, state: TwccState

	beforeEach(async () => {
		port = await nextPort(); server = new FakeTwccServer({ port })
		state = createState(); client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)
	})
	afterEach(async () => { client.destroy(); await server.close() })

	it('state keyed by camera ID', () => {
		expect(state.cameras.has('uuid-A')).toBe(true)
		expect(state.cameras.has('uuid-B')).toBe(true)
		// NOT keyed by label
		expect(state.cameras.has('A')).toBe(false)
	})

	it('variables use label prefix', () => {
		const vals = buildVariableValues(state)
		expect(vals['A_rec_state']).toBe('idle')
		expect(vals['A_iso']).toBe('800')
		expect(vals['A_model']).toBe('ILME-FX3')
		expect(vals['A_id']).toBe('uuid-A')
	})

	it('rec_time is 00:00:00 when idle', () => {
		expect(buildVariableValues(state)['A_rec_time']).toBe('00:00:00')
	})
})

// ---- Changes update variables ----

describe('Changes messages update variables', () => {
	let port: number, server: FakeTwccServer, client: TwccClient, state: TwccState

	beforeEach(async () => {
		port = await nextPort(); server = new FakeTwccServer({ port })
		state = createState(); client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)
	})
	afterEach(async () => { client.destroy(); await server.close() })

	it('ISO change via changes message updates variable', async () => {
		let gotChange = false
		client.on('message', (msg) => {
			if (msg.type === 'changes' && msg.cameraID === 'uuid-A') {
				applyChanges(state, msg.cameraID, msg.update, msg.removed)
				gotChange = true
			}
		})
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { set: 'iso', value: 3200 } })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('changes timeout')), 3000)
			const check = setInterval(() => { if (gotChange) { clearInterval(check); clearTimeout(timer); resolve() } }, 20)
		})
		expect(buildVariableValues(state)['A_iso']).toBe('3200')
	})
})

// ---- Action wire format: cameraID / pageID targets ----

describe('Action wire format', () => {
	let port: number, server: FakeTwccServer, client: TwccClient

	beforeEach(async () => {
		port = await nextPort(); server = new FakeTwccServer({ port })
		client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			client.once('connected', () => { clearTimeout(timer); setTimeout(resolve, 100) })
			client.connect()
		})
	})
	afterEach(async () => { client.destroy(); await server.close() })

	it('REC start sends cameraID target', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { set: 'record', value: 'recording' } })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'command' && 'target' in m && 'cameraID' in m.target && m.target.cameraID === 'uuid-A')
		expect(msg).toBeDefined()
	})

	it('REC stop sends cameraID target', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { set: 'record', value: 'idle' } })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'command' && 'target' in m && 'cameraID' in m.target)
		expect(msg).toBeDefined()
		if (msg && msg.type === 'command' && 'set' in msg.command) expect(msg.command.value).toBe('idle')
	})

	it('REC toggle sends toggle record with cameraID', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { toggle: 'record' } })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'command' && 'toggle' in m.command && m.command.toggle === 'record' && 'cameraID' in m.target)
		expect(msg).toBeDefined()
	})

	it('field_set sends cameraID target', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { set: 'iso', value: 1600 } })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'command' && 'set' in m.command && m.command.set === 'iso' && 'cameraID' in m.target)
		expect(msg).toBeDefined()
		if (msg && msg.type === 'command' && 'set' in msg.command) expect(msg.command.value).toBe(1600)
	})

	it('field_step sends cameraID target', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { step: 'iso', by: 1 } })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'command' && 'step' in m.command && 'cameraID' in m.target)
		expect(msg).toBeDefined()
	})

	it('field_cycle sends cameraID target', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { cycle: 'wbPreset' } })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'command' && 'cycle' in m.command && 'cameraID' in m.target)
		expect(msg).toBeDefined()
	})

	it('showPage sends pageID', async () => {
		client.send({ type: 'app', action: 'showPage', pageID: 'page-uuid-1' })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'showPage' && 'pageID' in m && m.pageID === 'page-uuid-1')
		expect(msg).toBeDefined()
	})

	it('setLinking sends pageID', async () => {
		client.send({ type: 'app', action: 'setLinking', pageID: 'page-uuid-1', enabled: true })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'setLinking' && 'pageID' in m && m.pageID === 'page-uuid-1')
		expect(msg).toBeDefined()
	})

	it('setLink sends pageID and group', async () => {
		client.send({ type: 'app', action: 'setLink', pageID: 'page-uuid-1', group: 'whiteBalance', enabled: false })
		await sleep(100)
		const msg = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'setLink' && 'pageID' in m && 'group' in m && m.group === 'whiteBalance')
		expect(msg).toBeDefined()
	})
})

// ---- Feedback logic ----

describe('Feedback logic', () => {
	it('recording false when idle', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['recording']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'recording' }, undefined as never)).toBe(false)
	})

	it('recording true only after camera confirms', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.record = { value: 'recording', writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['recording']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'recording' }, undefined as never)).toBe(true)
	})

	it('recording false for disconnected camera even if value is recording', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A', false)
		cam.fields.record = { value: 'recording', writable: false }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['recording']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'recording' }, undefined as never)).toBe(false)
	})

	it('rec_unknown true for offline camera', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A', false)
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['rec_unknown']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'rec_unknown' }, undefined as never)).toBe(true)
	})

	it('rec_unknown false for connected idle camera', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['rec_unknown']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'rec_unknown' }, undefined as never)).toBe(false)
	})

	it('REC never shown red before camera confirms', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.record = { value: 'idle', writable: true, request: 'start' }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fbs = buildFeedbacks(state)
		const recFb = fbs['recording']
		if (!recFb || recFb.type !== 'boolean') throw new Error()
		expect(recFb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'recording' }, undefined as never)).toBe(false)
		const pendFb = fbs['rec_pending']
		if (!pendFb || pendFb.type !== 'boolean') throw new Error()
		expect(pendFb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'rec_pending' }, undefined as never)).toBe(true)
	})

	it('radio_bars_below true when below threshold', () => {
		const state = createState()
		state.radio = { bars: 0.2 }
		const fb = buildFeedbacks(state)['radio_bars_below']
		if (!fb || fb.type !== 'boolean') throw new Error()
		expect(fb.callback({ options: { threshold: 0.3 }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'radio_bars_below' }, undefined as never)).toBe(true)
	})

	it('radio_bars_below false when above threshold', () => {
		const state = createState()
		state.radio = { bars: 0.8 }
		const fb = buildFeedbacks(state)['radio_bars_below']
		if (!fb || fb.type !== 'boolean') throw new Error()
		expect(fb.callback({ options: { threshold: 0.3 }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'radio_bars_below' }, undefined as never)).toBe(false)
	})
})

// ---- Camera rename keeps buttons on same camera ----

describe('Camera rename', () => {
	it('buttons (keyed by id) still target the right camera after rename', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const state = createState()
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)

		// Simulate server pushing a cameras message with a renamed label
		const renamed = server.cameras.map((c) => c.id === 'uuid-A' ? { ...c, label: 'X' } : c)
		await new Promise<void>((resolve) => {
			client.once('message', (msg) => {
				if (msg.type === 'cameras') { applyCamerasUpdate(state, msg.cameras); resolve() }
			})
			server.pushCameras(renamed)
		})

		// Camera uuid-A is now label X; the UUID is still in the map
		expect(state.cameras.has('uuid-A')).toBe(true)
		expect(state.cameras.get('uuid-A')?.label).toBe('X')
		// Variables now live under the new label
		const vals = buildVariableValues(state)
		expect(vals['X_model']).toBe('ILME-FX3')
		// Old label variable is gone (camera map is the authority)
		expect(vals['A_model']).toBeUndefined()

		client.destroy(); await server.close()
	})
})

// ---- Radio message updates bars feedback ----

describe('Radio message', () => {
	it('radio message updates state and bars feedback evaluates correctly', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const state = createState()
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)

		await new Promise<void>((resolve) => {
			client.once('message', (msg) => {
				if (msg.type === 'radio') { state.radio = msg.radio; resolve() }
			})
			server.pushRadio({ bars: 0.15, haLow: [{ name: 'vv-node-1', signalDBm: -72, state: 'polling' }] })
		})

		expect(state.radio?.bars).toBe(0.15)
		const vals = buildVariableValues(state)
		expect(vals['radio_bars']).toBe('0.15')
		expect(vals['halow_signal_dbm']).toBe('-72')

		const fb = buildFeedbacks(state)['radio_bars_below']
		if (!fb || fb.type !== 'boolean') throw new Error()
		expect(fb.callback({ options: { threshold: 0.3 }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'radio_bars_below' }, undefined as never)).toBe(true)

		client.destroy(); await server.close()
	})
})

// ---- Rejected REC (unknown state) ----

describe('Rejected results', () => {
	it('toggle on unknown REC returns rejected — not retried', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		// Make camera offline so REC is unknown
		server.cameras = server.cameras.map((c) => c.id === 'uuid-A' ? { ...c, connection: 'disconnected' as const, fields: { ...c.fields, record: { value: 'unknown' as const, writable: false } } } : c)
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			client.once('connected', () => { clearTimeout(timer); setTimeout(resolve, 100) })
			client.connect()
		})

		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { toggle: 'record' } })
		await sleep(150)

		// Server should have sent a rejected result
		const msgs = server.receivedMessages
		const toggleMsg = msgs.find((m) => m.type === 'command' && 'toggle' in m.command && m.command.toggle === 'record')
		expect(toggleMsg).toBeDefined()
		// Only one command sent — not retried
		const allToggles = msgs.filter((m) => m.type === 'command' && 'command' in m && 'toggle' in m.command && m.command.toggle === 'record')
		expect(allToggles.length).toBe(1)

		client.destroy(); await server.close()
	})
})

// ---- Reconnect ----

describe('Reconnect', () => {
	it('client reconnects after server drops connection', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			client.once('connected', () => { clearTimeout(timer); resolve() })
			client.connect()
		})
		for (const ws of server.clients) ws.close()
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('reconnect timeout')), 5000)
			client.once('connected', () => { clearTimeout(timer); resolve() })
		})
		client.destroy(); await server.close()
	})
})

// ---- Bug regressions ----

describe('Bug: authFailed does not overwrite status with disconnected', () => {
	it('authFailed fires once; disconnected is NOT emitted afterwards', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const client = new TwccClient({ host: '127.0.0.1', port, token: BAD_TOKEN })
		const events: string[] = []
		client.on('authFailed', () => events.push('authFailed'))
		client.on('disconnected', () => events.push('disconnected'))
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			client.once('authFailed', () => { clearTimeout(timer); setTimeout(resolve, 200) })
			client.connect()
		})
		expect(events).toEqual(['authFailed'])
		expect(events).not.toContain('disconnected')
		client.destroy(); await server.close()
	})
})

describe('Bug: field_step does not double-scale by', () => {
	it('step kelvin by 1 sends by=1, not by=100 (step units, not raw units)', async () => {
		const port = await nextPort()
		const server = new FakeTwccServer({ port })
		const state = createState()
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)

		// buildActions with a send spy
		const sent: unknown[] = []
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => { sent.push(msg) }, new LensDrives())

		// Simulate field_step with by=1 on a kelvin field (level, step=100)
		const stepAction = actions['field_step']
		if (!stepAction || !('callback' in stepAction)) throw new Error('field_step not found')
		stepAction.callback({ options: { camera: 'uuid-A', field: 'kelvin', by: 1 }, id: '1', controlId: 'x', actionId: 'field_step' } as never, undefined as never)

		expect(sent.length).toBe(1)
		const msg = sent[0] as { type: string; command: { step: string; by: number } }
		expect(msg.command.by).toBe(1) // NOT 100
		expect(msg.command.step).toBe('kelvin')

		client.destroy(); await server.close()
	})
})

// ---- Fields added since 0.1.0 ----

describe('BURANO, VENICE and playback fields in ALL_FIELD_NAMES', () => {
	it('includes ndMode, tally, colorGamut, call, timecodeDuration, playbackMode, playing', () => {
		expect(ALL_FIELD_NAMES).toContain('ndMode')
		expect(ALL_FIELD_NAMES).toContain('tally')
		expect(ALL_FIELD_NAMES).toContain('colorGamut')
		expect(ALL_FIELD_NAMES).toContain('call')
		expect(ALL_FIELD_NAMES).toContain('timecodeDuration')
		expect(ALL_FIELD_NAMES).toContain('playbackMode')
		expect(ALL_FIELD_NAMES).toContain('playing')
	})
})

describe('API fields', () => {
	// The fields table in docs/control-api.md ("All fields"), every name in each row's first cell.
	function documentedFields(): string[] {
		const doc = readFileSync(fileURLToPath(new URL('../../../docs/control-api.md', import.meta.url)), 'utf8')
		const names: string[] = []
		let inTable = false
		for (const line of doc.split('\n')) {
			if (line.startsWith('### All fields')) {
				inTable = true
				continue
			}
			if (inTable && line.startsWith('#')) break
			if (inTable && line.startsWith('| `')) {
				names.push(...[...line.split('|')[1].matchAll(/`([A-Za-z]+)`/g)].map((m) => m[1]))
			}
		}
		return names
	}

	it('every field the API documents is one the module offers, and no other', () => {
		const documented = documentedFields()
		expect(documented.length).toBeGreaterThan(40)
		expect([...ALL_FIELD_NAMES].filter((f) => !documented.includes(f))).toEqual([])
		expect(documented.filter((f) => !(ALL_FIELD_NAMES as readonly string[]).includes(f))).toEqual([])
	})
})

describe('FX6 and VENICE fields', () => {
	it('every one the app sets over the API is a field, the on/off ones toggles', () => {
		for (const f of ['userFrameA', 'userFrameB', 'shootingMode', 'gain', 'baseSensitivity', 'recordedLUT', 'proxy', 'ecs', 'irisAuto', 'ndAuto', 'isoAuto', 'steadyShot', 'imagerMode']) {
			expect(ALL_FIELD_NAMES).toContain(f)
		}
		for (const f of ['recordedLUT', 'proxy', 'ecs', 'irisAuto', 'ndAuto', 'isoAuto']) {
			expect(BOOL_FIELDS).toContain(f)
		}
	})
})

describe('BURANO, VENICE and playback bool fields', () => {
	it('BOOL_FIELDS includes call, timecodeDuration, playing', () => {
		expect(BOOL_FIELDS).toContain('call')
		expect(BOOL_FIELDS).toContain('timecodeDuration')
		expect(BOOL_FIELDS).toContain('playing')
	})
})

// ---- Playback action wire format ----

describe('Playback command action', () => {
	let port: number, server: FakeTwccServer, client: TwccClient, state: TwccState

	beforeEach(async () => {
		port = await nextPort(); server = new FakeTwccServer({ port })
		state = createState(); client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)
	})
	afterEach(async () => { client.destroy(); await server.close() })

	it('playback_command sends {playback: "togglePlay"} message', async () => {
		const sent: unknown[] = []
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => { sent.push(msg) }, new LensDrives())
		const action = actions['playback_command']
		if (!action || !('callback' in action)) throw new Error('playback_command not found')
		action.callback({ options: { camera: 'uuid-A', command: 'togglePlay', by: 0 }, id: '1', controlId: 'x', actionId: 'playback_command' } as never, undefined as never)
		expect(sent.length).toBe(1)
		const msg = sent[0] as { type: string; command: { playback: string } }
		expect(msg.command.playback).toBe('togglePlay')
		expect('by' in msg.command).toBe(false)
	})

	it('playback_command skip sends {playback: "skip", by: -5}', async () => {
		const sent: unknown[] = []
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => { sent.push(msg) }, new LensDrives())
		const action = actions['playback_command']
		if (!action || !('callback' in action)) throw new Error('playback_command not found')
		action.callback({ options: { camera: 'uuid-A', command: 'skip', by: -5 }, id: '1', controlId: 'x', actionId: 'playback_command' } as never, undefined as never)
		expect(sent.length).toBe(1)
		const msg = sent[0] as { type: string; command: { playback: string; by: number } }
		expect(msg.command.playback).toBe('skip')
		expect(msg.command.by).toBe(-5)
	})

	it('playback_command reaches fake server and returns accepted', async () => {
		client.send({ type: 'command', target: { cameraID: 'uuid-A' }, command: { playback: 'next' } })
		await sleep(100)
		const found = server.receivedMessages.find((m) => m.type === 'command' && 'playback' in m.command)
		expect(found).toBeDefined()
	})
})

// ---- Playback feedbacks and variables ----

describe('Playback feedbacks', () => {
	it('playing feedback true when playing field is true', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.playing = { value: true, options: [false, true], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['playing']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'playing' }, undefined as never)).toBe(true)
	})

	it('playing feedback false when playing field is false', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.playing = { value: false, options: [false, true], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['playing']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'playing' }, undefined as never)).toBe(false)
	})

	it('in_review true when playbackMode is "review"', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.playbackMode = { value: 'review', options: ['live', 'review'], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['in_review']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'in_review' }, undefined as never)).toBe(true)
	})

	it('in_review false when playbackMode is "live"', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.playbackMode = { value: 'live', options: ['live', 'review'], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['in_review']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'in_review' }, undefined as never)).toBe(false)
	})
})

describe('Playback variables', () => {
	it('playback variables populate from camera.playback', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.playback = { clip: 'A001C003', clipNumber: 2, clipCount: 5, position: 73.0, duration: 125.0, commands: ['play', 'pause'] }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const vals = buildVariableValues(state)
		expect(vals['A_pb_clip']).toBe('A001C003')
		expect(vals['A_pb_clip_number']).toBe('2')
		expect(vals['A_pb_clip_count']).toBe('5')
		expect(vals['A_pb_position']).toBe('1:13')
		expect(vals['A_pb_duration']).toBe('2:05')
	})

	it('playback variables are empty when no playback', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const vals = buildVariableValues(state)
		expect(vals['A_pb_clip']).toBe('')
		expect(vals['A_pb_clip_number']).toBe('')
	})

	it('formatPlaybackTime formats seconds as m:ss', () => {
		expect(formatPlaybackTime(0)).toBe('0:00')
		expect(formatPlaybackTime(60)).toBe('1:00')
		expect(formatPlaybackTime(73)).toBe('1:13')
		expect(formatPlaybackTime(125)).toBe('2:05')
		expect(formatPlaybackTime(undefined)).toBe('')
	})
})

describe('Playback state via changes message', () => {
	it('camera.playback updates via changes message', async () => {
		const port = await nextPort(); const server = new FakeTwccServer({ port })
		const state = createState(); const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)

		let gotChange = false
		client.on('message', (msg) => {
			if (msg.type === 'changes') {
				applyChanges(state, msg.cameraID, msg.update, msg.removed)
				gotChange = true
			}
		})
		server.pushPlayback('uuid-A', { clip: 'B002C001', clipNumber: 1, clipCount: 3, position: 5.0, duration: 30.0, commands: ['play'] })
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			const check = setInterval(() => { if (gotChange) { clearInterval(check); clearTimeout(timer); resolve() } }, 20)
		})
		expect(state.cameras.get('uuid-A')?.playback?.clip).toBe('B002C001')
		expect(buildVariableValues(state)['A_pb_clip']).toBe('B002C001')

		client.destroy(); await server.close()
	})

	it('camera.playback clears when null pushed', async () => {
		const port = await nextPort(); const server = new FakeTwccServer({ port })
		const state = createState(); const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)

		// Seed with playback
		const cam = state.cameras.get('uuid-A')
		if (cam) cam.playback = { clip: 'X', clipNumber: 1, clipCount: 1, commands: [] }

		let gotChange = false
		client.on('message', (msg) => {
			if (msg.type === 'changes') {
				applyChanges(state, msg.cameraID, msg.update, msg.removed)
				gotChange = true
			}
		})
		server.pushPlayback('uuid-A', null)
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			const check = setInterval(() => { if (gotChange) { clearInterval(check); clearTimeout(timer); resolve() } }, 20)
		})
		expect(state.cameras.get('uuid-A')?.playback).toBeNull()

		client.destroy(); await server.close()
	})
})

// ---- Lock action + feedback + variable ----

describe('Lock controls action', () => {
	let port: number, server: FakeTwccServer, client: TwccClient, state: TwccState

	beforeEach(async () => {
		port = await nextPort(); server = new FakeTwccServer({ port })
		state = createState(); client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)
	})
	afterEach(async () => { client.destroy(); await server.close() })

	it('lock action sends setLocked true', async () => {
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => client.send(msg), new LensDrives())
		const action = actions['lock_controls']
		if (!action || !('callback' in action)) throw new Error('lock_controls not found')
		action.callback({ options: { mode: 'lock' }, id: '1', controlId: 'x', actionId: 'lock_controls' } as never, undefined as never)
		await sleep(150)
		const found = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'setLocked' && m.enabled === true)
		expect(found).toBeDefined()
	})

	it('unlock action sends setLocked false', async () => {
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => client.send(msg), new LensDrives())
		const action = actions['lock_controls']
		if (!action || !('callback' in action)) throw new Error('lock_controls not found')
		action.callback({ options: { mode: 'unlock' }, id: '1', controlId: 'x', actionId: 'lock_controls' } as never, undefined as never)
		await sleep(150)
		const found = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'setLocked' && m.enabled === false)
		expect(found).toBeDefined()
	})

	it('toggle sends setLocked true when currently unlocked', async () => {
		state.locked = false
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => client.send(msg), new LensDrives())
		const action = actions['lock_controls']
		if (!action || !('callback' in action)) throw new Error('lock_controls not found')
		action.callback({ options: { mode: 'toggle' }, id: '1', controlId: 'x', actionId: 'lock_controls' } as never, undefined as never)
		await sleep(150)
		const found = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'setLocked' && m.enabled === true)
		expect(found).toBeDefined()
	})

	it('toggle sends setLocked false when currently locked', async () => {
		state.locked = true
		const { buildActions } = await import('../src/actions.js')
		const actions = buildActions(state, (msg) => client.send(msg), new LensDrives())
		const action = actions['lock_controls']
		if (!action || !('callback' in action)) throw new Error('lock_controls not found')
		action.callback({ options: { mode: 'toggle' }, id: '1', controlId: 'x', actionId: 'lock_controls' } as never, undefined as never)
		await sleep(150)
		const found = server.receivedMessages.find((m) => m.type === 'app' && m.action === 'setLocked' && m.enabled === false)
		expect(found).toBeDefined()
	})
})

describe('Lock feedback and variable', () => {
	it('controls_locked feedback false when not locked', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		state.locked = false
		const fb = buildFeedbacks(state)['controls_locked']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: {}, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'controls_locked' }, undefined as never)).toBe(false)
	})

	it('controls_locked feedback true when locked', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		state.locked = true
		const fb = buildFeedbacks(state)['controls_locked']
		if (!fb || fb.type !== 'boolean') throw new Error('not found')
		expect(fb.callback({ options: {}, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'controls_locked' }, undefined as never)).toBe(true)
	})

	it('locked variable reflects state', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		state.locked = true
		expect(buildVariableValues(state)['locked']).toBe('true')
		state.locked = false
		expect(buildVariableValues(state)['locked']).toBe('false')
	})
})

describe('Lock via server broadcast', () => {
	it('lock broadcast updates state and variable', async () => {
		const port = await nextPort(); const server = new FakeTwccServer({ port })
		const state = createState(); const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)

		let gotLock = false
		client.on('message', (msg) => {
			if (msg.type === 'lock') { state.locked = msg.locked; gotLock = true }
		})
		server.pushLock(true)
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('timeout')), 3000)
			const check = setInterval(() => { if (gotLock) { clearInterval(check); clearTimeout(timer); resolve() } }, 20)
		})
		expect(state.locked).toBe(true)
		expect(buildVariableValues(state)['locked']).toBe('true')

		client.destroy(); await server.close()
	})

	it('hello carries locked=true from server', async () => {
		const port = await nextPort(); const server = new FakeTwccServer({ port })
		server.locked = true
		const state = createState(); const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		await connectAndSubscribe(client, state, port)
		expect(state.locked).toBe(true)
		client.destroy(); await server.close()
	})
})

// ---- Presets: the transport row and the lock ----

describe('Playback presets', () => {
	it('Live / Review cycles playbackMode, which the server flips either way (it won\'t toggle a string)', async () => {
		const { buildPresets } = await import('../src/presets.js')
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-a', 'A')], [makeDemoPage('page-all', 'All', ['uuid-a'], true)])
		const { presets } = buildPresets(state)
		const preset = Object.entries(presets).find(([id]) => id.endsWith('_pb_live_review'))?.[1] as any
		expect(preset).toBeDefined()
		expect(preset.steps[0].down[0]).toEqual({ actionId: 'field_cycle', options: { camera: 'uuid-a', field: 'playbackMode' } })
		const lock = (presets as any)['global_lock']
		expect(lock.steps[0].down[0]).toEqual({ actionId: 'lock_controls', options: { mode: 'toggle' } })
	})
})

// ---- The link going quiet or never coming up ----

describe('Link hygiene', () => {
	it('destroying a client while its socket is still connecting ends quietly (no unhandled error)', async () => {
		// A server that takes the TCP connection and never answers the handshake: the socket stays CONNECTING.
		const held: import('net').Socket[] = []
		const silent = createServer((socket) => { held.push(socket) })
		const port = await nextPort()
		await new Promise<void>((resolve) => silent.listen(port, '127.0.0.1', () => resolve()))
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		client.connect()
		await sleep(100)
		expect(() => client.destroy()).not.toThrow()
		await sleep(200)  // an unhandled 'error' would surface here and fail the run
		for (const socket of held) socket.destroy()
		await new Promise<void>((resolve) => silent.close(() => resolve()))
	})

	it('a host the URL cannot take is reported and retried, not thrown', async () => {
		const client = new TwccClient({ host: 'not a host', port: 51800, token: DEMO_TOKEN })
		const problems: string[] = []
		client.on('problem', (text) => problems.push(text))
		expect(() => client.connect()).not.toThrow()
		expect(problems.length).toBe(1)
		client.destroy()
	})

	it('a socket the app goes quiet on is dropped after the heartbeat limit', async () => {
		const saved = { ...heartbeat }
		heartbeat.intervalMs = 50
		heartbeat.limitMs = 200
		// Opens, then says nothing: no hello, no pong.
		const port = await nextPort()
		const mute = new WebSocketServer({ port })
		const client = new TwccClient({ host: '127.0.0.1', port, token: DEMO_TOKEN })
		const dropped = new Promise<string>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error('not dropped')), 3000)
			client.on('problem', (text) => { if (text.includes('nothing from the app')) { clearTimeout(timer); resolve(text) } })
		})
		client.connect()
		await expect(dropped).resolves.toContain('nothing from the app')
		client.destroy()
		Object.assign(heartbeat, saved)
		await new Promise<void>((resolve) => mute.close(() => resolve()))
	})

	it('a dropped link leaves nothing known: REC unknown, cameras disconnected, no playback', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.record = { value: 'recording', writable: true, startedAt: new Date().toISOString() }
		applySnapshot(state, [cam], [])
		markAllUnknown(state)
		const after = state.cameras.get('uuid-A')!
		expect(after.connection).toBe('disconnected')
		expect((after.fields.record as { value: string }).value).toBe('unknown')
		expect(after.playback).toBeNull()
	})
})

// ---- FX6 lens drives and assignable buttons ----

type Sent = { command: { drive?: string; speed?: number; seconds?: number; press?: string; button?: number } }

describe('Focus and Zoom drives: held from a button', () => {
	beforeEach(() => { jest.useFakeTimers() })
	afterEach(() => { jest.useRealTimers() })

	function run(actionId: string, options: Record<string, unknown>, sent: Sent[], drives: LensDrives): void {
		const action = buildActions(createState(), (msg) => { sent.push(msg as Sent) }, drives)[actionId]
		if (!action || !('callback' in action)) throw new Error(`${actionId} not found`)
		void action.callback({ options, id: '1', controlId: 'x', actionId } as never, undefined as never)
	}

	it('drives at once and every 250 ms, then the up action stops it once', () => {
		const sent: Sent[] = [], drives = new LensDrives()
		run('focus_drive', { camera: 'uuid-A', direction: 'far', speed: 3 }, sent, drives)
		expect(sent).toEqual([{ type: 'command', target: { cameraID: 'uuid-A' }, command: { drive: 'focus', speed: 3, seconds: 0.5 } }])
		jest.advanceTimersByTime(760)
		expect(sent).toHaveLength(4)
		run('focus_stop', { camera: 'uuid-A' }, sent, drives)
		jest.advanceTimersByTime(1000)
		expect(sent).toHaveLength(5)
		expect(sent[4].command).toEqual({ drive: 'focus', speed: 0 })
		expect(drives.count).toBe(0)
	})

	it('Near and Wide are the motors\' − way', () => {
		const sent: Sent[] = [], drives = new LensDrives()
		run('focus_drive', { camera: 'uuid-A', direction: 'near', speed: 5 }, sent, drives)
		run('zoom_drive', { camera: 'uuid-A', direction: 'wide', speed: 2 }, sent, drives)
		run('zoom_drive', { camera: 'uuid-B', direction: 'tele', speed: 2 }, sent, drives)
		expect(sent.map((m) => [m.command.drive, m.command.speed])).toEqual([['focus', -5], ['zoom', -2], ['zoom', 2]])
		drives.stopAll()
	})

	it('pressed again while held: one renewal, not two', () => {
		const sent: Sent[] = [], drives = new LensDrives()
		run('focus_drive', { camera: 'uuid-A', direction: 'far', speed: 3 }, sent, drives)
		run('focus_drive', { camera: 'uuid-A', direction: 'far', speed: 3 }, sent, drives)
		jest.advanceTimersByTime(260)
		expect(sent).toHaveLength(3)
		drives.stopAll()
	})

	it('the connection or the module going stops every renewal', () => {
		const sent: Sent[] = [], drives = new LensDrives()
		run('focus_drive', { camera: 'uuid-A', direction: 'far', speed: 3 }, sent, drives)
		run('zoom_drive', { camera: 'uuid-A', direction: 'tele', speed: 3 }, sent, drives)
		drives.stopAll()
		jest.advanceTimersByTime(1000)
		expect(sent).toHaveLength(2)
		expect(drives.count).toBe(0)
	})
})

describe('Autofocus action', () => {
	it('pushes autofocus, with no button number', () => {
		const sent: Sent[] = []
		const actions = buildActions(createState(), (msg) => { sent.push(msg as Sent) }, new LensDrives())
		const action = actions['push_autofocus']
		if (!action || !('callback' in action)) throw new Error('push_autofocus not found')
		void action.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', actionId: 'push_autofocus' } as never, undefined as never)
		expect(sent.map((m) => m.command)).toEqual([{ press: 'autofocus' }])
	})
})

describe('Grab Still action', () => {
	it('sends press still for the chosen camera', () => {
		const sent: Sent[] = []
		const actions = buildActions(createState(), (msg) => { sent.push(msg as Sent) }, new LensDrives())
		const action = actions['grab_still']
		if (!action || !('callback' in action)) throw new Error('grab_still not found')
		void action.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', actionId: 'grab_still' } as never, undefined as never)
		expect(sent.map((m) => m.command)).toEqual([{ press: 'still' }])
	})
})

describe('Assignable button action', () => {
	it('presses the button by its number, 1 to 10', () => {
		const sent: Sent[] = []
		const actions = buildActions(createState(), (msg) => { sent.push(msg as Sent) }, new LensDrives())
		const action = actions['press_assignable']
		if (!action || !('callback' in action)) throw new Error('press_assignable not found')
		void action.callback({ options: { camera: 'uuid-A', button: 2 }, id: '1', controlId: 'x', actionId: 'press_assignable' } as never, undefined as never)
		void action.callback({ options: { camera: 'uuid-A', button: 12 }, id: '2', controlId: 'x', actionId: 'press_assignable' } as never, undefined as never)
		expect(sent.map((m) => m.command)).toEqual([{ press: 'assignable', button: 2 }, { press: 'assignable', button: 10 }])
	})
})

// ---- Field label quality: no raw camelCase in user-visible lists ----

import { BOOL_FIELD_LABELS } from '../src/actions.js'

describe('boolFieldChoices: no raw camelCase labels', () => {
	it('every label in boolFieldChoices differs from its raw field id', () => {
		for (const id of BOOL_FIELDS) {
			const label = BOOL_FIELD_LABELS[id]
			expect(label).toBeDefined()
			expect(label).not.toBe(id)
		}
	})
})

describe('fieldChoices: no raw camelCase labels', () => {
	it('every label in fieldChoices differs from its raw field id', () => {
		const actions = buildActions(createState(), () => {}, new LensDrives())
		const stepAction = actions['field_step']
		if (!stepAction || !('options' in stepAction)) throw new Error('field_step not found')
		const opts = stepAction.options as Array<{ type: string; choices?: Array<{ id: string; label: string }> }>
		const fieldOpt = opts.find((o) => o.type === 'dropdown' && o.choices)
		if (!fieldOpt?.choices) throw new Error('field dropdown not found')
		for (const { id, label } of fieldOpt.choices) {
			expect(label).not.toBe(id)
		}
	})
})

describe('shutter presets respect shutterMode', () => {
	it('steps shutterAngle in angle mode (default)', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-a', 'A')], [makeDemoPage('p1', 'A', ['uuid-a'])])
		const { presets } = buildPresets(state)
		const down = (presets as never as Record<string, { steps: Array<{ down: Array<{ actionId: string; options: { field: string } }> }> }>)['cam_uuid-a_shutter_down']
		expect(down.steps[0].down[0].options.field).toBe('shutterAngle')
	})

	it('steps shutterSpeed in speed mode', () => {
		const state = createState()
		const camData = makeDemoCamera('uuid-a', 'A')
		camData.fields.shutterMode = { value: 'speed', options: ['angle', 'speed'], writable: true }
		applySnapshot(state, [camData], [makeDemoPage('p1', 'A', ['uuid-a'])])
		const { presets } = buildPresets(state)
		const up = (presets as never as Record<string, { steps: Array<{ down: Array<{ actionId: string; options: { field: string } }> }> }>)['cam_uuid-a_shutter_up']
		expect(up.steps[0].down[0].options.field).toBe('shutterSpeed')
	})
})

describe('boolean fields show ON / OFF in variables', () => {
	it('look (LUT) shows ON when true, OFF when false', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.look = { value: true, options: [false, true], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		expect(buildVariableValues(state)['A_look']).toBe('ON')
		cam.fields.look = { value: false, options: [false, true], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		expect(buildVariableValues(state)['A_look']).toBe('OFF')
	})

	it('falseColor shows ON / OFF', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.fields.falseColor = { value: true, options: [false, true], writable: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		expect(buildVariableValues(state)['A_falseColor']).toBe('ON')
	})
})

describe('REC preset names include camera label', () => {
	it('rec preset name contains the camera label', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-a', 'A')], [makeDemoPage('p1', 'A', ['uuid-a'])])
		const { presets } = buildPresets(state)
		const recPreset = presets['cam_uuid-a_rec'] as { name: string } | undefined
		expect(recPreset).toBeDefined()
		expect(recPreset!.name).toContain('A')
	})
})

describe('Grab Still feedback', () => {
	it('grab_still_saved false when no lastStill', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-A', 'A')], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['grab_still_saved']
		if (!fb || fb.type !== 'boolean') throw new Error('grab_still_saved not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'grab_still_saved' }, undefined as never)).toBe(false)
	})

	it('grab_still_saved true when lastStill.saved = true', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.lastStill = { saved: true }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['grab_still_saved']
		if (!fb || fb.type !== 'boolean') throw new Error('grab_still_saved not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'grab_still_saved' }, undefined as never)).toBe(true)
	})

	it('grab_still_saved false when lastStill.saved = false', () => {
		const state = createState()
		const cam = makeDemoCamera('uuid-A', 'A')
		cam.lastStill = { saved: false, message: 'No media' }
		applySnapshot(state, [cam], [makeDemoPage('p1', 'A', ['uuid-A'])])
		const fb = buildFeedbacks(state)['grab_still_saved']
		if (!fb || fb.type !== 'boolean') throw new Error('grab_still_saved not found')
		expect(fb.callback({ options: { camera: 'uuid-A' }, id: '1', controlId: 'x', type: 'boolean', previousOptions: null, feedbackId: 'grab_still_saved' }, undefined as never)).toBe(false)
	})

	it('grab_still preset exists for each camera', () => {
		const state = createState()
		applySnapshot(state, [makeDemoCamera('uuid-a', 'A')], [makeDemoPage('p1', 'A', ['uuid-a'])])
		const { presets } = buildPresets(state)
		const preset = presets['cam_uuid-a_grab_still'] as { name: string } | undefined
		expect(preset).toBeDefined()
		expect(preset!.name).toBe('Grab Still')
	})
})
