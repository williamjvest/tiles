/**
 * Tiles Stream Deck Plugin — @elgato/streamdeck SDK v3
 *
 * All actions share a single WebSocket connection to Tiles.
 * Connection host/port/token live in global settings (set via the property
 * inspector's "Connection" section); per-action settings hold only the camera
 * UUID and "use current page" flag.
 *
 * Dial (encoder) actions require a Stream Deck + device.
 */

import streamDeck, {
  action,
  type DidReceiveSettingsEvent,
  type KeyDownEvent,
  type KeyUpEvent,
  type KeyAction,
  type DialAction,
  type WillAppearEvent,
  type WillDisappearEvent,
  type DialRotateEvent,
  type DialDownEvent,
  SingletonAction,
} from "@elgato/streamdeck";
import type { JsonObject } from "@elgato/utils";

import {
  connected,
  cameras,
  pages,
  appLocked,
  getField,
  sendCommand,
  applyGlobalSettings,
  onConnectionChange,
  type GlobalSettings,
} from "./connection.js";

import type { ChoiceField, LevelField, RecordField, Command } from "./protocol.js";
import { setValueFor, playbackKeyAllowed, playbackKeyCommand, playbackKeyTitle, recKeyState, driveCommand, driveStopCommand, DriveHold, DRIVE_MAX_SPEED, type PlaybackKeyCommand, type DriveMotor, type FocusDirection, type ZoomDirection } from "./keys.js";

// ─── Field label map ──────────────────────────────────────────────────────────
// Maps API field ids to short human labels for user-visible key titles.

const FIELD_LABELS: Record<string, string> = {
  iso: "ISO",
  baseISO: "Base ISO",
  shutterMode: "Shutter Mode",
  shutterAngle: "Shutter",
  shutterSpeed: "Shutter",
  wbPreset: "White Balance",
  kelvin: "Kelvin",
  tint: "Tint",
  iris: "Iris",
  ndPreset: "ND",
  variableND: "ND",
  frameRate: "FPS",
  frameRateVariable: "FPS Variable",
  offSpeedRate: "Off-Speed Rate",
  dynamicRange: "Dynamic Range",
  resolution: "Resolution",
  codec: "Codec",
  bitrate: "Bitrate",
  desqueeze: "De-squeeze",
  lut: "LUT",
  look: "LUT",
  falseColor: "False Color",
  zebra: "Zebra",
  focusAssist: "Focus Assist",
  frameGuides: "Frame Guides",
  frameGrids: "Frame Grids",
  safeArea: "Safe Area",
  cleanFeed: "Clean Feed",
  statusText: "Status Text",
  zebraLevel: "Zebra Level",
  frameGuideRatio: "Frame Guide Ratio",
  focusMode: "Focus Mode",
  colorBars: "Color Bars",
  hdmiInfo: "HDMI Info",
  gridLines: "Grid Lines",
  ndMode: "ND Mode",
  tally: "Tally",
  call: "Call",
  colorGamut: "Color Gamut",
  imageFlip: "Sensor Flip",
  clipFlag: "Clip Flag",
  timecodeDuration: "TC / Duration",
  playbackMode: "Playback Mode",
  playing: "Playing",
  userFrameA: "User Frame A",
  userFrameB: "User Frame B",
  shootingMode: "Shooting Mode",
  gain: "Gain",
  baseSensitivity: "Base Sensitivity",
  recordedLUT: "Recorded LUT",
  proxy: "Proxy",
  ecs: "ECS",
  irisAuto: "Iris Auto",
  ndAuto: "ND Auto",
  isoAuto: "ISO Auto",
  steadyShot: "SteadyShot",
  imagerMode: "Imager Mode",
  subjectRecognition: "Subject Recognition AF",
  focusArea: "Focus Area",
  afTransitionSpeed: "AF Transition Speed",
  afSubjectShift: "AF Subject Shift",
  afAssist: "AF Assist",
};

/** Boolean field ids whose values should display as ON / OFF. */
const BOOL_FIELD_IDS = new Set([
  "look", "falseColor", "colorBars", "imageFlip", "frameRateVariable",
  "zebra", "focusAssist", "frameGuides", "frameGrids", "safeArea",
  "cleanFeed", "statusText", "hdmiInfo", "gridLines", "call",
  "timecodeDuration", "playing", "recordedLUT", "proxy", "ecs",
  "irisAuto", "ndAuto", "isoAuto", "afAssist",
]);

// ─── Settings types ───────────────────────────────────────────────────────────

/** Per-action settings — stored per key/dial instance. */
interface ActionSettings extends JsonObject {
  /** Camera UUID. Absent = use current page. */
  cameraID?: string;
  /** Display label only — stored so the inspector dropdown can show it. */
  cameraDisplayLabel?: string;
  /** If true, target the app's current page instead of a fixed camera. */
  useCurrentPage?: boolean;
}


