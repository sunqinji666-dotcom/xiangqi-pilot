#!/usr/bin/env node
/**
 * A local, read-mostly client for XiangqiPilot's AI collaboration bridge.
 *
 * It deliberately does not import a UI automation library, invoke a shell,
 * or synthesize mouse input.  `actionRequested` is surfaced to stdout for an
 * external operator; the operator must explicitly provide an action receipt
 * through stdin after independently observing the result.
 *
 * stdout: one JSON envelope from the bridge per line (machine-readable).
 * stderr: connection and safety diagnostics for the human operator.
 */

import crypto from 'node:crypto';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const PROTOCOL_VERSION = 1;
const DEFAULT_SOCKET_PATH = path.join(
  os.homedir(), 'Library/Application Support/XiangqiPilot/ai-bridge.sock'
);
const DEFAULT_HEARTBEAT_MS = 5_000;
const DEFAULT_RETRY_MS = 1_000;
const MAX_HEARTBEAT_MS = 60_000;
const MAX_RETRY_MS = 60_000;
const RECEIPT_STATUSES = new Set([
  'completed',
  'failed',
  'skipped',
  'expired',
  'cancelled'
]);

function usage() {
  return `Usage: node scripts/bridge-watch.mjs [options]

Connects to XiangqiPilot's local AI collaboration socket, writes every
incoming JSON message to stdout, and never performs a click.

Options:
  --socket <path>         Unix socket path (default: ${DEFAULT_SOCKET_PATH})
  --heartbeat-ms <ms>     Heartbeat interval, 1000-${MAX_HEARTBEAT_MS} ms
                           (default: ${DEFAULT_HEARTBEAT_MS})
  --retry-ms <ms>         Reconnect interval, 100-${MAX_RETRY_MS} ms
                           (default: ${DEFAULT_RETRY_MS})
  --no-snapshot           Do not request the current board/candidate on connect
  --no-reconnect          Exit after a disconnected socket closes
  -h, --help              Show this help

stdin (one JSON object per line):
  {"receiptFor":"<actionRequested id>","status":"completed","detail":"..."}
  {"type":"actionReceipt","payload":{"correlationID":"<id>","status":"failed","detail":"..."}}

Accepted receipt statuses: completed, failed, skipped, expired, cancelled.
An action receipt is only sent for an actionRequested message observed during
this process.  The listener never infers success and never clicks anything.
`;
}

export function parseOptions(argv) {
  const options = {
    socketPath: DEFAULT_SOCKET_PATH,
    heartbeatMs: DEFAULT_HEARTBEAT_MS,
    retryMs: DEFAULT_RETRY_MS,
    requestSnapshot: true,
    reconnect: true,
    help: false
  };

  const requireValue = (flag, index) => {
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`${flag} requires a value`);
    }
    return value;
  };
  const parseInterval = (flag, value, minimum, maximum) => {
    if (!/^\d+$/.test(value)) {
      throw new Error(`${flag} must be an integer number of milliseconds`);
    }
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
      throw new Error(`${flag} must be between ${minimum} and ${maximum} milliseconds`);
    }
    return parsed;
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    switch (argument) {
      case '--socket':
        options.socketPath = requireValue(argument, index);
        index += 1;
        break;
      case '--heartbeat-ms':
        options.heartbeatMs = parseInterval(
          argument,
          requireValue(argument, index),
          1_000,
          MAX_HEARTBEAT_MS
        );
        index += 1;
        break;
      case '--retry-ms':
        options.retryMs = parseInterval(
          argument,
          requireValue(argument, index),
          100,
          MAX_RETRY_MS
        );
        index += 1;
        break;
      case '--no-snapshot':
        options.requestSnapshot = false;
        break;
      case '--no-reconnect':
        options.reconnect = false;
        break;
      case '-h':
      case '--help':
        options.help = true;
        break;
      default:
        throw new Error(`Unknown option: ${argument}`);
    }
  }
  return options;
}

function newEnvelope(type, payload = {}) {
  return {
    version: PROTOCOL_VERSION,
    id: crypto.randomUUID(),
    type,
    sentAtUnixMilliseconds: Date.now(),
    payload
  };
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined;
}

function optionalString(value) {
  return typeof value === 'string' ? value : undefined;
}

/**
 * Turns the intentionally small stdin receipt dialect into a bridge envelope.
 * The `actionRequested` context is authoritative for position/session fields;
 * stdin cannot inject coordinates or an arbitrary bridge command.
 */
