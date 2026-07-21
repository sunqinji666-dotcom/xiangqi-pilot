#!/usr/bin/env node
import crypto from 'node:crypto';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const [fen, confidence = '1'] = process.argv.slice(2);
if (!fen) {
  process.stderr.write(
    'Usage: submit-ai-recognized-position.mjs <fen> [confidence]\n'
  );
  process.exit(64);
}

const socketPath = path.join(
  os.homedir(), 'Library/Application Support/XiangqiPilot/ai-bridge.sock'
);
const client = net.createConnection(socketPath);
let buffered = '';

client.on('connect', () => {
  client.write(`${JSON.stringify({
    version: 1,
    id: crypto.randomUUID(),
    type: 'aiRecognizedPosition',
    sentAtUnixMilliseconds: Date.now(),
    payload: {
      fen,
      confidence: Number(confidence)
    }
  })}\n`);
});

client.on('data', chunk => {
  buffered += chunk.toString('utf8');
  let newline;
  while ((newline = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, newline);
    buffered = buffered.slice(newline + 1);
    if (!line) continue;
    process.stdout.write(`${line}\n`);
    try {
      if (JSON.parse(line).type === 'acknowledgement') client.end();
    } catch { /* the bridge only sends JSON; keep the raw diagnostic if not */ }
  }
});

client.on('error', error => {
  process.stderr.write(`Bridge unavailable: ${error.message}\n`);
  process.exitCode = 2;
});