// ─── Helpers ──────────────────────────────────────────────────────────────────

function targetFor(s: ActionSettings): { cameraID: string } | { currentPage: true } {
  if (s.useCurrentPage || !s.cameraID) return { currentPage: true };
  return { cameraID: s.cameraID };
}

function sendCameraCommand(s: ActionSettings, command: Command): void {
  sendCommand({ type: "command", target: targetFor(s), command });
}

function resolveFromSettings(s: ActionSettings) {
  if (s.useCurrentPage || !s.cameraID) {
    const pg = pages.find(p => p.current);
    if (pg?.cameras.length) return cameras.get(pg.cameras[0]);
    return undefined;
  }
  return cameras.get(s.cameraID);
}

// ─── Global settings ──────────────────────────────────────────────────────────

// Load on startup and whenever they change
streamDeck.settings.onDidReceiveGlobalSettings<GlobalSettings & JsonObject>((ev) => {
  applyGlobalSettings(ev.settings);
});

// ─── REC Action ───────────────────────────────────────────────────────────────
//
// States: 0 = idle/unknown, 1 = recording (red), 2 = pending
// REC is never red before the camera confirms recording.

@action({ UUID: "com.toldwell.twcc.rec" })
class RecAction extends SingletonAction<ActionSettings> {
  // Per-action-id: settings cache, the live REC timer and the take it counts
  private _settings    = new Map<string, ActionSettings>();
  private _timers      = new Map<string, ReturnType<typeof setInterval>>();
  private _timerStarts = new Map<string, string>();
  private _unsubs      = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._clearTimer(ev.action.id);
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const cam = resolveFromSettings(ev.payload.settings);
    if (!cam || cam.connection !== "connected") { await ev.action.showAlert(); return; }
    const rec = getField<RecordField>(cam, "record");
    if (!rec || rec.value === "unknown") { await ev.action.showAlert(); return; }
    // Show pending state immediately (state 2)
    if (ev.action.isKey()) await ev.action.setState(2);
    sendCameraCommand(ev.payload.settings, { toggle: "record" });
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private _clearTimer(id: string): void {
    const t = this._timers.get(id);
    if (t !== undefined) { clearInterval(t); this._timers.delete(id); }
    this._timerStarts.delete(id);
  }

  private async _refresh(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const { state, startedAt } = recKeyState(resolveFromSettings(s), connected);
    await a.setState(state);
    if (state !== 1 || !startedAt) {
      this._clearTimer(a.id);
      await a.setTitle(connected ? "" : "REC\n—");
      return;
    }
    const tick = async (): Promise<void> => {
      const elapsed = Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000);
      const mm = Math.floor(elapsed / 60).toString().padStart(2, "0");
      const ss = (elapsed % 60).toString().padStart(2, "0");
      await a.setTitle(`REC\n${mm}:${ss}`);
    };
    await tick();
    // One timer per key, for the take it was started for: a new take (after a reconnect, or another camera's on a
    // current-page key) gets a timer of its own.
    if (this._timerStarts.get(a.id) !== startedAt) {
      this._clearTimer(a.id);
      this._timers.set(a.id, setInterval(() => { void tick(); }, 1000));
      this._timerStarts.set(a.id, startedAt);
    }
  }
}

// ─── Scalar step/cycle actions — shared base ──────────────────────────────────

abstract class ValueKeyAction extends SingletonAction<ActionSettings> {
  protected abstract fieldName: string;

  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refreshTitle(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refreshTitle(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refreshTitle(keyAction, ev.payload.settings);
  }

  /** The key's tick: the command went out (the app's own result isn't waited for). */
  protected async _confirmSent(a: KeyAction<ActionSettings>): Promise<void> {
    await a.showOk();
  }

  /** The field the title shows: the one the key changes (the shutter's depends on its mode). */
  protected _displayField(_s: ActionSettings): string {
    return this.fieldName;
  }

  protected async _refreshTitle(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const field = cam ? cam.fields[this._displayField(s)] : undefined;
    const label = this._label();
    await a.setTitle(field ? `${label}\n${field.value}` : label);
  }

  protected abstract _label(): string;
}

// ─── − and + keys ─────────────────────────────────────────────────────────────

/**
 * A − or + key: one step of its field, the way the camera steps it. A camera without the field gets the alert rather
 * than a command it would turn down.
 */
abstract class StepKeyAction extends ValueKeyAction {
  protected abstract by: number;

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const field = this._displayField(ev.payload.settings);
    const cam = resolveFromSettings(ev.payload.settings);
    if (cam && !cam.fields[field]) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { step: field, by: this.by });
    if (ev.action.isKey()) await this._confirmSent(ev.action);
  }
}

