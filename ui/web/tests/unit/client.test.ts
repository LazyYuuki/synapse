import { describe, expect, it } from 'vitest';

import { RUN_ID, serverEnvelope } from '../fixtures/messages';
import { createTestClient } from '../support/test-client';

const hello = serverEnvelope('server.hello', null, {
  protocol: 1,
  replay: 'memory',
  max_active_runs: 1,
  cwd: '/synthetic/server-launch',
  max_output_bytes: 524_288,
});

describe('composed client controls', () => {
  it('enforces acknowledged cancellation below presentation', () => {
    const { client, socket } = acceptedClient();
    const first = client.cancelRun();
    expect(first.ok).toBe(true);
    socket.emitMessage(
      serverEnvelope('run.cancel_requested', 'request-2', {
        run_id: RUN_ID,
        status: 'cancel_requested',
      }),
    );

    expect(client.canCancelRun).toBe(false);
    expect(client.cancelRun()).toMatchObject({
      ok: false,
      error: { code: 'cancel_unavailable' },
    });
    expect(socket.sent.filter((frame) => JSON.parse(frame).type === 'run.cancel')).toHaveLength(1);
  });

  it('keeps authoritative callbacks alive when diagnostics throw', () => {
    const context = readyClient();
    const start = context.client.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    expect(start.ok).toBe(true);
    context.client.protocol.recordInbound = () => {
      throw new Error('sanitized diagnostic failure');
    };
    context.socket.emitMessage(
      serverEnvelope('run.accepted', 'request-1', { run_id: RUN_ID, status: 'starting' }),
    );
    expect(context.client.run.current?.runId).toBe(RUN_ID);

    context.client.protocol.recordOutbound = () => {
      throw new Error('sanitized diagnostic failure');
    };
    expect(context.client.cancelRun().ok).toBe(true);
    context.socket.emitClose(1_006);
    expect(context.client.run.syncState).toBe('detached');
  });

  it('records causal hello before the subscription it triggers', () => {
    const context = acceptedClient();
    context.client.connection.disconnect();
    context.client.protocol.clear();
    context.client.connection.reconnect();
    const replacement = context.factory.sockets[1];
    replacement.emitOpen();
    replacement.emitMessage(hello);

    expect(context.client.protocol.entries.map((entry) => entry.type)).toEqual([
      'server.hello',
      'run.subscribe',
    ]);
  });
});

function readyClient() {
  const context = createTestClient();
  context.client.connection.connect();
  const socket = context.factory.sockets[0];
  socket.emitOpen();
  socket.emitMessage(hello);
  return { ...context, socket };
}

function acceptedClient() {
  const context = readyClient();
  context.client.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
  context.socket.emitMessage(
    serverEnvelope('run.accepted', 'request-1', { run_id: RUN_ID, status: 'starting' }),
  );
  return context;
}
