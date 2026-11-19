// What the keys send and show, without the Stream Deck runtime, so the tests can run it.

import type { AnyField, Camera, Command, PlaybackCommand, PlaybackStatus, RecordField } from "./protocol.js";

/**
 * What the REC key shows: 0 idle (or nothing known), 1 recording, from `startedAt`, 2 a request on its way. Lit only
 * for a camera Tiles has now: what a lost one last said about REC isn't known.
 */
export function recKeyState(cam: Pick<Camera, "connection" | "fields"> | undefined,
                            linked: boolean): { state: 0 | 1 | 2; startedAt?: string } {
  if (!cam || !linked || cam.connection !== "connected") return { state: 0 };
  const rec = cam.fields["record"] as RecordField | undefined;
  if (!rec || rec.value === "unknown") return { state: 0 };
  if (rec.request) return { state: 2 };
  return rec.value === "recording" ? { state: 1, startedAt: rec.startedAt } : { state: 0 };
}

/** The Playback key's choices: the API's transport commands, plus Live/Review (the `playbackMode` field). */
export type PlaybackKeyCommand =
  | "togglePlay" | "play" | "pause" | "stop" | "next" | "previous" | "fastForward" | "rewind"
  | "recReview" | "review" | "live" | "liveReviewToggle" | "skip";

/**
 * An Any Control key's typed-in value, as the field takes it: a field whose value is a number gets a number, a bool
 * field `true`/`false`, a string field the text as typed (a frame rate of "23.98" stays a string). Without a camera
 * to look at, numbers and bools by their look. undefined when there's nothing to send.
 */
export function setValueFor(raw: string | undefined, field?: AnyField): string | number | boolean | undefined {
  const text = (raw ?? "").trim();
  if (text === "") return undefined;
  const current = field ? (field as { value?: unknown }).value : undefined;
  const asBool = text.toLowerCase() === "true" ? true : text.toLowerCase() === "false" ? false : undefined;
  const asNumber = Number(text);
  if (typeof current === "boolean") return asBool;
  if (typeof current === "number") return Number.isFinite(asNumber) ? asNumber : undefined;
  if (typeof current === "string") return text;
  if (asBool !== undefined) return asBool;
  return Number.isFinite(asNumber) ? asNumber : text;
}

/** What a Playback key sends. Live/Review cycles `playbackMode` (a string field: there's nothing to toggle). */
export function playbackKeyCommand(cmd: PlaybackKeyCommand, skipSeconds?: number): Command | PlaybackCommand {
  if (cmd === "liveReviewToggle") return { cycle: "playbackMode" };
  if (cmd === "skip") return { playback: "skip", by: skipSeconds || 5 };
  return { playback: cmd };
}

/**
 * Whether the camera takes the key's command now. Unknown camera (a page or all-cameras key): let the app decide.
 * Live/Review needs a writable `playbackMode` (not into review while recording); the rest must be in `commands`.
 */
export function playbackKeyAllowed(
  cam: { fields: Record<string, AnyField>; playback?: PlaybackStatus } | undefined,
  cmd: PlaybackKeyCommand,
): boolean {
  if (!cam) return true;
  if (cmd === "liveReviewToggle") {
    const mode = cam.fields["playbackMode"] as { writable?: boolean } | undefined;
    return mode?.writable === true;
  }
  return cam.playback?.commands.includes(cmd) ?? false;
}

/** The motor that a drive command moves. */
export type DriveMotor = "focus" | "zoom";

/** A held key's drive goes out this often, each running this long: the app lets a newer one take over. */
export const DRIVE_RENEW_MS = 250;
export const DRIVE_SECONDS = 0.5;
/** An FX6's fastest. */
export const DRIVE_MAX_SPEED = 8;

/** Direction for Focus and Zoom keys, chosen in the property inspector. */
export type FocusDirection = "near" | "far";
export type ZoomDirection  = "wide" | "tele";

/** Build a `drive` command from key settings. Speed 0 stops the motor. */
export function driveCommand(
  motor: DriveMotor,
  direction: FocusDirection | ZoomDirection,
  speed: number,
): { drive: DriveMotor; speed: number; seconds: number } {
  // Far and Tele are the motor's + way.
  const forward = direction === "far" || direction === "tele";
  return { drive: motor, speed: forward ? speed : -speed, seconds: DRIVE_SECONDS };
}

/** Build a stop command (speed 0) for a motor. */
export function driveStopCommand(motor: DriveMotor): { drive: DriveMotor; speed: number } {
  return { drive: motor, speed: 0 };
}

/**
 * Held lens keys: a key's drive goes out at once and again every `renewEvery` ms (each drive runs half a second, and
 * the app lets a newer one take over with no stop between), and its stop goes out once, when it's let go. A key let
 * go without being held sends nothing.
 */
export class DriveHold {
  private readonly held = new Map<string, { timer: ReturnType<typeof setInterval>; stop: () => void }>();

  constructor(private readonly renewEvery = DRIVE_RENEW_MS) {}

  /** Starts the key's drive, or starts it again: `drive` now and on each renewal, `stop` when it's let go. */
  start(key: string, drive: () => void, stop: () => void): void {
    this.end(key, false);
    drive();
    this.held.set(key, { timer: setInterval(drive, this.renewEvery), stop });
  }

  /** Lets the key go: no more renewals, and its stop unless there's no connection to send it on. */
  release(key: string, sendStop = true): void {
    this.end(key, sendStop);
  }

  /** Lets every held key go (a lost connection: no stops, as nothing can carry them). */
  releaseAll(sendStop: boolean): void {
    for (const key of [...this.held.keys()]) this.end(key, sendStop);
  }

  get count(): number {
    return this.held.size;
  }

  private end(key: string, sendStop: boolean): void {
    const hold = this.held.get(key);
    if (!hold) return;
    clearInterval(hold.timer);
    this.held.delete(key);
    if (sendStop) hold.stop();
  }
}

/** A Playback key's title: the command in a few letters, since every one shares the play icon. */
export function playbackKeyTitle(cmd: PlaybackKeyCommand, skipSeconds?: number): string {
  switch (cmd) {
    case "togglePlay": return "PLAY\nPAUSE";
    case "play": return "PLAY";
    case "pause": return "PAUSE";
    case "stop": return "STOP";
    case "next": return "NEXT";
    case "previous": return "PREV";
    case "fastForward": return "FF";
    case "rewind": return "REW";
    case "recReview": return "REC\nREVIEW";
    case "review": return "REVIEW";
    case "live": return "LIVE";
    case "liveReviewToggle": return "LIVE\nREVIEW";
    case "skip": {
      const by = skipSeconds || 5;
      return `${by > 0 ? "+" : ""}${by}s`;
    }
  }
}