function shutterField(s: ActionSettings): string {
  const cam = resolveFromSettings(s);
  const mode = cam ? getField<ChoiceField<string>>(cam, "shutterMode") : undefined;
  return mode?.value === "speed" ? "shutterSpeed" : "shutterAngle";
}

@action({ UUID: "com.toldwell.twcc.iso-up" })
class ISOUpAction extends StepKeyAction { protected fieldName = "iso"; protected by = 1; protected _label() { return "ISO+"; } }

@action({ UUID: "com.toldwell.twcc.iso-down" })
class ISODownAction extends StepKeyAction { protected fieldName = "iso"; protected by = -1; protected _label() { return "ISO−"; } }

/** The shutter's keys step and show its angle or its speed, whichever mode it's in. */
@action({ UUID: "com.toldwell.twcc.shutter-up" })
class ShutterUpAction extends StepKeyAction {
  protected fieldName = "shutterAngle";
  protected by = 1;
  protected _label() { return "SHT+"; }
  protected override _displayField(s: ActionSettings): string { return shutterField(s); }
}

@action({ UUID: "com.toldwell.twcc.shutter-down" })
class ShutterDownAction extends StepKeyAction {
  protected fieldName = "shutterAngle";
  protected by = -1;
  protected _label() { return "SHT−"; }
  protected override _displayField(s: ActionSettings): string { return shutterField(s); }
}

@action({ UUID: "com.toldwell.twcc.iris-up" })
class IrisUpAction extends StepKeyAction { protected fieldName = "iris"; protected by = 1; protected _label() { return "IRIS+"; } }

@action({ UUID: "com.toldwell.twcc.iris-down" })
class IrisDownAction extends StepKeyAction { protected fieldName = "iris"; protected by = -1; protected _label() { return "IRIS−"; } }

@action({ UUID: "com.toldwell.twcc.kelvin-up" })
class KelvinUpAction extends StepKeyAction { protected fieldName = "kelvin"; protected by = 1; protected _label() { return "K+"; } }

@action({ UUID: "com.toldwell.twcc.kelvin-down" })
class KelvinDownAction extends StepKeyAction { protected fieldName = "kelvin"; protected by = -1; protected _label() { return "K−"; } }

@action({ UUID: "com.toldwell.twcc.nd-up" })
class NDUpAction extends StepKeyAction { protected fieldName = "ndPreset"; protected by = 1; protected _label() { return "ND+"; } }

@action({ UUID: "com.toldwell.twcc.nd-down" })
class NDDownAction extends StepKeyAction { protected fieldName = "ndPreset"; protected by = -1; protected _label() { return "ND−"; } }

@action({ UUID: "com.toldwell.twcc.tint-up" })
class TintUpAction extends StepKeyAction { protected fieldName = "tint"; protected by = 1; protected _label() { return "TINT+"; } }

@action({ UUID: "com.toldwell.twcc.tint-down" })
class TintDownAction extends StepKeyAction { protected fieldName = "tint"; protected by = -1; protected _label() { return "TINT−"; } }

// ─── WB Preset cycle ─────────────────────────────────────────────────────────

@action({ UUID: "com.toldwell.twcc.wb-cycle" })
class WBCycleAction extends ValueKeyAction {
  protected fieldName = "wbPreset";
  protected _label() { return "WB"; }
  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { cycle: "wbPreset" });
    if (ev.action.isKey()) await this._confirmSent(ev.action);
  }
}

// ─── LUT on/off ──────────────────────────────────────────────────────────────

@action({ UUID: "com.toldwell.twcc.lut" })
class LUTAction extends SingletonAction<ActionSettings> {
  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { toggle: "look" });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const look = cam ? getField<ChoiceField<boolean>>(cam, "look") : undefined;
    await a.setState(look?.value ? 1 : 0);
  }
}

// ─── False color ─────────────────────────────────────────────────────────────

@action({ UUID: "com.toldwell.twcc.false-color" })
class FalseColorAction extends SingletonAction<ActionSettings> {
  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { toggle: "falseColor" });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const fc = cam ? getField<ChoiceField<boolean>>(cam, "falseColor") : undefined;
    await a.setState(fc?.value ? 1 : 0);
  }
}

// ─── One-tap switches on a field (2.1.0) ───────────────────────────────────────
// A key that toggles one Boolean field of the camera and lights while it's on: the camera's answer, not the press.
// On a Blackmagic camera the monitoring fields cover every output (the app's tiles set one output at a time).

abstract class FieldToggleAction extends SingletonAction<ActionSettings> {
  protected abstract readonly field: string;
  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const cam = resolveFromSettings(ev.payload.settings);
    // A camera without the field (a Sony has no clean feed, a PYXIS no HDMI info) says so rather than sending.
    if (cam && !getField<ChoiceField<boolean>>(cam, this.field)) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { toggle: this.field });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const field = cam ? getField<ChoiceField<boolean>>(cam, this.field) : undefined;
    await a.setState(field?.value ? 1 : 0);
  }
}

