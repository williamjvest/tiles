import type { Camera, Page, RadioStatus, AnyField, FieldName, PlaybackState } from './protocol.js'

export interface TwccState {
	// Keyed by camera ID (UUID)
	cameras: Map<string, Camera>
	// Keyed by page ID (UUID)
	pages: Map<string, Page>
	radio?: RadioStatus
	currentPageId?: string
	locked: boolean
}

export function createState(): TwccState {
	return { cameras: new Map(), pages: new Map(), locked: false }
}

export function applySnapshot(
	state: TwccState,
	cameras: Camera[],
	pages: Page[],
	radio?: RadioStatus,
	locked?: boolean,
): void {
	state.cameras.clear()
	for (const cam of cameras) {
		state.cameras.set(cam.id, cam)
	}
	state.pages.clear()
	state.currentPageId = undefined
	for (const page of pages) {
		state.pages.set(page.id, page)
		if (page.current) state.currentPageId = page.id
	}
	if (radio !== undefined) state.radio = radio
	if (locked !== undefined) state.locked = locked
}

export function applyChanges(
	state: TwccState,
	cameraID: string,
	update: Partial<Camera> & { fields?: Partial<Record<FieldName, Partial<AnyField>>>; playback?: PlaybackState | null },
	removed?: FieldName[],
): void {
	const cam = state.cameras.get(cameraID)
	if (!cam) return

	if (update.connection !== undefined) cam.connection = update.connection
	if (update.label !== undefined) cam.label = update.label
	if (update.latencyMs !== undefined) cam.latencyMs = update.latencyMs
	if (update.battery !== undefined) cam.battery = update.battery
	if (update.mediaMinutes !== undefined) cam.mediaMinutes = update.mediaMinutes

	// playback: whole object replacement per spec (or null when it goes away)
	if ('playback' in update) cam.playback = update.playback
	if ('canGrabStill' in update) cam.canGrabStill = update.canGrabStill
	if ('lastStill' in update) cam.lastStill = update.lastStill

	if (update.fields) {
		for (const [fname, patch] of Object.entries(update.fields)) {
			const name = fname as FieldName
			const existing = cam.fields[name]
			if (existing) {
				Object.assign(existing, patch)
				const patchRec = patch as unknown as Record<string, unknown>
				if (patchRec.pending === null) {
					const existingRec = existing as unknown as Record<string, unknown>
					delete existingRec.pending
				}
			} else {
				cam.fields[name] = patch
			}
		}
	}

	if (removed) {
		for (const fname of removed) {
			delete cam.fields[fname]
		}
	}
}

/**
 * The link to the app is down: nothing it said is known now. REC especially, which would otherwise keep a key red
 * after the take ended (the Stream Deck plugin's connection.ts does the same).
 */
export function markAllUnknown(state: TwccState): void {
	for (const cam of state.cameras.values()) {
		cam.connection = 'disconnected'
		const rec = cam.fields.record
		if (rec) rec.value = 'unknown'
		cam.playback = null
	}
}

export function applyPagesUpdate(state: TwccState, pages: Page[]): void {
	// Full list replacement per spec
	state.pages.clear()
	state.currentPageId = undefined
	for (const page of pages) {
		state.pages.set(page.id, page)
		if (page.current) state.currentPageId = page.id
	}
}

// Full list replacement per spec
export function applyCamerasUpdate(state: TwccState, cameras: Camera[]): void {
	state.cameras.clear()
	for (const cam of cameras) {
		state.cameras.set(cam.id, cam)
	}
}
