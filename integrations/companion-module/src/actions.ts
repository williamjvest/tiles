import type { CompanionActionDefinitions, CompanionActionEvent } from '@companion-module/base'
import type { TwccState } from './state.js'
import type { Target, CommandMessage, AppMessage, FieldName, PlaybackCommand, DriveMotor } from './protocol.js'
import { isChoiceField } from './protocol.js'
import { asText, asNumber } from './options.js'

// ─── Held lens drives ──────────────────────────────────────────────────────────

/** A held button's drive goes out this often, each running this long: the app lets a newer one take over. */
const DRIVE_RENEW_MS = 250
const DRIVE_SECONDS = 0.5
/** An FX6's fastest. */
const DRIVE_MAX_SPEED = 8

/**
 * Lens drives held from a button, one per camera and motor: the drive at once and every 250 ms (each runs half a
 * second, and the app lets a newer one take over with no stop between) until the button's up action stops it. The
 * module stops them all when the connection goes or the module does.
 */
export class LensDrives {
	private readonly timers = new Map<string, ReturnType<typeof setInterval>>()

	start(key: string, drive: () => void): void {
		this.stop(key)
		drive()
		this.timers.set(key, setInterval(drive, DRIVE_RENEW_MS))
	}

	stop(key: string): void {
		const timer = this.timers.get(key)
		if (timer === undefined) return
		clearInterval(timer)
		this.timers.delete(key)
	}

	stopAll(): void {
		for (const timer of this.timers.values()) clearInterval(timer)
		this.timers.clear()
	}

	get count(): number {
		return this.timers.size
	}
}

/** A motor's two ways, its + way first. */
type DriveWays = [{ id: string; label: string }, { id: string; label: string }]
const FOCUS_WAYS: DriveWays = [
	{ id: 'far', label: 'Far' },
	{ id: 'near', label: 'Near' },
]
const ZOOM_WAYS: DriveWays = [
	{ id: 'tele', label: 'Tele' },
	{ id: 'wide', label: 'Wide' },
]

/** A drive action and its stop, for one motor. */
function driveActions(
	motor: DriveMotor,
	ways: DriveWays,
	state: TwccState,
	send: (msg: CommandMessage | AppMessage) => void,
	drives: LensDrives,
): CompanionActionDefinitions {
	const title = motor === 'focus' ? 'Focus' : 'Zoom'
	return {
		[`${motor}_drive`]: {
			name: `${title} — Drive`,
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'dropdown', id: 'direction', label: 'Direction', default: ways[0].id, choices: ways },
				{ type: 'number', id: 'speed', label: 'Speed (1–8)', default: 3, min: 1, max: DRIVE_MAX_SPEED },
			],
			callback: (action: CompanionActionEvent) => {
				const cameraId = asText(action.options.camera)
				const magnitude = Math.max(1, Math.min(DRIVE_MAX_SPEED, asNumber(action.options.speed, 3)))
				const speed = asText(action.options.direction) === ways[0].id ? magnitude : -magnitude
				const target = buildTarget(cameraId)
				drives.start(`${cameraId}:${motor}`, () =>
					send({ type: 'command', target, command: { drive: motor, speed, seconds: DRIVE_SECONDS } }),
				)
			},
		},
		[`${motor}_stop`]: {
			name: `${title} — Stop`,
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (action: CompanionActionEvent) => {
				const cameraId = asText(action.options.camera)
				drives.stop(`${cameraId}:${motor}`)
				send({ type: 'command', target: buildTarget(cameraId), command: { drive: motor, speed: 0 } })
			},
		},
	}
}

export const BOOL_FIELDS: FieldName[] = [
	'look',
	'falseColor',
	'colorBars',
	'imageFlip',
	'frameRateVariable',
	// On every output of a Blackmagic camera (the app sets one output at a time)
	'zebra',
	'focusAssist',
	'frameGuides',
	'frameGrids',
	'safeArea',
	'cleanFeed',
	'statusText',
	// Sony
	'hdmiInfo',
	'gridLines',
	// BURANO call; VENICE timecode/duration and Playback's play/pause
	'call',
	'timecodeDuration',
	'playing',
	// An FX6's
	'recordedLUT',
	'proxy',
	'ecs',
	'irisAuto',
	'ndAuto',
	'isoAuto',
	// A Sony's AF Assist
	'afAssist',
]

export const CURRENT_PAGE_ID = '__currentPage__'

/** Dropdown entries for camera selection: the current page's cameras, then each camera by its UUID. */
export function cameraChoices(state: TwccState): { id: string; label: string }[] {
	const choices: { id: string; label: string }[] = [{ id: CURRENT_PAGE_ID, label: 'Current Page' }]
	for (const [id, cam] of state.cameras) {
		choices.push({ id, label: `${cam.label} · ${cam.model}` })
	}
	return choices
}

