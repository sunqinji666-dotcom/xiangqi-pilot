import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { receiptEnvelopeFromInput } from './bridge-watch.mjs';

const scriptPath = fileURLToPath(new URL('./bridge-watch.mjs', import.meta.url));

function waitFor(predicate, timeoutMilliseconds = 3_000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMilliseconds;
    const timer = setInterval(() => {
      if (predicate()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() >= deadline) {
        clearInterval(timer);
        reject(new Error('Timed out waiting for bridge event'));
      }
    }, 10);
  });
}

function appendLines(stream, destination) {
  let buffer = '';
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line) destination.push(line);
    }
  });
}

async function stopChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([
    once(child, 'exit'),
    new Promise(resolve => setTimeout(resolve, 1_000))
  ]);
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
}

test('action receipt is bound to an observed request and cannot add coordinates', () => {
  const request = {
    version: 1,
    id: 'requested-move-1',
    type: 'actionRequested',
    payload: {
      sessionID: 'session-1',
      fen: 'rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w',
      moveUCCI: 'h2e2',
      frameSequence: 18,
      sourceX: 1,
      sourceY: 2
    }
  };
  const envelope = receiptEnvelopeFromInput({
    receiptFor: 'requested-move-1',
    status: 'completed',
    detail: 'external operator visually confirmed the move',
    sourceX: 999
  }, new Map([[request.id, request]]));

  assert.equal(envelope.type, 'actionReceipt');
  assert.equal(envelope.payload.correlationID, request.id);
  assert.equal(envelope.payload.moveUCCI, 'h2e2');
  assert.equal(envelope.payload.frameSequence, 18);
  assert.equal('sourceX' in envelope.payload, false);
  assert.throws(
    () => receiptEnvelopeFromInput(
      { receiptFor: 'requested-move-1', status: 'clicked' },
      new Map([[request.id, request]])
    ),
    /Receipt status must be one of/
  );
});

test('watcher sends hello and heartbeats, exposes requests, and only emits an explicit receipt', async t => {
  const temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'xiangqi-bridge-watch-'));
  const socketPath = path.join(temporaryDirectory, 'ai-bridge.sock');
  const receivedByServer = [];
  const stdoutLines = [];
  const stderrLines = [];
  let serverSocket;
  let serverBuffer = '';

  const server = net.createServer(socket => {
    serverSocket = socket;
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      serverBuffer += chunk;
      let newline;
      while ((newline = serverBuffer.indexOf('\n')) >= 0) {
        const line = serverBuffer.slice(0, newline);
        serverBuffer = serverBuffer.slice(newline + 1);
        if (line) receivedByServer.push(JSON.parse(line));
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socketPath, resolve);
  });

  const child = spawn(process.execPath, [
    scriptPath,
    '--socket', socketPath,
    '--heartbeat-ms', '1000',
    '--no-reconnect'
  ], { stdio: ['pipe', 'pipe', 'pipe'] });
  appendLines(child.stdout, stdoutLines);
  appendLines(child.stderr, stderrLines);

  t.after(async () => {
    await stopChild(child);
    await new Promise(resolve => server.close(resolve));
    await fs.rm(temporaryDirectory, { recursive: true, force: true });
  });

  await waitFor(() => receivedByServer.some(message => message.type === 'hello'));
  await waitFor(() => receivedByServer.some(message => message.type === 'requestSnapshot'));

  const actionRequested = {
    version: 1,
    id: 'action-42',
    type: 'actionRequested',
    sentAtUnixMilliseconds: Date.now(),
    payload: {
      sessionID: 'game-42',
      fen: 'rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w',
      moveUCCI: 'h2e2',
      frameSequence: 42
    }
  };
  serverSocket.write(`${JSON.stringify(actionRequested)}\n`);
  await waitFor(() => stdoutLines.some(line => JSON.parse(line).id === 'action-42'));
  await waitFor(() => stderrLines.some(line => line.includes('no click was performed')));

  child.stdin.write(`${JSON.stringify({
    receiptFor: 'action-42',
    status: 'completed',
    detail: 'external operator confirmed result'
  })}\n`);
  await waitFor(() => receivedByServer.some(message => message.type === 'actionReceipt'));

  const receipt = receivedByServer.find(message => message.type === 'actionReceipt');
  assert.deepEqual(receipt.payload, {
    correlationID: 'action-42',
    status: 'completed',
    detail: 'external operator confirmed result',
    sessionID: 'game-42',
    fen: actionRequested.payload.fen,
    moveUCCI: 'h2e2',
    frameSequence: 42
  });
  assert.equal(receivedByServer.some(message => message.type === 'requestExecution'), false);
});