export function receiptEnvelopeFromInput(input, pendingActions) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('Receipt input must be a JSON object');
  }

  const suppliedPayload = input.type === 'actionReceipt'
    ? input.payload
    : input;
  if (!suppliedPayload || typeof suppliedPayload !== 'object' || Array.isArray(suppliedPayload)) {
    throw new Error('actionReceipt payload must be a JSON object');
  }

  const requestedID = nonEmptyString(
    suppliedPayload.correlationID
      ?? suppliedPayload.receiptFor
      ?? suppliedPayload.actionID
  );
  const actionID = requestedID ?? (pendingActions.size === 1
    ? pendingActions.keys().next().value
    : undefined);
  if (!actionID) {
    throw new Error('Receipt needs receiptFor/actionID when there is not exactly one pending action');
  }

  const action = pendingActions.get(actionID);
  if (!action) {
    throw new Error(`No observed actionRequested message has id ${actionID}`);
  }

  const status = nonEmptyString(suppliedPayload.status);
  if (!status || !RECEIPT_STATUSES.has(status)) {
    throw new Error(`Receipt status must be one of: ${[...RECEIPT_STATUSES].join(', ')}`);
  }

  const requestedPayload = action.payload && typeof action.payload === 'object'
    ? action.payload
    : {};
  const detail = optionalString(suppliedPayload.detail);
  if (detail !== undefined && detail.length > 4_096) {
    throw new Error('Receipt detail must not exceed 4096 characters');
  }

  // These values bind a human-verified receipt to the precise request that
  // was surfaced.  Coordinates are deliberately omitted even if a future
  // protocol version puts them on actionRequested.
  const payload = {
    correlationID: actionID,
    status,
    ...(detail === undefined ? {} : { detail }),
    ...(optionalString(requestedPayload.sessionID) === undefined
      ? {}
      : { sessionID: requestedPayload.sessionID }),
    ...(optionalString(requestedPayload.fen) === undefined
      ? {}
      : { fen: requestedPayload.fen }),
    ...(optionalString(requestedPayload.moveUCCI) === undefined
      ? {}
      : { moveUCCI: requestedPayload.moveUCCI }),
    ...(typeof requestedPayload.frameSequence === 'number'
      ? { frameSequence: requestedPayload.frameSequence }
      : {})
  };

  return newEnvelope('actionReceipt', payload);
}

export class BridgeWatcher {
  constructor(options, io = {}) {
    this.options = options;
    this.stdout = io.stdout ?? process.stdout;
    this.stderr = io.stderr ?? process.stderr;
    this.stdin = io.stdin ?? process.stdin;
    this.createConnection = io.createConnection ?? net.createConnection;
    this.schedule = io.schedule ?? setTimeout;
    this.cancelSchedule = io.cancelSchedule ?? clearTimeout;
    this.setInterval = io.setInterval ?? globalThis.setInterval;
    this.clearInterval = io.clearInterval ?? globalThis.clearInterval;
    this.exit = io.exit ?? (code => { process.exitCode = code; });
    this.socket = undefined;
    this.connected = false;
    this.stopping = false;
    this.reconnectTimer = undefined;
    this.heartbeatTimer = undefined;
    this.inboundBuffer = '';
    this.stdinBuffer = '';
    this.outboundQueue = [];
    this.pendingActions = new Map();
  }

  start() {
    this.installStdinHandler();
    this.connect();
  }