// Dropdown entries for page selection: id is the page UUID
function pageChoices(state: TwccState): { id: string; label: string }[] {
	const choices: { id: string; label: string }[] = []
	for (const [id, page] of state.pages) {
		choices.push({ id, label: page.name })
	}
	return choices
}

function buildTarget(cameraId: string): Target {
	if (cameraId === CURRENT_PAGE_ID) return { currentPage: true }
	return { cameraID: cameraId }
}

function fieldChoices() {
	return [
		{ id: 'iso', label: 'ISO' },
		{ id: 'baseISO', label: 'Base ISO' },
		{ id: 'shutterMode', label: 'Shutter Mode' },
		{ id: 'shutterAngle', label: 'Shutter Angle' },
		{ id: 'shutterSpeed', label: 'Shutter Speed' },
		{ id: 'wbPreset', label: 'WB Preset' },
		{ id: 'kelvin', label: 'Kelvin' },
		{ id: 'tint', label: 'Tint' },
		{ id: 'iris', label: 'Iris' },
		{ id: 'ndPreset', label: 'ND Preset' },
		{ id: 'variableND', label: 'Variable ND' },
		{ id: 'frameRate', label: 'Frame Rate' },
		{ id: 'resolution', label: 'Resolution' },
		{ id: 'codec', label: 'Codec' },
		{ id: 'bitrate', label: 'Bitrate' },
		{ id: 'desqueeze', label: 'De-squeeze' },
		{ id: 'dynamicRange', label: 'Dynamic Range' },
		{ id: 'offSpeedRate', label: 'Off-Speed Rate' },
		{ id: 'zebraLevel', label: 'Zebra Level' },
		{ id: 'frameGuideRatio', label: 'Frame Guide Ratio' },
		{ id: 'lut', label: 'LUT' },
		{ id: 'focusMode', label: 'Focus Mode' },
		{ id: 'clipFlag', label: 'Clip Flag' },
		// A BURANO's
		{ id: 'ndMode', label: 'ND Mode (Step/Variable)' },
		{ id: 'tally', label: 'Tally' },
		{ id: 'colorGamut', label: 'Color Gamut' },
		// Playback's Live | Review switch (cycle flips it)
		{ id: 'playbackMode', label: 'Playback Mode (live/review)' },
		// A VENICE's (cycle steps through them as its own button does)
		{ id: 'userFrameA', label: 'User Frame A' },
		{ id: 'userFrameB', label: 'User Frame B' },
		// An FX6's
		{ id: 'shootingMode', label: 'Shooting Mode' },
		{ id: 'gain', label: 'Gain (dB)' },
		{ id: 'baseSensitivity', label: 'Base Sensitivity (Low/Mid/High)' },
		// An FX5's
		{ id: 'steadyShot', label: 'SteadyShot' },
		{ id: 'imagerMode', label: 'Imager Mode' },
		// A Sony's autofocus settings
		{ id: 'subjectRecognition', label: 'Subject Recognition AF' },
		{ id: 'focusArea', label: 'Focus Area' },
		{ id: 'afTransitionSpeed', label: 'AF Transition Speed (1–7)' },
		{ id: 'afSubjectShift', label: 'AF Subject Shift Sensitivity (1–5)' },
	]
}

/** Human labels for every boolean-toggle field, keyed by API field id. */
export const BOOL_FIELD_LABELS: Record<string, string> = {
	look: 'LUT',
	falseColor: 'False Color',
	colorBars: 'Color Bars',
	imageFlip: 'Sensor Flip',
	frameRateVariable: 'Frame Rate Variable',
	zebra: 'Zebra',
	focusAssist: 'Focus Assist',
	frameGuides: 'Frame Guides',
	frameGrids: 'Frame Grids',
	safeArea: 'Safe Area',
	cleanFeed: 'Clean Feed',
	statusText: 'Status Text',
	hdmiInfo: 'HDMI Info',
	gridLines: 'Grid Lines',
	call: 'Call',
	timecodeDuration: 'TC / Duration',
	playing: 'Playing',
	recordedLUT: 'Recorded LUT',
	proxy: 'Proxy',
	ecs: 'ECS',
	irisAuto: 'Iris Auto',
	ndAuto: 'ND Auto',
	isoAuto: 'ISO Auto',
	afAssist: 'AF Assist',
}

function boolFieldChoices() {
	return BOOL_FIELDS.map((f) => ({ id: f, label: BOOL_FIELD_LABELS[f] ?? f }))
}

