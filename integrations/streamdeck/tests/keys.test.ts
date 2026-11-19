// What the keys send and show (src/keys.ts), without the Stream Deck runtime.

import { setValueFor, playbackKeyAllowed, playbackKeyCommand, playbackKeyTitle, recKeyState, driveCommand, driveStopCommand, DriveHold } from '../src/keys'
import type { AnyField, Camera } from '../src/protocol'

const choice = (value: unknown, writable = true): AnyField => ({ value, options: [value], writable } as AnyField)

describe('Any Control: a typed value as the field takes it', () => {
  it('a number field gets a number', () => {
    expect(setValueFor('1600', choice(800))).toBe(1600)
    expect(setValueFor('2.8', choice(4))).toBe(2.8)
    expect(setValueFor('fast', choice(800))).toBeUndefined()
  })
  it('a string field keeps the text, even when it looks like a number', () => {
    expect(setValueFor('23.98', choice('25'))).toBe('23.98')
    expect(setValueFor(' S-Log3 ', choice('709'))).toBe('S-Log3')
  })
  it('a bool field gets true or false, nothing else', () => {
    expect(setValueFor('true', choice(false))).toBe(true)
    expect(setValueFor('False', choice(true))).toBe(false)
    expect(setValueFor('1', choice(false))).toBeUndefined()
  })
  it('nothing typed sends nothing (Number("") is 0)', () => {
    expect(setValueFor('', choice(800))).toBeUndefined()
    expect(setValueFor('   ', undefined)).toBeUndefined()
    expect(setValueFor(undefined, undefined)).toBeUndefined()
  })
  it('without a camera, by its look', () => {
    expect(setValueFor('3200', undefined)).toBe(3200)
    expect(setValueFor('true', undefined)).toBe(true)
    expect(setValueFor('Clear', undefined)).toBe('Clear')
  })
})

describe('Playback key', () => {
  const inReview = {
    fields: { playbackMode: choice('review'), playing: choice(true) },
    playback: { clip: 'A001C003', commands: ['togglePlay', 'play', 'pause', 'next', 'previous', 'live'] },
  }

  it('sends the transport command, skip with its seconds, and Live/Review as a cycle of playbackMode', () => {
    expect(playbackKeyCommand('next')).toEqual({ playback: 'next' })
    expect(playbackKeyCommand('skip', -15)).toEqual({ playback: 'skip', by: -15 })
    expect(playbackKeyCommand('skip')).toEqual({ playback: 'skip', by: 5 })
    // playbackMode is a string field: the server won't toggle it, but cycles its two options.
    expect(playbackKeyCommand('liveReviewToggle')).toEqual({ cycle: 'playbackMode' })
  })

  it('goes out only when the camera takes it now', () => {
    expect(playbackKeyAllowed(inReview, 'next')).toBe(true)
    expect(playbackKeyAllowed(inReview, 'skip')).toBe(false)
    expect(playbackKeyAllowed(inReview, 'review')).toBe(false)
    expect(playbackKeyAllowed({ fields: {}, playback: { commands: [] } }, 'togglePlay')).toBe(false)
    expect(playbackKeyAllowed({ fields: {} }, 'togglePlay')).toBe(false)
    expect(playbackKeyAllowed(undefined, 'next')).toBe(true)
  })

  it('Live/Review needs the switch, and not while recording', () => {
    expect(playbackKeyAllowed(inReview, 'liveReviewToggle')).toBe(true)
    expect(playbackKeyAllowed({ fields: { playbackMode: choice('live', false) } }, 'liveReviewToggle')).toBe(false)
    expect(playbackKeyAllowed({ fields: {} }, 'liveReviewToggle')).toBe(false)
  })

  it('titles in a few letters', () => {
    expect(playbackKeyTitle('previous')).toBe('PREV')
    expect(playbackKeyTitle('skip', 15)).toBe('+15s')
    expect(playbackKeyTitle('skip', -5)).toBe('-5s')
    expect(playbackKeyTitle('liveReviewToggle')).toBe('LIVE\nREVIEW')
  })
})

