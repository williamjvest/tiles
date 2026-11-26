/**
 * Shared Tiles WebSocket connection — used by all actions.
 *
 * One socket per plugin process. Global settings carry host, port and token;
 * every action calls applyGlobalSettings() on first appear and whenever
 * onDidReceiveSettings fires.
 *
 * Auth flow: open → send auth → recv hello → send subscribe → recv snapshot.
 * On close/error: mark everything unknown, schedule reconnect with exponential
 * backoff (1 s → 2 → 4 → … → 30 s).
 *
 * Heartbeat: a link that dies quietly (out of radio range, the app's device
 * asleep) can keep the socket open for minutes before TCP notices, with every
 * key showing what it last knew: a REC tally reading recording when it isn't.
 * The plugin pings every few seconds, and a socket the app has said nothing on
 * for `heartbeat.limitMs` is dropped like any other close.
 *
 * Auth failure: server closes the socket. scheduleReconnect checks authFailed
 * and skips the retry. applyGlobalSettings clears authFailed so a corrected
 * token can reconnect.
 */

import WebSocket from "ws";
import type { Camera, Page, ClientMessage, ServerMessage, ChoiceField, LevelField, RecordField, PlaybackStatus } from "./protocol.js";

export const DEFAULT_HOST  = "127.0.0.1";
export const DEFAULT_PORT  = 51800;

// ─── Live camera state store ──────────────────────────────────────────────────

export interface LiveCamera {
  id: string;
  label: string;
  model: string;
  connection: Camera["connection"];
  fields: Camera["fields"];
  playback?: PlaybackStatus;
  canGrabStill?: boolean;
  lastStill?: { saved: boolean; message?: string };
}

export const cameras = new Map<string, LiveCamera>(); // keyed by camera UUID
export const pages: Page[] = [];
export let appLocked = false;

export function getField<T extends ChoiceField | LevelField | RecordField>(cam: LiveCamera, fieldName: string): T | undefined {
  return cam.fields[fieldName] as T | undefined;
}

// ─── Connection state ─────────────────────────────────────────────────────────

export const heartbeat = { intervalMs: 5_000, limitMs: 12_000 };

export let connected = false;
let ws: WebSocket | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let lastHeard = 0;
let reconnectDelay = 1000;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let authFailed = false;

let currentHost  = DEFAULT_HOST;
let currentPort  = DEFAULT_PORT;
let currentToken = "";

type Listener = () => void;
const onStateChange: Set<Listener> = new Set();
export function onConnectionChange(fn: Listener): () => void {
  onStateChange.add(fn);
  return () => onStateChange.delete(fn);
}

function notifyAll(): void {
  for (const fn of onStateChange) fn();
}

// ─── Public API ───────────────────────────────────────────────────────────────

/** The plugin's global settings, shared by every action and set in the inspector. */
export interface GlobalSettings {
  host?: string;
  port?: number;
  token?: string;
}

export function applyGlobalSettings(s: GlobalSettings): void {
  const host  = s.host  || DEFAULT_HOST;
  const port  = s.port  || DEFAULT_PORT;
  const token = s.token || "";
  if (host !== currentHost || port !== currentPort || token !== currentToken) {
    currentHost  = host;
    currentPort  = port;
    currentToken = token;
    authFailed = false;
    reconnect();
  }
}

export function sendCommand(msg: ClientMessage): void {
  if (ws) sendOn(ws, msg);
}

/** One message on one socket, if it's open: every message the plugin sends goes through here, typed. */
function sendOn(sock: WebSocket, msg: ClientMessage): void {
  if (sock.readyState === WebSocket.OPEN) sock.send(JSON.stringify(msg));
}

/** Tear down the current socket and cancel any pending reconnect. Primarily for test cleanup. */
export function disconnect(): void {
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  stopHeartbeat();
  dropSocket();
  connected = false;
}

/**
 * The current socket gone without a word: its listeners off, then terminated. A socket still connecting emits an error
 * as it's dropped, and with nothing listening that would end the plugin's process.
 */
function dropSocket(): void {
  if (!ws) return;
  ws.removeAllListeners();
  ws.on("error", () => {});
  ws.terminate();
  ws = null;
}

// ─── Connection logic ─────────────────────────────────────────────────────────

function reconnect(): void {
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  stopHeartbeat();
  dropSocket();
  // New settings start the backoff over: a corrected address shouldn't wait out the old one's 30 s.
  reconnectDelay = 1000;
  connected = false;
  cameras.clear();
  pages.length = 0;
  notifyAll();
  connect();
}