@action({ UUID: "com.toldwell.twcc.clean-feed" })
class CleanFeedAction extends FieldToggleAction { protected readonly field = "cleanFeed"; }

@action({ UUID: "com.toldwell.twcc.status-text" })
class StatusTextAction extends FieldToggleAction { protected readonly field = "statusText"; }

@action({ UUID: "com.toldwell.twcc.zebra" })
class ZebraAction extends FieldToggleAction { protected readonly field = "zebra"; }

@action({ UUID: "com.toldwell.twcc.focus-assist" })
class FocusAssistAction extends FieldToggleAction { protected readonly field = "focusAssist"; }

@action({ UUID: "com.toldwell.twcc.frame-guides" })
class FrameGuidesAction extends FieldToggleAction { protected readonly field = "frameGuides"; }

@action({ UUID: "com.toldwell.twcc.hdmi-info" })
class HDMIInfoAction extends FieldToggleAction { protected readonly field = "hdmiInfo"; }

@action({ UUID: "com.toldwell.twcc.grid-lines" })
class GridLinesAction extends FieldToggleAction { protected readonly field = "gridLines"; }

// ─── Frame rate cycle ────────────────────────────────────────────────────────

@action({ UUID: "com.toldwell.twcc.framerate-cycle" })
class FrameRateCycleAction extends ValueKeyAction {
  protected fieldName = "frameRate";
  protected _label() { return "FPS"; }
  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { cycle: "frameRate" });
    if (ev.action.isKey()) await this._confirmSent(ev.action);
  }
}

// ─── Show Page ───────────────────────────────────────────────────────────────

interface PageActionSettings extends ActionSettings {
  pageID?: string;
  pageDisplayName?: string;
}

@action({ UUID: "com.toldwell.twcc.show-page" })
class ShowPageAction extends SingletonAction<PageActionSettings> {
  override async onKeyDown(ev: KeyDownEvent<PageActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const pageID = ev.payload.settings.pageID;
    if (!pageID) { await ev.action.showAlert(); return; }
    sendCommand({ type: "app", action: "showPage", pageID });
    if (ev.action.isKey()) await ev.action.showOk();
  }
  override async onWillAppear(ev: WillAppearEvent<PageActionSettings>): Promise<void> {
    const name = ev.payload.settings.pageDisplayName;
    if (name && ev.action.isKey()) await ev.action.setTitle(name);
  }
  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<PageActionSettings>): void {
    const name = ev.payload.settings.pageDisplayName;
    if (name && ev.action.isKey()) void ev.action.setTitle(name);
  }
}

// ─── Link toggle ─────────────────────────────────────────────────────────────

interface LinkActionSettings extends ActionSettings {
  pageID?: string;
}

@action({ UUID: "com.toldwell.twcc.link-toggle" })
class LinkToggleAction extends SingletonAction<LinkActionSettings> {
  private _settings = new Map<string, LinkActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<LinkActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<LinkActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<LinkActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const pageID = ev.payload.settings.pageID;
    if (!pageID) { await ev.action.showAlert(); return; }
    const pg = pages.find(p => p.id === pageID);
    const enabled = !(pg?.linking ?? false);
    sendCommand({ type: "app", action: "setLinking", pageID, enabled });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<LinkActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<LinkActionSettings>, s: LinkActionSettings): Promise<void> {
    const pg = pages.find(p => p.id === s.pageID);
    await a.setState(pg?.linking ? 1 : 0);
  }
}

// ─── Dial actions — shared base ───────────────────────────────────────────────

abstract class DialOnlyAction extends SingletonAction<ActionSettings> {
  protected abstract dialFieldName: string;
  /** The field the dial shows: the one it turns (the shutter's depends on its mode). */
  protected _dialField(_s: ActionSettings): string { return this.dialFieldName; }
  protected abstract dialLabel: string;

  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isDial()) return;
    const dialAction = ev.action;
    this._settings.set(dialAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(dialAction.id);
      if (s) void refreshDialFeedback(dialAction, s, this._dialField(s), this.dialLabel);
    });
    this._unsubs.set(dialAction.id, unsub);
    await dialAction.setFeedbackLayout("$A1");
    await dialAction.setTriggerDescription(this._triggerDescription());
    await refreshDialFeedback(dialAction, ev.payload.settings, this._dialField(ev.payload.settings), this.dialLabel);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isDial()) return;
    const dialAction = ev.action;
    this._settings.set(dialAction.id, ev.payload.settings);
    void refreshDialFeedback(dialAction, ev.payload.settings, this._dialField(ev.payload.settings), this.dialLabel);
  }

  protected abstract _triggerDescription(): { rotate: string; push: string };
}

