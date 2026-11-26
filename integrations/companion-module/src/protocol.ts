// Tiles Control API — protocol types (API 1) [control-api.md]

export type ConnectionState =
	'connected' | 'connecting' | 'awaitingApproval' | 'fingerprintChanged' | 'stale' | 'disconnected' | 'failed'

export type RecordValue = 'idle' | 'recording' | 'unknown'

export interface ChoiceField<T = unknown> {
	value: T
	options: T[]
	writable: boolean
	pending?: T
}

export interface LevelField {
	value: number
	min: number
	max: number
	step: number
	writable: boolean
	pending?: number
}

export interface RecordField {
	value: RecordValue
	writable: boolean
	startedAt?: string
	request?: 'start' | 'stop'
	failure?: string
}

export type AnyField = ChoiceField | LevelField | RecordField

export function isChoiceField(f: AnyField): f is ChoiceField {
	return 'options' in f
}

export function isLevelField(f: AnyField): f is LevelField {
	return 'min' in f && 'max' in f
}

export const ALL_FIELD_NAMES = [
	'record',
	'iso',
	'baseISO',
	'shutterMode',
	'shutterAngle',
	'shutterSpeed',
	'wbPreset',
	'kelvin',
	'tint',
	'iris',
	'ndPreset',
	'variableND',
	'frameRate',
	'frameRateVariable',
	'resolution',
	'codec',
	'bitrate',
	'desqueeze',
	'lut',
	'look',
	'falseColor',
	'focusMode',
	'colorBars',
	'imageFlip',
	'clipFlag',
	// Added since 0.1.0: Blackmagic off-speed, dynamic range and monitoring, Sony HDMI info and grid lines
	'offSpeedRate',
	'dynamicRange',
	'zebra',
	'focusAssist',
	'frameGuides',
	'frameGrids',
	'safeArea',
	'cleanFeed',
	'statusText',
	'zebraLevel',
	'frameGuideRatio',
	'hdmiInfo',
	'gridLines',
	// BURANO ND mode, tally, call, gamut; VENICE timecode/duration, Playback's mode and play
	'ndMode',
	'tally',
	'colorGamut',
	'call',
	'timecodeDuration',
	'playbackMode',
	'playing',
	// A VENICE's user frame lines; an FX6's shooting mode, gain in dB and its base, LUT in the recording, proxy, ECS and
	// Autos
	'userFrameA',
	'userFrameB',
	'shootingMode',
	'gain',
	'baseSensitivity',
	'recordedLUT',
	'proxy',
	'ecs',
	'irisAuto',
	'ndAuto',
	'isoAuto',
	// An FX5's SteadyShot and Imager Mode; a Sony's autofocus settings
	'steadyShot',
	'imagerMode',
	'subjectRecognition',
	'focusArea',
	'afTransitionSpeed',
	'afSubjectShift',
	'afAssist',
] as const

export type FieldName = (typeof ALL_FIELD_NAMES)[number]

export interface PlaybackState {
	clip?: string
	clipNumber?: number
	clipCount?: number
	position?: number
	duration?: number
	commands: string[]
}

export interface Camera {
	id: string
	label: string
	model: string
	color: string
	demo: boolean
	connection: ConnectionState
	latencyMs: number
	battery: number
	mediaMinutes: number
	fields: Partial<Record<FieldName, AnyField>>
	playback?: PlaybackState | null
	locked?: boolean
	/** True when the camera supports `{"press":"still"}` while connected. Absent = no still capture. */
	canGrabStill?: boolean
	/** Result of the last Grab Still. `saved: true` = on card; `false` = not saved, `message` says why. */
	lastStill?: { saved: boolean; message?: string } | null
}

export interface HaLowNode {
	name: string
	signalDBm: number
	state: string
}

export interface RadioStatus {
	bars: number
	haLow?: HaLowNode[]
}

export interface Page {
	id: string
	name: string
	cameras: string[] // camera IDs
	linking: boolean
	links: string[]
	current: boolean
}

// ---- Client → Server messages ----

export interface AuthMessage {
	type: 'auth'
	token: string
	id?: string
}

export interface SubscribeMessage {
	type: 'subscribe'
	id?: string
}

// Spec: cameraID is the canonical target; camera label still accepted for one-off curl use
export type Target =
	| { cameraID: string }
	| { camera: string } // label, resolved at command time
	| { pageID: string }
	| { currentPage: true }
	| { all: true }

export type PlaybackCommand =
	| 'togglePlay'
	| 'play'
	| 'pause'
	| 'stop'
	| 'next'
	| 'previous'
	| 'fastForward'
	| 'rewind'
	| 'scanForward'
	| 'scanBackward'
	| 'endScan'
	| 'skip'
	| 'recReview'
	| 'review'
	| 'live'

export type DriveMotor = 'focus' | 'zoom'

export type Command =
	| { set: FieldName; value: unknown }
	| { step: FieldName; by: number }
	| { toggle: FieldName }
	| { cycle: FieldName }
	| { playback: PlaybackCommand; by?: number }
	| { drive: DriveMotor; speed: number; seconds?: number }
	| { press: 'assignable'; button: number }
	| { press: 'autofocus' }
	| { press: 'still' }

export interface CommandMessage {
	type: 'command'
	id?: string
	token?: string
	target: Target
	link?: 'app' | false
	command: Command
}

export type AppAction =
	| { action: 'showPage'; pageID: string }
	| { action: 'setLinking'; pageID: string; enabled: boolean }
	| { action: 'setLink'; pageID: string; group: string; enabled: boolean }
	| { action: 'setLocked'; enabled: boolean }

export type AppMessage = { type: 'app'; id?: string } & AppAction

export interface PingMessage {
	type: 'ping'
	id?: string
}

export type ClientMessage = AuthMessage | SubscribeMessage | CommandMessage | AppMessage | PingMessage

// ---- Server → Client messages ----

export interface HelloMessage {
	type: 'hello'
	id?: string
	api: number
	app: string
	appVersion: string
	cameras: Camera[]
	pages: Page[]
	radio?: RadioStatus
	locked?: boolean
}

export interface SnapshotMessage {
	type: 'snapshot'
	cameras: Camera[]
	pages: Page[]
	radio?: RadioStatus
	locked?: boolean
}

export interface LockMessage {
	type: 'lock'
	locked: boolean
}

export interface ChangesMessage {
	type: 'changes'
	camera: string
	cameraID: string
	update: Partial<Camera> & { fields?: Partial<Record<FieldName, Partial<AnyField>>>; playback?: PlaybackState | null }
	removed?: FieldName[]
}

export interface PagesMessage {
	type: 'pages'
	pages: Page[]
}

export interface RadioMessage {
	type: 'radio'
	radio: RadioStatus
}

export interface CamerasMessage {
	type: 'cameras'
	cameras: Camera[] // full list — clients replace theirs
}

export type ResultStatus = 'confirmed' | 'failed' | 'timeout' | 'rejected' | 'superseded' | 'accepted'

export interface ResultEntry {
	camera: string
	status: ResultStatus
	field?: FieldName
	value?: unknown
	error?: string
}

export interface ResultMessage {
	type: 'result'
	id?: string
	results: ResultEntry[]
}

export interface ErrorMessage {
	type: 'error'
	id?: string
	code: 'auth' | 'badRequest' | 'unknownTarget' | 'unknownField'
	message: string
}

export type ServerMessage =
	| HelloMessage
	| SnapshotMessage
	| ChangesMessage
	| PagesMessage
	| RadioMessage
	| CamerasMessage
	| ResultMessage
	| ErrorMessage
	| LockMessage
	| { type: 'pong'; id?: string }