export function buildActions(
	state: TwccState,
	send: (msg: CommandMessage | AppMessage) => void,
	drives: LensDrives,
): CompanionActionDefinitions {
	return {
		rec_start: {
			name: 'REC — Start',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (action: CompanionActionEvent) => {
				send({
					type: 'command',
					target: buildTarget(asText(action.options.camera)),
					command: { set: 'record', value: 'recording' },
				})
			},
		},

		rec_stop: {
			name: 'REC — Stop',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (action: CompanionActionEvent) => {
				send({
					type: 'command',
					target: buildTarget(asText(action.options.camera)),
					command: { set: 'record', value: 'idle' },
				})
			},
		},

		rec_toggle: {
			name: 'REC — Toggle',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (action: CompanionActionEvent) => {
				// toggle: server resolves from confirmed state; unknown → rejected (logged, not retried)
				send({ type: 'command', target: buildTarget(asText(action.options.camera)), command: { toggle: 'record' } })
			},
		},

		field_set: {
			name: 'Field — Set Value',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'dropdown', id: 'field', label: 'Field', default: 'iso', choices: fieldChoices() },
				{ type: 'textinput', id: 'value', label: 'Value', default: '' },
			],
			callback: (action: CompanionActionEvent) => {
				const rawValue = asText(action.options.value)
				let parsed: unknown = rawValue
				const n = Number(rawValue)
				if (!isNaN(n) && rawValue.trim() !== '') parsed = n

				const cameraId = asText(action.options.camera)
				if (cameraId !== CURRENT_PAGE_ID) {
					const cam = state.cameras.get(cameraId)
					if (cam) {
						const field = cam.fields[action.options.field as FieldName]
						if (field && isChoiceField(field)) {
							const opt = field.options.find((o) => String(o) === rawValue)
							if (opt !== undefined) parsed = opt
						}
					}
				}

				send({
					type: 'command',
					target: buildTarget(cameraId),
					command: { set: action.options.field as FieldName, value: parsed },
				})
			},
		},

		field_step: {
			name: 'Field — Step +/−',
			description: '1 step = one camera option (ISO stop, preset notch, etc.). Use +1 or −1 for most fields.',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'dropdown', id: 'field', label: 'Field', default: 'iso', choices: fieldChoices() },
				{ type: 'number', id: 'by', label: 'Steps (+ or −)', default: 1, min: -100, max: 100 },
			],
			callback: (action: CompanionActionEvent) => {
				// by is in step units per the API spec [control-api.md §step]
				send({
					type: 'command',
					target: buildTarget(asText(action.options.camera)),
					command: { step: action.options.field as FieldName, by: asNumber(action.options.by, 1) },
				})
			},
		},

		field_cycle: {
			name: 'Field — Cycle',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'dropdown', id: 'field', label: 'Field', default: 'wbPreset', choices: fieldChoices() },
			],
			callback: (action: CompanionActionEvent) => {
				send({
					type: 'command',
					target: buildTarget(asText(action.options.camera)),
					command: { cycle: action.options.field as FieldName },
				})
			},
		},

		field_toggle_bool: {
			name: 'Field — Toggle On/Off',
			description:
				'Toggle a boolean camera field. Examples: LUT, False Color, Zebra, Clean Feed, Status Text, HDMI Info.',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'dropdown', id: 'field', label: 'Bool Field', default: 'falseColor', choices: boolFieldChoices() },
			],
			callback: (action: CompanionActionEvent) => {
				send({
					type: 'command',
					target: buildTarget(asText(action.options.camera)),
					command: { toggle: action.options.field as FieldName },
				})
			},
		},

		app_show_page: {
			name: 'App — Show Page',
			options: [{ type: 'dropdown', id: 'pageID', label: 'Page', default: '', choices: pageChoices(state) }],
			callback: (action: CompanionActionEvent) => {
				send({ type: 'app', action: 'showPage', pageID: asText(action.options.pageID) })
			},
		},

		app_set_linking: {
			name: 'App — Set Page Linking On/Off/Toggle',
			options: [
				{ type: 'dropdown', id: 'pageID', label: 'Page', default: '', choices: pageChoices(state) },
				{
					type: 'dropdown',
					id: 'mode',
					label: 'Mode',
					default: 'toggle',
					choices: [
						{ id: 'on', label: 'On' },
						{ id: 'off', label: 'Off' },
						{ id: 'toggle', label: 'Toggle' },
					],
				},
			],
			callback: (action: CompanionActionEvent) => {
				const pageID = asText(action.options.pageID)
				const mode = asText(action.options.mode)
				let enabled: boolean
				if (mode === 'toggle') {
					const page = state.pages.get(pageID)
					enabled = page ? !page.linking : true
				} else {
					enabled = mode === 'on'
				}
				send({ type: 'app', action: 'setLinking', pageID, enabled })
			},
		},

		app_set_link: {
			name: 'App — Set Link Group On/Off/Toggle',
			options: [
				{ type: 'dropdown', id: 'pageID', label: 'Page', default: '', choices: pageChoices(state) },
				{
					type: 'dropdown',
					id: 'group',
					label: 'Link Group',
					default: 'whiteBalance',
					choices: [
						{ id: 'whiteBalance', label: 'White Balance' },
						{ id: 'frameRate', label: 'Frame Rate' },
						{ id: 'shutter', label: 'Shutter' },
						{ id: 'record', label: 'Record' },
					],
				},
				{
					type: 'dropdown',
					id: 'mode',
					label: 'Mode',
					default: 'toggle',
					choices: [
						{ id: 'on', label: 'On' },
						{ id: 'off', label: 'Off' },
						{ id: 'toggle', label: 'Toggle' },
					],
				},
			],
			callback: (action: CompanionActionEvent) => {
				const pageID = asText(action.options.pageID)
				const group = asText(action.options.group)
				const mode = asText(action.options.mode)
				let enabled: boolean
				if (mode === 'toggle') {
					const page = state.pages.get(pageID)
					enabled = page ? !page.links.includes(group) : true
				} else {
					enabled = mode === 'on'
				}
				send({ type: 'app', action: 'setLink', pageID, group, enabled })
			},
		},

		playback_command: {
			name: 'Playback — Transport Command',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{
					type: 'dropdown',
					id: 'command',
					label: 'Command',
					default: 'togglePlay',
					choices: [
						{ id: 'togglePlay', label: 'Toggle Play/Pause' },
						{ id: 'play', label: 'Play' },
						{ id: 'pause', label: 'Pause' },
						{ id: 'stop', label: 'Stop' },
						{ id: 'next', label: 'Next Clip' },
						{ id: 'previous', label: 'Previous Clip' },
						{ id: 'fastForward', label: 'Fast Forward' },
						{ id: 'rewind', label: 'Rewind' },
						{ id: 'scanForward', label: 'Scan Forward' },
						{ id: 'scanBackward', label: 'Scan Backward' },
						{ id: 'endScan', label: 'End Scan' },
						{ id: 'skip', label: 'Skip (seconds)' },
						{ id: 'recReview', label: 'Rec Review (Sony)' },
						{ id: 'review', label: 'Into Review' },
						{ id: 'live', label: 'Back to Live' },
					],
				},
				{ type: 'number', id: 'by', label: 'Skip: seconds (+ forward, − back)', default: 5, min: -3600, max: 3600 },
			],
			callback: (action: CompanionActionEvent) => {
				const playbackCmd = action.options.command as PlaybackCommand
				const cmd: { playback: PlaybackCommand; by?: number } =
					playbackCmd === 'skip'
						? { playback: playbackCmd, by: asNumber(action.options.by, 1) }
						: { playback: playbackCmd }
				send({ type: 'command', target: buildTarget(asText(action.options.camera)), command: cmd })
			},
		},

		lock_controls: {
			name: 'App — Lock / Unlock Controls',
			options: [
				{
					type: 'dropdown',
					id: 'mode',
					label: 'Mode',
					default: 'toggle',
					choices: [
						{ id: 'lock', label: 'Lock' },
						{ id: 'unlock', label: 'Unlock' },
						{ id: 'toggle', label: 'Toggle' },
					],
				},
			],
			callback: (action: CompanionActionEvent) => {
				const mode = asText(action.options.mode)
				let enabled: boolean
				if (mode === 'toggle') {
					enabled = !state.locked
				} else {
					enabled = mode === 'lock'
				}
				send({ type: 'app', action: 'setLocked', enabled })
			},
		},

		...driveActions('focus', FOCUS_WAYS, state, send, drives),
		...driveActions('zoom', ZOOM_WAYS, state, send, drives),

		// The Autofocus tile's push: a Blackmagic camera's one-shot, an FX5's Push AF. The app refuses it while the
		// camera's focus is on AF, and on a camera with no push.
		push_autofocus: {
			name: 'Autofocus — Push',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (action: CompanionActionEvent) => {
				send({ type: 'command', target: buildTarget(asText(action.options.camera)), command: { press: 'autofocus' } })
			},
		},

		// Grab Still: a still frame written to the camera's own card (Blackmagic cameras). The app rejects it on a
		// camera with no still capture (`canGrabStill` absent/false).
		grab_still: {
			name: 'Grab Still',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (action: CompanionActionEvent) => {
				send({ type: 'command', target: buildTarget(asText(action.options.camera)), command: { press: 'still' } })
			},
		},

		press_assignable: {
			name: 'Assignable Button — Press',
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'number', id: 'button', label: 'Button (1–10)', default: 1, min: 1, max: 10 },
			],
			callback: (action: CompanionActionEvent) => {
				const button = Math.max(1, Math.min(10, asNumber(action.options.button, 1)))
				send({
					type: 'command',
					target: buildTarget(asText(action.options.camera)),
					command: { press: 'assignable', button },
				})
			},
		},
	}
}