// ─── ISO dial ─────────────────────────────────────────────────────────────────
// Press: toggle base ISO if present; otherwise step by 1

@action({ UUID: "com.toldwell.twcc.dial-iso" })
class ISODialAction extends DialOnlyAction {
  protected dialFieldName = "iso";
  protected dialLabel = "ISO";
  protected _triggerDescription() { return { rotate: "Adjust ISO", push: "Toggle base ISO" }; }

  override async onDialRotate(ev: DialRotateEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "iso", by: ev.payload.ticks });
  }
  override async onDialDown(ev: DialDownEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    const cam = resolveFromSettings(ev.payload.settings);
    const baseISO = cam ? getField<ChoiceField>(cam, "baseISO") : undefined;
    if (baseISO) {
      sendCameraCommand(ev.payload.settings, { toggle: "baseISO" });
    } else {
      sendCameraCommand(ev.payload.settings, { step: "iso", by: 1 });
    }
  }
}

// ─── Shutter dial ─────────────────────────────────────────────────────────────
// Press: toggle shutter mode angle↔speed

@action({ UUID: "com.toldwell.twcc.dial-shutter" })
class ShutterDialAction extends DialOnlyAction {
  protected dialFieldName = "shutterAngle";
  protected dialLabel = "SHT";
  protected override _dialField(s: ActionSettings): string { return shutterField(s); }
  protected _triggerDescription() { return { rotate: "Adjust shutter", push: "Toggle angle/speed mode" }; }

  override async onDialRotate(ev: DialRotateEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: shutterField(ev.payload.settings), by: ev.payload.ticks });
  }
  override async onDialDown(ev: DialDownEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    // Cycle shutterMode angle↔speed (two-option string choice, not boolean)
    sendCameraCommand(ev.payload.settings, { cycle: "shutterMode" });
  }
}

// ─── Kelvin dial ─────────────────────────────────────────────────────────────
// Press: cycle WB preset

@action({ UUID: "com.toldwell.twcc.dial-kelvin" })
class KelvinDialAction extends DialOnlyAction {
  protected dialFieldName = "kelvin";
  protected dialLabel = "KELVIN";
  protected _triggerDescription() { return { rotate: "Adjust colour temperature", push: "Cycle WB preset" }; }

  override async onDialRotate(ev: DialRotateEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "kelvin", by: ev.payload.ticks });
  }
  override async onDialDown(ev: DialDownEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { cycle: "wbPreset" });
  }
}

// ─── Tint dial ───────────────────────────────────────────────────────────────
// Press: reset tint to center (step toward 0)

@action({ UUID: "com.toldwell.twcc.dial-tint" })
class TintDialAction extends DialOnlyAction {
  protected dialFieldName = "tint";
  protected dialLabel = "TINT";
  protected _triggerDescription() { return { rotate: "Adjust tint", push: "Step tint toward 0" }; }

  override async onDialRotate(ev: DialRotateEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "tint", by: ev.payload.ticks });
  }
  override async onDialDown(ev: DialDownEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    const cam = resolveFromSettings(ev.payload.settings);
    const tint = cam ? getField<LevelField>(cam, "tint") : undefined;
    if (!tint) return;
    // Step one increment toward 0
    const by = tint.value > 0 ? -1 : tint.value < 0 ? 1 : 0;
    if (by !== 0) sendCameraCommand(ev.payload.settings, { step: "tint", by });
  }
}

// ─── Iris dial ────────────────────────────────────────────────────────────────
// Press: step iris open by 1

@action({ UUID: "com.toldwell.twcc.dial-iris" })
class IrisDialAction extends DialOnlyAction {
  protected dialFieldName = "iris";
  protected dialLabel = "IRIS";
  protected _triggerDescription() { return { rotate: "Adjust iris", push: "Open iris one stop" }; }

  override async onDialRotate(ev: DialRotateEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "iris", by: ev.payload.ticks });
  }
  override async onDialDown(ev: DialDownEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "iris", by: 1 });
  }
}

// ─── Variable ND dial ─────────────────────────────────────────────────────────
// Press: step ND down (less ND)

@action({ UUID: "com.toldwell.twcc.dial-nd" })
class NDDialAction extends DialOnlyAction {
  protected dialFieldName = "variableND";
  protected dialLabel = "ND";
  protected _triggerDescription() { return { rotate: "Adjust ND", push: "Decrease ND" }; }

  override async onDialRotate(ev: DialRotateEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "variableND", by: ev.payload.ticks });
  }
  override async onDialDown(ev: DialDownEvent<ActionSettings>): Promise<void> {
    if (!connected) return;
    sendCameraCommand(ev.payload.settings, { step: "variableND", by: -1 });
  }
}

// ─── Dial feedback helper ─────────────────────────────────────────────────────

