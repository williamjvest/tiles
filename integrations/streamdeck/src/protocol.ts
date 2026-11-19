// Tiles Control API — protocol types [control-api.md]

// ─── Camera / Page ────────────────────────────────────────────────────────────

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
  value: 'idle' | 'recording' | 'unknown'
  writable: boolean
  startedAt?: string
  request?: 'start' | 'stop'
  failure?: string
}

export type AnyField = ChoiceField | LevelField | RecordField

export interface PlaybackStatus {
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
  connection: 'connected' | 'connecting' | 'awaitingApproval' | 'fingerprintChanged' | 'stale' | 'disconnected' | 'failed'
  latencyMs: number
  battery: number
  mediaMinutes: number
  fields: Record<string, AnyField>
  playback?: PlaybackStatus
  locked?: boolean
}

export interface Page {
  id: string
  name: string
  cameras: string[]
  linking: boolean
  links: string[]
  current: boolean
}

export interface RadioStatus {
  bars: number
  haLow?: Array<{ name: string; signalDBm: number; state: string }>
}

// ─── Client → Server ─────────────────────────────────────────────────────────

export type Target =
  | { cameraID: string }
  | { camera: string }
  | { pageID: string }
  | { currentPage: true }
  | { all: true }

export type Command =
  | { set: string; value: unknown }
  | { step: string; by: number }
  | { toggle: string }
  | { cycle: string }
  | { drive: 'focus' | 'zoom'; speed: number; seconds?: number }
  | { press: 'assignable'; button: number }
  | { press: 'autofocus' }

export type PlaybackCommand =
  | { playback: 'togglePlay' | 'play' | 'pause' | 'stop' | 'next' | 'previous' | 'fastForward' | 'rewind' | 'scanForward' | 'scanBackward' | 'endScan' | 'recReview' | 'review' | 'live' }
  | { playback: 'skip'; by: number }

export type ClientMessage =
  | { type: 'auth'; token: string; id?: string }
  | { type: 'subscribe'; id?: string }
  | { type: 'ping'; id?: string }
  | { type: 'command'; id?: string; token?: string; target: Target; link?: 'app' | false; command: Command | PlaybackCommand }
  | { type: 'app'; id?: string; action: 'showPage'; pageID: string }
  | { type: 'app'; id?: string; action: 'setLinking'; pageID: string; enabled: boolean }
  | { type: 'app'; id?: string; action: 'setLink'; pageID: string; group: string; enabled: boolean }
  | { type: 'app'; id?: string; action: 'setLocked'; enabled: boolean }

// ─── Server → Client ─────────────────────────────────────────────────────────

export interface ResultEntry {
  camera: string
  status: 'confirmed' | 'failed' | 'timeout' | 'rejected' | 'superseded' | 'accepted'
  field?: string
  value?: unknown
  error?: string
}

export type ServerMessage =
  | { type: 'hello'; id?: string; api: number; app: string; appVersion: string; cameras: Camera[]; pages: Page[]; radio?: RadioStatus; locked?: boolean }
  | { type: 'snapshot'; cameras: Camera[]; pages: Page[]; radio?: RadioStatus; locked?: boolean }
  | { type: 'changes'; camera: string; cameraID: string; update: { connection?: Camera['connection']; latencyMs?: number; fields?: Record<string, Partial<AnyField>>; playback?: PlaybackStatus | null }; removed?: string[] }
  | { type: 'pages'; pages: Page[] }
  | { type: 'cameras'; cameras: Camera[] }
  | { type: 'radio'; radio: RadioStatus }
  | { type: 'lock'; locked: boolean }
  | { type: 'result'; id?: string; results: ResultEntry[] }
  | { type: 'pong'; id?: string }
  | { type: 'error'; id?: string; code: 'auth' | 'badRequest' | 'unknownTarget' | 'unknownField'; message: string }