describe('driveCommand and driveStopCommand', () => {
  it.each([
    ['focus', 'far', 3, 3], ['focus', 'near', 3, -3], ['zoom', 'tele', 5, 5], ['zoom', 'wide', 5, -5],
  ] as const)('%s %s at %i: speed %i, for half a second', (motor, direction, speed, signed) => {
    expect(driveCommand(motor, direction, speed)).toEqual({ drive: motor, speed: signed, seconds: 0.5 })
  })
  it.each(['focus', 'zoom'] as const)('stop %s: speed 0', (motor) => {
    expect(driveStopCommand(motor)).toEqual({ drive: motor, speed: 0 })
  })
})

describe('REC key', () => {
  const take = '2026-10-29T12:00:00Z'
  const cam = (connection: Camera['connection'], record?: AnyField): Pick<Camera, 'connection' | 'fields'> =>
    ({ connection, fields: record ? { record } : {} })

  it('red, from the take\'s start, for a camera Tiles has and that is recording', () => {
    expect(recKeyState(cam('connected', { value: 'recording', writable: true, startedAt: take }), true))
      .toEqual({ state: 1, startedAt: take })
  })

  it('never red for a camera Tiles has lost, or with the app gone: what it last said isn\'t known', () => {
    const recording = { value: 'recording', writable: true, startedAt: take } as AnyField
    for (const connection of ['disconnected', 'stale', 'connecting', 'failed'] as const) {
      expect(recKeyState(cam(connection, recording), true)).toEqual({ state: 0 })
    }
    expect(recKeyState(cam('connected', recording), false)).toEqual({ state: 0 })
    expect(recKeyState(undefined, true)).toEqual({ state: 0 })
  })

  it('pending while a request is on its way; dark when REC is unknown, idle or absent', () => {
    expect(recKeyState(cam('connected', { value: 'idle', writable: true, request: 'start' }), true)).toEqual({ state: 2 })
    expect(recKeyState(cam('connected', { value: 'unknown', writable: true }), true)).toEqual({ state: 0 })
    expect(recKeyState(cam('connected', { value: 'idle', writable: true }), true)).toEqual({ state: 0 })
    expect(recKeyState(cam('connected'), true)).toEqual({ state: 0 })
  })
})

describe('DriveHold: a held lens key', () => {
  beforeEach(() => { jest.useFakeTimers() })
  afterEach(() => { jest.useRealTimers() })

  it('drives at once and every 250 ms while held, then stops once when let go', () => {
    const hold = new DriveHold()
    const drive = jest.fn(), stop = jest.fn()
    hold.start('key', drive, stop)
    expect(drive).toHaveBeenCalledTimes(1)
    jest.advanceTimersByTime(760)
    expect(drive).toHaveBeenCalledTimes(4)
    hold.release('key')
    hold.release('key')
    expect(stop).toHaveBeenCalledTimes(1)
    jest.advanceTimersByTime(1000)
    expect(drive).toHaveBeenCalledTimes(4)
    expect(hold.count).toBe(0)
  })

  it('a key let go without being held sends nothing', () => {
    const hold = new DriveHold()
    const drive = jest.fn(), stop = jest.fn()
    hold.start('other', drive, stop)
    hold.release('key')
    expect(stop).not.toHaveBeenCalled()
    expect(hold.count).toBe(1)
    hold.releaseAll(false)
  })

  it('pressed again while held: one renewal timer, not two, and one stop', () => {
    const hold = new DriveHold()
    const drive = jest.fn(), stop = jest.fn()
    hold.start('key', drive, stop)
    hold.start('key', drive, stop)
    jest.advanceTimersByTime(260)
    expect(drive).toHaveBeenCalledTimes(3)
    hold.release('key')
    expect(stop).toHaveBeenCalledTimes(1)
  })

  it('a lost connection lets every key go without a stop', () => {
    const hold = new DriveHold()
    const drive = jest.fn(), stop = jest.fn()
    hold.start('focus', drive, stop)
    hold.start('zoom', drive, stop)
    hold.releaseAll(false)
    jest.advanceTimersByTime(1000)
    expect(drive).toHaveBeenCalledTimes(2)
    expect(stop).not.toHaveBeenCalled()
    expect(hold.count).toBe(0)
  })
})