async function refreshDialFeedback(
  a: DialAction<ActionSettings>,
  s: ActionSettings,
  fieldName: string,
  label: string
): Promise<void> {
  const cam = resolveFromSettings(s);
  const camLabel = cam?.label ?? "–";
  const field = cam ? cam.fields[fieldName] : undefined;
  const value = field ? String(field.value) : "–";
  await a.setFeedback({ title: label, value: `${camLabel} · ${value}` });
}

// ─── Any Control key ──────────────────────────────────────────────────────────

type AnyControlOperation = "set" | "step" | "toggle" | "cycle";

interface AnyControlSettings extends ActionSettings {
  controlField?: string;
  controlOp?: AnyControlOperation;
  controlValue?: string;
  controlBy?: number;
}

@action({ UUID: "com.toldwell.twcc.any-control" })
class AnyControlAction extends SingletonAction<AnyControlSettings> {
  private _settings = new Map<string, AnyControlSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<AnyControlSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<AnyControlSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<AnyControlSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const s = ev.payload.settings;
    const fieldName = s.controlField;
    const op = s.controlOp ?? "toggle";
    if (!fieldName) { await ev.action.showAlert(); return; }
    const cam = resolveFromSettings(s);
    if (cam && !cam.fields[fieldName]) { await ev.action.showAlert(); return; }
    let cmd: Command;
    if (op === "set") {
      // As the field takes it: a frame rate of "23.98" stays a string, a bool field gets true/false.
      const value = setValueFor(s.controlValue, cam?.fields[fieldName]);
      if (value === undefined) { await ev.action.showAlert(); return; }
      cmd = { set: fieldName, value };
    } else if (op === "step") {
      cmd = { step: fieldName, by: s.controlBy ?? 1 };
    } else if (op === "toggle") {
      cmd = { toggle: fieldName };
    } else {
      cmd = { cycle: fieldName };
    }
    sendCameraCommand(s, cmd);
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<AnyControlSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<AnyControlSettings>, s: AnyControlSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const fieldName = s.controlField;
    const humanLabel = fieldName ? (FIELD_LABELS[fieldName] ?? fieldName) : "ANY";
    if (!fieldName || !cam) { await a.setTitle(humanLabel); return; }
    const field = cam.fields[fieldName];
    if (field) {
      const raw = field.value;
      await a.setState(raw === true ? 1 : 0);
      let display: string;
      if (BOOL_FIELD_IDS.has(fieldName) && typeof raw === "boolean") {
        display = raw ? "ON" : "OFF";
      } else {
        display = String(raw);
      }
      await a.setTitle(`${humanLabel}\n${display}`);
    } else {
      await a.setState(0);
      await a.setTitle(humanLabel);
    }
  }
}

// ─── Playback key ─────────────────────────────────────────────────────────────

interface PlaybackKeySettings extends ActionSettings {
  playbackCmd?: PlaybackKeyCommand;
  skipSeconds?: number;
}

@action({ UUID: "com.toldwell.twcc.playback" })
class PlaybackKeyAction extends SingletonAction<PlaybackKeySettings> {
  private _settings = new Map<string, PlaybackKeySettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<PlaybackKeySettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<PlaybackKeySettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<PlaybackKeySettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const s = ev.payload.settings;
    const cmd = s.playbackCmd ?? "togglePlay";
    // A camera that doesn't take it now (not in its `commands`; no Review while recording) alerts instead.
    if (!playbackKeyAllowed(resolveFromSettings(s), cmd)) { await ev.action.showAlert(); return; }
    sendCommand({ type: "command", target: targetFor(s), command: playbackKeyCommand(cmd, s.skipSeconds) });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<PlaybackKeySettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<PlaybackKeySettings>, s: PlaybackKeySettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const playing = cam ? getField<ChoiceField<boolean>>(cam, "playing") : undefined;
    // play/pause/togglePlay keys light when playing
    const cmd = s.playbackCmd ?? "togglePlay";
    const reviewing = cam ? getField<ChoiceField<string>>(cam, "playbackMode")?.value === "review" : false;
    if (cmd === "play" || cmd === "pause" || cmd === "togglePlay") {
      await a.setState(playing?.value ? 1 : 0);
    } else if (cmd === "liveReviewToggle" || cmd === "review") {
      await a.setState(reviewing ? 1 : 0);
    } else {
      await a.setState(0);
    }
    await a.setTitle(playbackKeyTitle(cmd, s.skipSeconds));
  }
}

// ─── Lock key ────────────────────────────────────────────────────────────────

@action({ UUID: "com.toldwell.twcc.lock" })
class LockAction extends SingletonAction<ActionSettings> {
  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      void this._refresh(keyAction);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    sendCommand({ type: "app", action: "setLocked", enabled: !appLocked });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction);
  }

  private async _refresh(a: KeyAction<ActionSettings>): Promise<void> {
    await a.setState(appLocked ? 1 : 0);
  }
}

