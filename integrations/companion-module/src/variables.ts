import type { CompanionVariableDefinitions, CompanionVariableValues } from '@companion-module/base'
import type { TwccState } from './state.js'
import { ALL_FIELD_NAMES } from './protocol.js'
import { BOOL_FIELDS } from './actions.js'
import { asText } from './options.js'

// Variables use camera label for readability: $(twcc:C_iso)
// On a rename, the variable id updates at the next snapshot/cameras message — buttons
// referencing the old label name will go blank until Companion's variable subscriptions refresh.
export function buildVariableDefinitions(state: TwccState): CompanionVariableDefinitions {
	const defs: CompanionVariableDefinitions = {}

	for (const [, cam] of state.cameras) {
		const p = cam.label
		for (const field of ALL_FIELD_NAMES) {
			defs[`${p}_${field}`] = { name: `Camera ${p} — ${field}` }
		}
		defs[`${p}_rec_state`] = { name: `Camera ${p} — REC state` }
		defs[`${p}_rec_time`] = { name: `Camera ${p} — REC time (HH:MM:SS)` }
		defs[`${p}_battery`] = { name: `Camera ${p} — Battery %` }
		defs[`${p}_media_minutes`] = { name: `Camera ${p} — Media minutes remaining` }
		defs[`${p}_latency`] = { name: `Camera ${p} — Latency ms` }
		defs[`${p}_model`] = { name: `Camera ${p} — Model` }
		defs[`${p}_connection`] = { name: `Camera ${p} — Connection state` }
		defs[`${p}_id`] = { name: `Camera ${p} — ID (UUID)` }
		// Playback
		defs[`${p}_pb_clip`] = { name: `Camera ${p} — Playback clip name` }
		defs[`${p}_pb_clip_number`] = { name: `Camera ${p} — Playback clip number` }
		defs[`${p}_pb_clip_count`] = { name: `Camera ${p} — Playback clip count` }
		defs[`${p}_pb_position`] = { name: `Camera ${p} — Playback position (m:ss)` }
		defs[`${p}_pb_duration`] = { name: `Camera ${p} — Playback duration (m:ss)` }
		defs[`${p}_pb_mode`] = { name: `Camera ${p} — Playback mode (live/review)` }
	}

	defs['current_page'] = { name: 'Current Page Name' }
	defs['radio_bars'] = { name: 'Radio Link Bars (0.0–1.0)' }
	defs['halow_signal_dbm'] = { name: 'HaLow Signal dBm (first node)' }
	defs['locked'] = { name: 'App Controls Locked (true/false)' }

	return defs
}

export function formatRecTime(startedAt: string | undefined): string {
	if (!startedAt) return '00:00:00'
	const elapsed = Math.max(0, Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000))
	const h = Math.floor(elapsed / 3600)
	const m = Math.floor((elapsed % 3600) / 60)
	const s = elapsed % 60
	return [h, m, s].map((v) => String(v).padStart(2, '0')).join(':')
}

export function formatPlaybackTime(seconds: number | undefined): string {
	if (seconds === undefined || seconds === null) return ''
	const total = Math.max(0, Math.floor(seconds))
	const m = Math.floor(total / 60)
	const s = total % 60
	return `${m}:${String(s).padStart(2, '0')}`
}

export function buildVariableValues(state: TwccState): CompanionVariableValues {
	const vals: CompanionVariableValues = {}

	for (const [, cam] of state.cameras) {
		const p = cam.label
		for (const field of ALL_FIELD_NAMES) {
			const f = cam.fields[field]
			if (!f) {
				vals[`${p}_${field}`] = ''
				continue
			}
			const raw = (f as { value: unknown }).value
			// Boolean fields show ON / OFF in key labels and preset text
			if ((BOOL_FIELDS as readonly string[]).includes(field) && typeof raw === 'boolean') {
				vals[`${p}_${field}`] = raw ? 'ON' : 'OFF'
			} else {
				vals[`${p}_${field}`] = String(raw)
			}
		}
		const recField = cam.fields.record
		const recValue = recField ? String(recField.value) : 'unknown'
		const startedAt = recField && 'startedAt' in recField ? recField.startedAt : undefined
		vals[`${p}_rec_state`] = recValue
		vals[`${p}_rec_time`] = recValue === 'recording' ? formatRecTime(startedAt) : '00:00:00'
		vals[`${p}_battery`] = String(cam.battery)
		vals[`${p}_media_minutes`] = String(cam.mediaMinutes)
		vals[`${p}_latency`] = String(cam.latencyMs)
		vals[`${p}_model`] = cam.model
		vals[`${p}_connection`] = cam.connection
		vals[`${p}_id`] = cam.id
		// Playback
		const pb = cam.playback ?? null
		vals[`${p}_pb_clip`] = pb?.clip ?? ''
		vals[`${p}_pb_clip_number`] = pb?.clipNumber !== undefined ? String(pb.clipNumber) : ''
		vals[`${p}_pb_clip_count`] = pb?.clipCount !== undefined ? String(pb.clipCount) : ''
		vals[`${p}_pb_position`] = formatPlaybackTime(pb?.position)
		vals[`${p}_pb_duration`] = formatPlaybackTime(pb?.duration)
		vals[`${p}_pb_mode`] = asText(cam.fields.playbackMode?.value)
	}

	const currentPage = state.currentPageId ? state.pages.get(state.currentPageId) : undefined
	vals['current_page'] = currentPage?.name ?? ''
	vals['radio_bars'] = state.radio ? String(state.radio.bars) : ''
	vals['halow_signal_dbm'] =
		state.radio?.haLow && state.radio.haLow.length > 0 ? String(state.radio.haLow[0].signalDBm) : ''
	vals['locked'] = String(state.locked)

	return vals
}
