// Stream Deck plugin — field label coverage tests
// Verifies:
//  1. No user-visible field label in FIELD_LABELS equals its raw camelCase id.
//  2. The inspector's field <option> values and FIELD_LABELS cover the same field ids.

import { readFileSync } from 'fs'
import { join } from 'path'

// ── Helpers ───────────────────────────────────────────────────────────────────

const PLUGIN_SRC = join(__dirname, '../src/plugin.ts')
const INSPECTOR_HTML = join(__dirname, '../com.toldwell.twcc.sdPlugin/ui/inspector.html')

/** Parse FIELD_LABELS from plugin.ts source without importing the module. */
function parsedFieldLabels(): Map<string, string> {
  const src = readFileSync(PLUGIN_SRC, 'utf8')
  const blockMatch = src.match(/const FIELD_LABELS[^=]*=\s*\{([\s\S]*?)\};/)
  if (!blockMatch) throw new Error('FIELD_LABELS not found in plugin.ts')
  const map = new Map<string, string>()
  for (const m of blockMatch[1].matchAll(/"?(\w+)"?\s*:\s*"([^"]+)"/g)) {
    map.set(m[1], m[2])
  }
  return map
}

/** Extract option value="" ids from the control-field <select> in inspector.html. */
function inspectorFieldIds(): string[] {
  const html = readFileSync(INSPECTOR_HTML, 'utf8')
  const selectMatch = html.match(/id="control-field"[\s\S]*?<\/select>/)
  if (!selectMatch) throw new Error('control-field select not found in inspector.html')
  const ids: string[] = []
  for (const m of selectMatch[0].matchAll(/<option value="([^"]+)">/g)) {
    ids.push(m[1])
  }
  return ids
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('Stream Deck FIELD_LABELS: no raw camelCase labels', () => {
  it('every label in FIELD_LABELS differs from its raw field id', () => {
    const labels = parsedFieldLabels()
    expect(labels.size).toBeGreaterThan(10)
    for (const [id, label] of labels) {
      expect(label).not.toBe(id)
    }
  })
})

describe('Stream Deck inspector field ids and FIELD_LABELS cover the same fields', () => {
  it('no field id in the inspector is missing from FIELD_LABELS', () => {
    const labels = parsedFieldLabels()
    const inspectorIds = inspectorFieldIds()
    expect(inspectorIds.length).toBeGreaterThan(10)
    const missing = inspectorIds.filter((id) => !labels.has(id))
    expect(missing).toEqual([])
  })

  it('no field id in FIELD_LABELS is missing from the inspector', () => {
    const labels = parsedFieldLabels()
    const inspectorIds = new Set(inspectorFieldIds())
    const missing = [...labels.keys()].filter((id) => !inspectorIds.has(id))
    expect(missing).toEqual([])
  })
})

describe('Stream Deck inspector field labels: no raw camelCase', () => {
  it('every <option> text in the control-field select differs from its value attribute', () => {
    const html = readFileSync(INSPECTOR_HTML, 'utf8')
    const selectMatch = html.match(/id="control-field"[\s\S]*?<\/select>/)
    if (!selectMatch) throw new Error('control-field select not found')
    for (const m of selectMatch[0].matchAll(/<option value="([^"]+)">([^<]+)<\/option>/g)) {
      const id = m[1]
      const label = m[2].trim()
      expect(label).not.toBe(id)
    }
  })
})