// ─── TC / Duration toggle key (VENICE) ────────────────────────────────────────

@action({ UUID: "com.toldwell.twcc.tc-duration" })
class TCDurationAction extends SingletonAction<ActionSettings> {
  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const cam = resolveFromSettings(ev.payload.settings);
    if (cam && !cam.fields["timecodeDuration"]) { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { toggle: "timecodeDuration" });
    if (ev.action.isKey()) await ev.action.showOk();
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const tc = cam ? getField<ChoiceField<boolean>>(cam, "timecodeDuration") : undefined;
    await a.setState(tc?.value ? 1 : 0);
  }
}

// ─── Lens drives: Focus, Zoom ─────────────────────────────────────────────────
//
// Held: the drive at once and every 250 ms (`DriveHold`). Let go or put away: one stop. A lost connection lets every
// held key go; the app stops a motor nothing renews.

interface DriveSettings extends ActionSettings {
  direction?: FocusDirection | ZoomDirection;
  speed?: number;
}

abstract class LensDriveAction extends SingletonAction<DriveSettings> {
  protected abstract readonly motor: DriveMotor;
  protected abstract readonly defaultDirection: FocusDirection | ZoomDirection;
  private readonly holds = new DriveHold();

  constructor() {
    super();
    onConnectionChange(() => { if (!connected) this.holds.releaseAll(false); });
  }

  override async onKeyDown(ev: KeyDownEvent<DriveSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const s = ev.payload.settings;
    const speed = Math.max(1, Math.min(DRIVE_MAX_SPEED, s.speed ?? 3));
    const direction = s.direction ?? this.defaultDirection;
    this.holds.start(ev.action.id,
      () => sendCameraCommand(s, driveCommand(this.motor, direction, speed)),
      () => sendCameraCommand(s, driveStopCommand(this.motor)));
  }

  override async onKeyUp(ev: KeyUpEvent<DriveSettings>): Promise<void> {
    this.holds.release(ev.action.id, connected);
  }

  override async onWillDisappear(ev: WillDisappearEvent<DriveSettings>): Promise<void> {
    this.holds.release(ev.action.id, connected);
  }
}

@action({ UUID: "com.toldwell.twcc.focus" })
class FocusAction extends LensDriveAction {
  protected readonly motor = "focus";
  protected readonly defaultDirection = "far";
}

@action({ UUID: "com.toldwell.twcc.zoom" })
class ZoomAction extends LensDriveAction {
  protected readonly motor = "zoom";
  protected readonly defaultDirection = "tele";
}

// ─── Assignable Button ────────────────────────────────────────────────────────

interface AssignableSettings extends ActionSettings {
  button?: number;
}

@action({ UUID: "com.toldwell.twcc.assignable" })
class AssignableAction extends SingletonAction<AssignableSettings> {
  override async onKeyDown(ev: KeyDownEvent<AssignableSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const button = Math.max(1, Math.min(10, ev.payload.settings.button ?? 1));
    sendCameraCommand(ev.payload.settings, { press: "assignable", button });
  }
}

// ─── Autofocus ────────────────────────────────────────────────────────────────

// Push autofocus, as the Autofocus tile pushes it: a Blackmagic camera's one-shot, an FX5's Push AF. The app decides:
// it takes it only while the camera's focus is manual (an FX5 with AF / MF on AF but its lens switched to MF is manual,
// which the fields can't show), and refuses it on a camera with no push.
@action({ UUID: "com.toldwell.twcc.autofocus" })
class AutofocusAction extends SingletonAction<ActionSettings> {
  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const cam = resolveFromSettings(ev.payload.settings);
    if (cam && cam.connection !== "connected") { await ev.action.showAlert(); return; }
    sendCameraCommand(ev.payload.settings, { press: "autofocus" });
  }
}

// ─── Grab Still ───────────────────────────────────────────────────────────────

// Grab Still: a still frame written to the camera's own card. The app rejects it on a camera with no still capture
// (`canGrabStill` absent/false). Key briefly shows "Saved" (ok) or "Failed" (alert) from `lastStill`, and shows an
// alert immediately if the camera can't do it.
@action({ UUID: "com.toldwell.twcc.grab-still" })
class GrabStillAction extends SingletonAction<ActionSettings> {
  private _settings = new Map<string, ActionSettings>();
  private _unsubs   = new Map<string, () => void>();
  private _lastSeen = new Map<string, typeof undefined | { saved: boolean; message?: string }>();

  override async onWillAppear(ev: WillAppearEvent<ActionSettings>): Promise<void> {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    const unsub = onConnectionChange(() => {
      const s = this._settings.get(keyAction.id);
      if (s) void this._refresh(keyAction, s);
    });
    this._unsubs.set(keyAction.id, unsub);
    await this._refresh(keyAction, ev.payload.settings);
  }

