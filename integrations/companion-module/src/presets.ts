import { combineRgb } from '@companion-module/base'
import type {
	CompanionPresetDefinitions,
	CompanionSimplePresetDefinition,
	CompanionPresetSection,
} from '@companion-module/base'
import type { TwccState } from './state.js'
import type { TwccTypes } from './types.js'

/** The held focus and zoom presets: each motor's two ways. */
const DRIVE_PRESETS = [
	{ motor: 'focus', direction: 'near', text: 'FOCUS\nNEAR', bgcolor: combineRgb(30, 60, 30) },
	{ motor: 'focus', direction: 'far', text: 'FOCUS\nFAR', bgcolor: combineRgb(30, 60, 30) },
	{ motor: 'zoom', direction: 'wide', text: 'ZOOM\nWIDE', bgcolor: combineRgb(30, 30, 80) },
	{ motor: 'zoom', direction: 'tele', text: 'ZOOM\nTELE', bgcolor: combineRgb(30, 30, 80) },
] as const

export function buildPresets(state: TwccState): {
	structure: CompanionPresetSection<TwccTypes>[]
	presets: CompanionPresetDefinitions<TwccTypes>
} {
	const presets: CompanionPresetDefinitions<TwccTypes> = {}
	const sections: CompanionPresetSection<TwccTypes>[] = []

	for (const [camId, cam] of state.cameras) {
		const lbl = cam.label // display / variable prefix
		const presetIds: string[] = []

		function addPreset(id: string, def: CompanionSimplePresetDefinition<TwccTypes>): void {
			presets[id] = def
			presetIds.push(id)
		}

		// REC toggle — red tally (connected + confirmed), gray when unknown, orange pending
		addPreset(`cam_${camId}_rec`, {
			type: 'simple',
			name: `REC Toggle — ${lbl}`,
			style: {
				text: `REC\n$(twcc:${lbl}_rec_state)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(0, 0, 0),
			},
			feedbacks: [
				{
					feedbackId: 'recording',
					options: { camera: camId },
					style: { bgcolor: combineRgb(255, 0, 0), color: combineRgb(255, 255, 255) },
				},
				{ feedbackId: 'rec_unknown', options: { camera: camId }, style: { bgcolor: combineRgb(100, 100, 100) } },
				{
					feedbackId: 'rec_pending',
					options: { camera: camId },
					style: { bgcolor: combineRgb(255, 128, 0), color: combineRgb(0, 0, 0) },
				},
			],
			steps: [{ down: [{ actionId: 'rec_toggle', options: { camera: camId } }], up: [] }],
		})

		addPreset(`cam_${camId}_rec_time`, {
			type: 'simple',
			name: `REC Time`,
			style: {
				text: `$(twcc:${lbl}_rec_time)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(0, 0, 0),
			},
			feedbacks: [{ feedbackId: 'recording', options: { camera: camId }, style: { bgcolor: combineRgb(180, 0, 0) } }],
			steps: [{ down: [], up: [] }],
		})

		addPreset(`cam_${camId}_iso_down`, {
			type: 'simple',
			name: `ISO −`,
			style: {
				text: `ISO−\n$(twcc:${lbl}_iso)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(30, 30, 80),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: 'iso', by: -1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_iso_up`, {
			type: 'simple',
			name: `ISO +`,
			style: {
				text: `ISO+\n$(twcc:${lbl}_iso)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(30, 30, 80),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: 'iso', by: 1 } }], up: [] }],
		})

		// Shutter presets respect the camera's shutter mode (angle or speed).
		// shutterMode field: 'angle' uses shutterAngle, 'speed' uses shutterSpeed.
		const shutterMode = cam.fields.shutterMode
		const shutterField =
			shutterMode && 'value' in shutterMode && shutterMode.value === 'speed' ? 'shutterSpeed' : 'shutterAngle'
		const shutterVar = shutterField === 'shutterSpeed' ? `${lbl}_shutterSpeed` : `${lbl}_shutterAngle`

		addPreset(`cam_${camId}_shutter_down`, {
			type: 'simple',
			name: `Shutter −`,
			style: {
				text: `SHTR−\n$(twcc:${shutterVar})`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(40, 60, 40),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: shutterField, by: -1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_shutter_up`, {
			type: 'simple',
			name: `Shutter +`,
			style: {
				text: `SHTR+\n$(twcc:${shutterVar})`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(40, 60, 40),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: shutterField, by: 1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_wb_cycle`, {
			type: 'simple',
			name: `WB Cycle`,
			style: {
				text: `WB\n$(twcc:${lbl}_wbPreset)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(60, 40, 80),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_cycle', options: { camera: camId, field: 'wbPreset' } }], up: [] }],
		})

		addPreset(`cam_${camId}_kelvin_down`, {
			type: 'simple',
			name: `Kelvin −`,
			style: {
				text: `K−\n$(twcc:${lbl}_kelvin)`,
				size: '14',
				color: combineRgb(255, 200, 100),
				bgcolor: combineRgb(60, 40, 20),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: 'kelvin', by: -1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_kelvin_up`, {
			type: 'simple',
			name: `Kelvin +`,
			style: {
				text: `K+\n$(twcc:${lbl}_kelvin)`,
				size: '14',
				color: combineRgb(255, 200, 100),
				bgcolor: combineRgb(60, 40, 20),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: 'kelvin', by: 1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_iris_down`, {
			type: 'simple',
			name: `Iris −`,
			style: {
				text: `IRIS−\n$(twcc:${lbl}_iris)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(50, 50, 20),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: 'iris', by: -1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_iris_up`, {
			type: 'simple',
			name: `Iris +`,
			style: {
				text: `IRIS+\n$(twcc:${lbl}_iris)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(50, 50, 20),
			},
			feedbacks: [],
			steps: [{ down: [{ actionId: 'field_step', options: { camera: camId, field: 'iris', by: 1 } }], up: [] }],
		})

		addPreset(`cam_${camId}_lut_toggle`, {
			type: 'simple',
			name: `LUT On/Off`,
			style: {
				text: `LUT\n$(twcc:${lbl}_look)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(20, 60, 60),
			},
			feedbacks: [
				{
					feedbackId: 'field_equals',
					options: { camera: camId, field: 'look', value: 'true' },
					style: { bgcolor: combineRgb(0, 120, 120) },
				},
			],
			steps: [{ down: [{ actionId: 'field_toggle_bool', options: { camera: camId, field: 'look' } }], up: [] }],
		})

		addPreset(`cam_${camId}_false_colour`, {
			type: 'simple',
			name: `False Colour`,
			style: {
				text: `FC\n$(twcc:${lbl}_falseColor)`,
				size: '14',
				color: combineRgb(255, 255, 255),
				bgcolor: combineRgb(60, 20, 60),
			},
			feedbacks: [
				{
					feedbackId: 'field_equals',
					options: { camera: camId, field: 'falseColor', value: 'true' },
					style: { bgcolor: combineRgb(120, 0, 120) },
				},
			],
			steps: [{ down: [{ actionId: 'field_toggle_bool', options: { camera: camId, field: 'falseColor' } }], up: [] }],
		})

		// Focus and zoom, held: the drive on the button's down action, the stop on its up action
		for (const { motor, direction, text, bgcolor } of DRIVE_PRESETS) {
			addPreset(`cam_${camId}_${motor}_${direction}`, {
				type: 'simple',
				name: `${motor === 'focus' ? 'Focus' : 'Zoom'} — ${direction[0].toUpperCase()}${direction.slice(1)}`,
				style: { text, size: '14', color: combineRgb(255, 255, 255), bgcolor },
				feedbacks: [],
				steps: [
					{
						down: [{ actionId: `${motor}_drive`, options: { camera: camId, direction, speed: 3 } }],
						up: [{ actionId: `${motor}_stop`, options: { camera: camId } }],
					},
				],
			})
		}

		// Push autofocus, as the Autofocus tile's
		addPreset(`cam_${camId}_autofocus`, {
			type: 'simple',
			name: 'Autofocus — Push',
			style: { text: 'PUSH\nAF', size: '14', color: combineRgb(255, 255, 255), bgcolor: combineRgb(20, 50, 60) },
			feedbacks: [],
			steps: [{ down: [{ actionId: 'push_autofocus', options: { camera: camId } }], up: [] }],
		})

		// Grab Still, as the Grab Still tile: lights briefly green when the last still was saved
		addPreset(`cam_${camId}_grab_still`, {
			type: 'simple',
			name: 'Grab Still',
			style: { text: 'GRAB\nSTILL', size: '14', color: combineRgb(255, 255, 255), bgcolor: combineRgb(20, 40, 60) },
			feedbacks: [
				{
					feedbackId: 'grab_still_saved',
					options: { camera: camId },
					style: { bgcolor: combineRgb(0, 160, 80), color: combineRgb(255, 255, 255) },
				},
			],
			steps: [{ down: [{ actionId: 'grab_still', options: { camera: camId } }], up: [] }],
		})

		// Assignable buttons 1–10
		for (let btn = 1; btn <= 10; btn++) {
			addPreset(`cam_${camId}_asgn_${btn}`, {
				type: 'simple',
				name: `Assignable ${btn}`,
				style: { text: `ASGN\n${btn}`, size: '14', color: combineRgb(255, 255, 255), bgcolor: combineRgb(60, 40, 20) },
				feedbacks: [],
				steps: [{ down: [{ actionId: 'press_assignable', options: { camera: camId, button: btn } }], up: [] }],
			})
		}

		// Transport row: previous, rewind, play/pause, fast forward, next, stop, Live/Review
		addPreset(`cam_${camId}_pb_prev`, {
			type: 'simple',
			name: `Playback — Previous`,
			style: { text: '|◀', size: '18', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [],
			steps: [
				{ down: [{ actionId: 'playback_command', options: { camera: camId, command: 'previous', by: 0 } }], up: [] },
			],
		})

		addPreset(`cam_${camId}_pb_rew`, {
			type: 'simple',
			name: `Playback — Rewind`,
			style: { text: '◀◀', size: '18', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [],
			steps: [
				{ down: [{ actionId: 'playback_command', options: { camera: camId, command: 'rewind', by: 0 } }], up: [] },
			],
		})

		addPreset(`cam_${camId}_pb_play`, {
			type: 'simple',
			name: `Playback — Play/Pause`,
			style: { text: '▶ / ‖', size: '14', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [
				{
					feedbackId: 'playing',
					options: { camera: camId },
					style: { bgcolor: combineRgb(0, 160, 60), color: combineRgb(255, 255, 255) },
				},
			],
			steps: [
				{ down: [{ actionId: 'playback_command', options: { camera: camId, command: 'togglePlay', by: 0 } }], up: [] },
			],
		})

		addPreset(`cam_${camId}_pb_ff`, {
			type: 'simple',
			name: `Playback — Fast Forward`,
			style: { text: '▶▶', size: '18', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [],
			steps: [
				{ down: [{ actionId: 'playback_command', options: { camera: camId, command: 'fastForward', by: 0 } }], up: [] },
			],
		})

		addPreset(`cam_${camId}_pb_next`, {
			type: 'simple',
			name: `Playback — Next`,
			style: { text: '▶|', size: '18', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [],
			steps: [{ down: [{ actionId: 'playback_command', options: { camera: camId, command: 'next', by: 0 } }], up: [] }],
		})

		addPreset(`cam_${camId}_pb_stop`, {
			type: 'simple',
			name: `Playback — Stop`,
			style: { text: '■', size: '18', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [],
			steps: [{ down: [{ actionId: 'playback_command', options: { camera: camId, command: 'stop', by: 0 } }], up: [] }],
		})

		addPreset(`cam_${camId}_pb_live_review`, {
			type: 'simple',
			name: `Playback — Live / Review`,
			style: { text: 'LIVE /\nREVIEW', size: '14', color: combineRgb(255, 255, 255), bgcolor: combineRgb(30, 30, 60) },
			feedbacks: [
				{
					feedbackId: 'in_review',
					options: { camera: camId },
					style: { bgcolor: combineRgb(80, 0, 160), color: combineRgb(255, 255, 255) },
				},
			],
			// playbackMode's two options, live and review: a cycle flips it either way (the server won't toggle a string).
			steps: [{ down: [{ actionId: 'field_cycle', options: { camera: camId, field: 'playbackMode' } }], up: [] }],
		})

		sections.push({
			id: `section_cam_${camId}`,
			name: `Camera ${lbl} · ${cam.model}`,
			definitions: [{ id: `grp_cam_${camId}`, type: 'simple', name: `Camera ${lbl} Controls`, presets: presetIds }],
		})
	}

	// Global lock button
	presets['global_lock'] = {
		type: 'simple',
		name: 'Lock Controls',
		style: { text: '🔒 LOCK', size: '14', color: combineRgb(255, 255, 255), bgcolor: combineRgb(60, 60, 0) },
		feedbacks: [
			{
				feedbackId: 'controls_locked',
				options: {},
				style: { bgcolor: combineRgb(200, 150, 0), color: combineRgb(0, 0, 0) },
			},
		],
		steps: [{ down: [{ actionId: 'lock_controls', options: { mode: 'toggle' } }], up: [] }],
	}

	const globalSection: CompanionPresetSection = {
		id: 'section_global',
		name: 'Global',
		definitions: [{ id: 'grp_global', type: 'simple', name: 'Global Controls', presets: ['global_lock'] }],
	}
	sections.push(globalSection)

	return { structure: sections, presets }
}