function scheduleReconnect(): void {
  if (reconnectTimer || authFailed) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 30_000);
}

export function connect(): void {
  if (reconnectTimer) return;
  const url = `ws://${currentHost}:${currentPort}/`;
  let sock: WebSocket;
  try { sock = new WebSocket(url); }
  catch { scheduleReconnect(); return; }
  ws = sock;

  sock.on("open", () => {
    if (ws !== sock) return;
    reconnectDelay = 1000;
    sendOn(sock, { type: "auth", token: currentToken });
    startHeartbeat(sock);
  });

  sock.on("message", (raw: WebSocket.RawData) => {
    if (ws !== sock) return;
    lastHeard = Date.now();
    try {
      const msg = JSON.parse(raw.toString()) as ServerMessage;
      handleMessage(msg);
    } catch { /* ignore malformed */ }
  });

  sock.on("close", () => {
    if (ws !== sock) return;
    stopHeartbeat();
    ws = null;
    connected = false;
    markAllUnknown();
    notifyAll();
    scheduleReconnect();
  });

  sock.on("error", () => { /* close follows */ });
}

function startHeartbeat(sock: WebSocket): void {
  stopHeartbeat();
  lastHeard = Date.now();
  heartbeatTimer = setInterval(() => {
    if (ws !== sock) { stopHeartbeat(); return; }
    // terminate() emits close, which marks everything unknown and reconnects.
    if (Date.now() - lastHeard > heartbeat.limitMs) { sock.terminate(); return; }
    sendOn(sock, { type: "ping" });
  }, heartbeat.intervalMs);
}

function stopHeartbeat(): void {
  if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
}

function markAllUnknown(): void {
  for (const cam of cameras.values()) {
    cam.connection = "disconnected";
    const rec = cam.fields["record"] as RecordField | undefined;
    if (rec) rec.value = "unknown";
    cam.playback = undefined;
  }
}

function handleMessage(msg: ServerMessage): void {
  switch (msg.type) {
    case "hello": {
      connected = true;
      if (msg.locked !== undefined) appLocked = msg.locked;
      applySnapshot(msg.cameras, msg.pages);
      sendCommand({ type: "subscribe" });
      notifyAll();
      break;
    }
    case "snapshot": {
      if (msg.locked !== undefined) appLocked = msg.locked;
      applySnapshot(msg.cameras, msg.pages);
      notifyAll();
      break;
    }
    case "lock": {
      appLocked = msg.locked;
      notifyAll();
      break;
    }
    case "changes": {
      const cam = cameras.get(msg.cameraID);
      if (!cam) break;
      // The camera's own link: REC and the rest check it before they light.
      if (msg.update.connection !== undefined) cam.connection = msg.update.connection;
      if (msg.update.fields) {
        for (const [field, partial] of Object.entries(msg.update.fields)) {
          const existing = cam.fields[field];
          if (existing) {
            Object.assign(existing, partial);
            // null pending clears it
            if ((partial as unknown as Record<string, unknown>)["pending"] === null) {
              delete (existing as unknown as Record<string, unknown>)["pending"];
            }
          } else {
            cam.fields[field] = partial as Camera["fields"][string];
          }
        }
      }
      if (msg.removed) {
        for (const f of msg.removed) delete cam.fields[f];
      }
      if ("playback" in msg.update) {
        cam.playback = msg.update.playback ?? undefined;
      }
      if ("canGrabStill" in msg.update) {
        cam.canGrabStill = msg.update.canGrabStill ?? undefined;
      }
      if ("lastStill" in msg.update) {
        const ls = msg.update.lastStill;
        cam.lastStill = ls == null ? undefined : ls;
      }
      notifyAll();
      break;
    }
    case "pages": {
      pages.length = 0;
      pages.push(...msg.pages);
      notifyAll();
      break;
    }
    case "cameras": {
      applySnapshot(msg.cameras, undefined);
      notifyAll();
      break;
    }
    case "error": {
      if (msg.code === "auth") {
        authFailed = true;
        connected = false;
        notifyAll();
        // server closes the socket after auth error; scheduleReconnect will skip retry
      }
      break;
    }
  }
}

function applySnapshot(cams: Camera[], pgs?: Page[]): void {
  cameras.clear();
  for (const cam of cams) {
    cameras.set(cam.id, {
      id: cam.id,
      label: cam.label,
      model: cam.model,
      connection: cam.connection,
      fields: cam.fields,
      playback: cam.playback,
      canGrabStill: cam.canGrabStill,
      lastStill: cam.lastStill,
    });
  }
  if (pgs) {
    pages.length = 0;
    pages.push(...pgs);
  }
}