  override async onWillDisappear(ev: WillDisappearEvent<ActionSettings>): Promise<void> {
    this._unsubs.get(ev.action.id)?.();
    this._unsubs.delete(ev.action.id);
    this._settings.delete(ev.action.id);
    this._lastSeen.delete(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ActionSettings>): Promise<void> {
    if (!connected) { await ev.action.showAlert(); return; }
    const cam = resolveFromSettings(ev.payload.settings);
    if (!cam || cam.connection !== "connected" || !cam.canGrabStill) {
      await ev.action.showAlert();
      return;
    }
    sendCameraCommand(ev.payload.settings, { press: "still" });
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ActionSettings>): void {
    if (!ev.action.isKey()) return;
    const keyAction = ev.action;
    this._settings.set(keyAction.id, ev.payload.settings);
    void this._refresh(keyAction, ev.payload.settings);
  }

  private async _refresh(a: KeyAction<ActionSettings>, s: ActionSettings): Promise<void> {
    const cam = resolveFromSettings(s);
    const canStill = cam?.connection === "connected" && cam.canGrabStill;
    // Show result feedback when lastStill changed
    const newResult = cam?.lastStill;
    const prevResult = this._lastSeen.get(a.id);
    if (newResult !== prevResult) {
      this._lastSeen.set(a.id, newResult);
      if (newResult !== undefined) {
        if (newResult.saved) {
          await a.setTitle("Grab\nStill\nSaved");
          setTimeout(() => { void a.setTitle(canStill ? "Grab\nStill" : "Grab\nStill\n—"); }, 2000);
        } else {
          await a.showAlert();
          await a.setTitle("Grab\nStill\n—");
          setTimeout(() => { void a.setTitle("Grab\nStill"); }, 2000);
        }
        return;
      }
    }
    await a.setTitle(canStill ? "Grab\nStill" : "Grab\nStill\n—");
  }
}

// ─── Registration ─────────────────────────────────────────────────────────────

streamDeck.actions.registerAction(new RecAction());
streamDeck.actions.registerAction(new ISOUpAction());
streamDeck.actions.registerAction(new ISODownAction());
streamDeck.actions.registerAction(new ShutterUpAction());
streamDeck.actions.registerAction(new ShutterDownAction());
streamDeck.actions.registerAction(new IrisUpAction());
streamDeck.actions.registerAction(new IrisDownAction());
streamDeck.actions.registerAction(new KelvinUpAction());
streamDeck.actions.registerAction(new KelvinDownAction());
streamDeck.actions.registerAction(new WBCycleAction());
streamDeck.actions.registerAction(new LUTAction());
streamDeck.actions.registerAction(new FalseColorAction());
streamDeck.actions.registerAction(new FrameRateCycleAction());
streamDeck.actions.registerAction(new ShowPageAction());
streamDeck.actions.registerAction(new LinkToggleAction());
streamDeck.actions.registerAction(new ISODialAction());
streamDeck.actions.registerAction(new ShutterDialAction());
streamDeck.actions.registerAction(new KelvinDialAction());
streamDeck.actions.registerAction(new TintDialAction());
streamDeck.actions.registerAction(new IrisDialAction());
streamDeck.actions.registerAction(new NDDialAction());
streamDeck.actions.registerAction(new CleanFeedAction());
streamDeck.actions.registerAction(new StatusTextAction());
streamDeck.actions.registerAction(new ZebraAction());
streamDeck.actions.registerAction(new FocusAssistAction());
streamDeck.actions.registerAction(new FrameGuidesAction());
streamDeck.actions.registerAction(new HDMIInfoAction());
streamDeck.actions.registerAction(new GridLinesAction());
streamDeck.actions.registerAction(new NDUpAction());
streamDeck.actions.registerAction(new NDDownAction());
streamDeck.actions.registerAction(new TintUpAction());
streamDeck.actions.registerAction(new TintDownAction());
streamDeck.actions.registerAction(new AnyControlAction());
streamDeck.actions.registerAction(new PlaybackKeyAction());
streamDeck.actions.registerAction(new LockAction());
streamDeck.actions.registerAction(new TCDurationAction());
streamDeck.actions.registerAction(new FocusAction());
streamDeck.actions.registerAction(new ZoomAction());
streamDeck.actions.registerAction(new AssignableAction());
streamDeck.actions.registerAction(new AutofocusAction());
streamDeck.actions.registerAction(new GrabStillAction());

// ─── Entry point ──────────────────────────────────────────────────────────────

// Connects once the settings name an app: with the defaults and no token there's nothing to connect to yet.
void streamDeck.settings.getGlobalSettings<GlobalSettings & JsonObject>().then((s) => {
  applyGlobalSettings(s);
});

streamDeck.connect();
