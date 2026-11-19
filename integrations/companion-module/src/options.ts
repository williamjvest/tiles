/** An action's or feedback's option as text: strings as they are, numbers and booleans spelled out, anything else empty. */
export function asText(value: unknown): string {
	if (typeof value === 'string') return value
	if (typeof value === 'number' || typeof value === 'boolean') return String(value)
	return ''
}

/** An option as a number, or `fallback` when it isn't one. */
export function asNumber(value: unknown, fallback: number): number {
	const n = typeof value === 'number' ? value : typeof value === 'string' && value.trim() !== '' ? Number(value) : NaN
	return Number.isFinite(n) ? n : fallback
}