  stop() {
    this.stopping = true;
    if (this.reconnectTimer !== undefined) {
      this.cancelSchedule(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    this.stopHeartbeat();
    if (this.socket && !this.socket.destroyed) this.socket.end();
    this.stdin.pause?.();
  }

  connect() {
    if (this.stopping || this.socket) return;

    let client;
    try {
      client = this.createConnection(this.options.socketPath);
    } catch (error) {
      this.reportConnectionError(error);
      this.scheduleReconnect();
      return;
    }
    this.socket = client;
    this.inboundBuffer = '';

    client.on('connect', () => {
      if (this.socket !== client || this.stopping) return;
      this.connected = true;
      this.stderr.write(`Bridge connected: ${this.options.socketPath}\n`);
      this.sendNow(newEnvelope('hello', {
        applicationName: 'XiangqiPilot bridge watcher',
        status: 'observing-only'
      }));
      if (this.options.requestSnapshot) this.sendNow(newEnvelope('requestSnapshot'));
      this.flushOutboundQueue();
      this.startHeartbeat();
    });

    client.on('data', chunk => this.handleSocketData(chunk));
    client.on('error', error => this.reportConnectionError(error));
    client.on('close', () => this.handleSocketClose(client));
  }

  handleSocketData(chunk) {
    this.inboundBuffer += chunk.toString('utf8');
    let newline;
    while ((newline = this.inboundBuffer.indexOf('\n')) >= 0) {
      const line = this.inboundBuffer.slice(0, newline);
      this.inboundBuffer = this.inboundBuffer.slice(newline + 1);
      if (line.length === 0) continue;

      // Keep stdout a pure NDJSON stream so an external operator can pipe it
      // to a controller without parsing diagnostics.  The source bridge only
      // emits JSON, but malformed lines are still faithfully observable.
      this.stdout.write(`${line}\n`);

      let envelope;
      try {
        envelope = JSON.parse(line);
      } catch {
        this.stderr.write('Bridge sent a non-JSON line; passed through unchanged.\n');
        continue;
      }
      this.handleEnvelope(envelope);
    }
  }

  handleEnvelope(envelope) {
    if (!envelope || typeof envelope !== 'object') return;
    if (envelope.type !== 'actionRequested') return;
    if (envelope.version !== PROTOCOL_VERSION || !nonEmptyString(envelope.id)) {
      this.stderr.write('Ignoring malformed actionRequested message.\n');
      return;
    }

    this.pendingActions.set(envelope.id, envelope);
    // Avoid unbounded state when an operator intentionally observes a long
    // game without taking any action.  The most recent actions are the only
    // ones that can plausibly still be current.
    while (this.pendingActions.size > 32) {
      this.pendingActions.delete(this.pendingActions.keys().next().value);
    }
    const move = optionalString(envelope.payload?.moveUCCI) ?? 'unknown move';
    this.stderr.write(
      `actionRequested ${envelope.id} (${move}) observed; no click was performed. ` +
      'After external verification, send an actionReceipt JSON line to stdin.\n'
    );
  }

  installStdinHandler() {
    this.stdin.setEncoding?.('utf8');
    this.stdin.on('data', chunk => {
      this.stdinBuffer += chunk.toString();
      let newline;
      while ((newline = this.stdinBuffer.indexOf('\n')) >= 0) {
        const line = this.stdinBuffer.slice(0, newline).trim();
        this.stdinBuffer = this.stdinBuffer.slice(newline + 1);
        if (line) this.handleReceiptLine(line);
      }
    });
    this.stdin.on('end', () => {
      if (this.stdinBuffer.trim()) this.handleReceiptLine(this.stdinBuffer.trim());
      this.stdinBuffer = '';
    });
  }

  handleReceiptLine(line) {
    let input;
    try {
      input = JSON.parse(line);
    } catch {
      this.stderr.write('Ignoring non-JSON stdin line; expected an actionReceipt object.\n');
      return;
    }
    let envelope;
    try {
      envelope = receiptEnvelopeFromInput(input, this.pendingActions);
    } catch (error) {
      this.stderr.write(`Receipt rejected locally: ${error.message}\n`);
      return;
    }

    this.pendingActions.delete(envelope.payload.correlationID);
    this.sendOrQueue(envelope);
    this.stderr.write(
      `actionReceipt queued for ${envelope.payload.correlationID} (${envelope.payload.status}); ` +
      'the watcher still did not click anything.\n'
    );
  }

  sendOrQueue(envelope) {
    if (!this.connected || !this.socket || this.socket.destroyed) {
      this.outboundQueue.push(envelope);
      return;
    }
    if (!this.sendNow(envelope)) this.outboundQueue.push(envelope);
  }

  sendNow(envelope) {
    if (!this.socket || this.socket.destroyed) return false;
    try {
      this.socket.write(`${JSON.stringify(envelope)}\n`);
      return true;
    } catch (error) {
      this.reportConnectionError(error);
      return false;
    }
  }

  flushOutboundQueue() {
    while (this.outboundQueue.length > 0) {
      const envelope = this.outboundQueue.shift();
      if (!this.sendNow(envelope)) {
        this.outboundQueue.unshift(envelope);
        return;
      }
    }
  }

  startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeatTimer = this.setInterval(() => {
      if (!this.connected || this.stopping) return;
      this.sendNow(newEnvelope('heartbeat', { status: 'observing-only' }));
    }, this.options.heartbeatMs);
  }

  stopHeartbeat() {
    if (this.heartbeatTimer !== undefined) {
      this.clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = undefined;
    }
  }

  handleSocketClose(client) {
    if (this.socket !== client) return;
    this.connected = false;
    this.socket = undefined;
    this.stopHeartbeat();
    if (this.stopping) return;
    this.stderr.write('Bridge disconnected.\n');
    if (this.options.reconnect) {
      this.scheduleReconnect();
    } else {
      this.exit(2);
    }
  }

  scheduleReconnect() {
    if (this.stopping || !this.options.reconnect || this.reconnectTimer !== undefined) return;
    this.reconnectTimer = this.schedule(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, this.options.retryMs);
  }

  reportConnectionError(error) {
    const message = error instanceof Error ? error.message : String(error);
    this.stderr.write(`Bridge unavailable: ${message}\n`);
  }
}

function isMainModule() {
  const entry = process.argv[1];
  return entry !== undefined
    && path.resolve(entry) === path.resolve(fileURLToPath(import.meta.url));
}

if (isMainModule()) {
  let options;
  try {
    options = parseOptions(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${usage()}`);
    process.exitCode = 64;
  }

  if (options?.help) {
    process.stdout.write(usage());
  } else if (options) {
    const watcher = new BridgeWatcher(options);
    const stop = () => watcher.stop();
    process.once('SIGINT', stop);
    process.once('SIGTERM', stop);
    watcher.start();
  }
}
