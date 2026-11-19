import { combineRgb } from '@companion-module/base'
import type { CompanionFeedbackDefinitions, CompanionFeedbackBooleanEvent } from '@companion-module/base'
import type { TwccState } from './state.js'
import { CURRENT_PAGE_ID, cameraChoices } from './actions.js'
import { asText, asNumber } from './options.js'

// Sentinel camera ID meaning "whichever cameras are on the current page"
export function buildFeedbacks(state: TwccState): CompanionFeedbackDefinitions {
	function currentPageCameras(): string[] {
		const page = state.currentPageId ? state.pages.get(state.currentPageId) : undefined
		return page?.cameras ?? []
	}

	function forCamera(cameraID: string, check: (id: string) => boolean, all = false): boolean {
		if (cameraID === CURRENT_PAGE_ID) {
			const ids = currentPageCameras()
			return ids.length > 0 && (all ? ids.every(check) : ids.some(check))
		}
		return check(cameraID)
	}

	return {
		recording: {
			type: 'boolean',
			name: 'Camera — Recording (camera-confirmed, connected only)',
			description: 'Red when the camera is connected and confirms recording = recording.',
			defaultStyle: { bgcolor: combineRgb(255, 0, 0), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					if (!cam || cam.connection !== 'connected') return false
					const rec = cam.fields.record
					return rec?.value === 'recording'
				})
			},
		},

		rec_unknown: {
			type: 'boolean',
			name: 'Camera — REC Unknown (offline or transitioning)',
			description: 'Active when the camera is not connected and REC state is unknown.',
			defaultStyle: { bgcolor: combineRgb(100, 100, 100), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					if (!cam) return false
					const rec = cam.fields.record
					return rec?.value === 'unknown'
				})
			},
		},

		rec_pending: {
			type: 'boolean',
			name: 'Camera — REC Request Pending',
			description: 'Active while a REC start or stop command is in flight.',
			defaultStyle: { bgcolor: combineRgb(255, 128, 0), color: combineRgb(0, 0, 0) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					const rec = cam?.fields.record
					return !!(rec && 'request' in rec && rec.request)
				})
			},
		},

		camera_connected: {
			type: 'boolean',
			name: 'Camera — Connected',
			description: 'Active when connection = connected.',
			defaultStyle: { bgcolor: combineRgb(0, 180, 0), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				return forCamera(
					asText(feedback.options.camera),
					(id) => state.cameras.get(id)?.connection === 'connected',
					true,
				)
			},
		},

		camera_not_connected: {
			type: 'boolean',
			name: 'Camera — Not Connected',
			description: 'Active when connection ≠ connected.',
			defaultStyle: { bgcolor: combineRgb(80, 80, 80), color: combineRgb(200, 200, 200) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				const cameraID = asText(feedback.options.camera)
				if (cameraID === CURRENT_PAGE_ID) {
					const ids = currentPageCameras()
					if (!ids.length) return true
					return ids.some((id) => state.cameras.get(id)?.connection !== 'connected')
				}
				const cam = state.cameras.get(cameraID)
				return !cam || cam.connection !== 'connected'
			},
		},

		field_equals: {
			type: 'boolean',
			name: 'Field — Equals Value',
			description: 'Active when the camera-confirmed field value matches.',
			defaultStyle: { bgcolor: combineRgb(0, 100, 200), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'textinput', id: 'field', label: 'Field Name', default: 'iso' },
				{ type: 'textinput', id: 'value', label: 'Expected Value', default: '' },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				const fieldName = asText(feedback.options.field)
				const expectedStr = asText(feedback.options.value)
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					if (!cam) return false
					const field = cam.fields[fieldName as keyof typeof cam.fields]
					if (!field) return false
					return String((field as { value: unknown }).value) === expectedStr
				})
			},
		},

		field_writable: {
			type: 'boolean',
			name: 'Field — Writable',
			description: 'Active when the field exists and is writable.',
			defaultStyle: { bgcolor: combineRgb(0, 60, 120), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
				{ type: 'textinput', id: 'field', label: 'Field Name', default: 'iso' },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				const fieldName = asText(feedback.options.field)
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					if (!cam) return false
					const field = cam.fields[fieldName as keyof typeof cam.fields]
					return !!(field && (field as { writable?: boolean }).writable)
				})
			},
		},

		radio_bars_below: {
			type: 'boolean',
			name: 'Radio — Link Bars Below Threshold',
			description: 'Active when the HaLow radio bars value is below the threshold.',
			defaultStyle: { bgcolor: combineRgb(200, 100, 0), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'number', id: 'threshold', label: 'Threshold (0.0–1.0)', default: 0.3, min: 0, max: 1, step: 0.05 },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				if (!state.radio) return false
				return state.radio.bars < asNumber(feedback.options.threshold, 0)
			},
		},

		playing: {
			type: 'boolean',
			name: 'Playback — Playing',
			description: "Active when the camera's playing field is true.",
			defaultStyle: { bgcolor: combineRgb(0, 180, 60), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					if (!cam) return false
					const field = cam.fields.playing
					return field?.value === true
				})
			},
		},

		in_review: {
			type: 'boolean',
			name: 'Playback — In Review',
			description: 'Active when the camera\'s playbackMode field is "review".',
			defaultStyle: { bgcolor: combineRgb(80, 0, 160), color: combineRgb(255, 255, 255) },
			options: [
				{ type: 'dropdown', id: 'camera', label: 'Camera', default: CURRENT_PAGE_ID, choices: cameraChoices(state) },
			],
			callback: (feedback: CompanionFeedbackBooleanEvent): boolean => {
				return forCamera(asText(feedback.options.camera), (id) => {
					const cam = state.cameras.get(id)
					if (!cam) return false
					const field = cam.fields.playbackMode
					return field?.value === 'review'
				})
			},
		},

		controls_locked: {
			type: 'boolean',
			name: 'App — Controls Locked',
			description: "Active when the app's controls are locked.",
			defaultStyle: { bgcolor: combineRgb(200, 150, 0), color: combineRgb(0, 0, 0) },
			options: [],
			callback: (_feedback: CompanionFeedbackBooleanEvent): boolean => {
				return state.locked
			},
		},
	}
}
