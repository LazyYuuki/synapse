import { describe, expect, it } from 'vitest';

import {
  createProtocolTimeline,
  serializeProtocolEntries,
} from '../../src/lib/client/protocol-timeline.svelte';
import { appendBounded } from '../../src/lib/client/timeline';
import type { StartCommand } from '../../src/lib/protocol/types';

describe('bounded diagnostic timelines', () => {
  it('evicts oldest entries by count and encoded bytes', () => {
    let timeline = { entries: [] as { value: string }[], bytes: 0 };
    timeline = appendBounded(timeline, { value: 'a' }, 2, 30);
    timeline = appendBounded(timeline, { value: 'bb' }, 2, 30);
    timeline = appendBounded(timeline, { value: 'ccc' }, 2, 30);
    expect(timeline.entries).toEqual([{ value: 'ccc' }]);
    expect(timeline.bytes).toBe(
      new TextEncoder().encode(JSON.stringify(timeline.entries)).byteLength,
    );

    const unchanged = appendBounded(timeline, { value: 'x'.repeat(100) }, 2, 30);
    expect(unchanged).toBe(timeline);
  });

  it('stores only sanitized protocol summaries, never start content', () => {
    const timeline = createProtocolTimeline();
    const command: StartCommand = {
      version: 1,
      type: 'run.start',
      request_id: 'start-1',
      payload: { prompt: 'secret prompt', cwd: '/secret/path', model: 'model-a' },
    };
    timeline.recordOutbound(command);

    const serialized = JSON.stringify(timeline.entries);
    expect(serialized).not.toContain('secret prompt');
    expect(serialized).not.toContain('/secret/path');
    expect(timeline.entries[0]).toMatchObject({
      id: 1,
      direction: 'outbound',
      type: 'run.start',
      requestId: 'start-1',
      runId: null,
      seq: null,
      detail: null,
      role: 'command',
      marker: 'command',
      display: {
        type: 'run.start',
        payload: {
          prompt: { omitted: true, utf8_bytes: 13 },
          cwd: { omitted: true, utf8_bytes: 12 },
          model: 'model-a',
        },
      },
    });
  });

  it('redacts the server launch path from hello diagnostics', () => {
    const timeline = createProtocolTimeline();
    timeline.recordInbound({
      version: 1,
      type: 'server.hello',
      request_id: null,
      payload: {
        protocol: 1,
        replay: 'memory',
        max_active_runs: 1,
        cwd: '/private/server/launch',
        max_output_bytes: 524_288,
      },
    });

    const serialized = serializeProtocolEntries(timeline.entries);
    expect(serialized).not.toContain('/private/server/launch');
    expect(timeline.entries[0]).toMatchObject({
      display: { payload: { cwd: { omitted: true, utf8_bytes: 22 } } },
    });
  });

  it('serializes validated values while omitting output and Agent error details', () => {
    const timeline = createProtocolTimeline();
    timeline.recordInbound({
      version: 1,
      type: 'run.event',
      request_id: null,
      payload: {
        run_id: 'run-1',
        seq: 1,
        event: {
          type: 'text.delta',
          turn: 1,
          operation_id: 'operation-1',
          item_id: 'item-1',
          content_index: 0,
          delta: 'private assistant output',
        },
      },
    });
    timeline.recordInbound({
      version: 1,
      type: 'run.terminal',
      request_id: null,
      payload: {
        run_id: 'run-1',
        seq: 2,
        status: 'failed',
        result: null,
        error: {
          source: 'agent',
          kind: 'provider',
          reason: 'provider_failed',
          message: 'Provider request failed',
          turn: 1,
          operation_id: 'operation-1',
          details: { secret: 'private error detail' },
        },
      },
    });

    const serialized = serializeProtocolEntries(timeline.entries);
    expect(serialized).not.toContain('private assistant output');
    expect(serialized).not.toContain('private error detail');
    expect(serialized).toContain('"marker": "event"');
    expect(serialized).toContain('"marker": "terminal"');
    expect(serialized).toContain('"utf8_bytes": 24');
    expect(serialized).toContain('"keys"');
  });

  it('distinguishes replay, snapshot, reset, response, and asynchronous roles', () => {
    const timeline = createProtocolTimeline();
    timeline.recordInbound({
      version: 1,
      type: 'run.snapshot',
      request_id: 'subscribe-1',
      payload: {
        mode: 'replay',
        reset: false,
        run_id: 'run-1',
        first_available_seq: 1,
        last_seq: 0,
        projection: null,
        terminal: null,
      },
    });
    timeline.recordInbound({
      version: 1,
      type: 'run.snapshot',
      request_id: null,
      payload: {
        mode: 'snapshot',
        reset: false,
        run_id: 'run-1',
        first_available_seq: 1,
        last_seq: 3,
        projection: projection(),
        terminal: null,
      },
    });
    timeline.recordInbound({
      version: 1,
      type: 'run.snapshot',
      request_id: null,
      payload: {
        mode: 'snapshot',
        reset: true,
        run_id: 'run-1',
        first_available_seq: 4,
        last_seq: 4,
        projection: projection(),
        terminal: null,
      },
    });

    expect(timeline.entries.map(({ role, marker }) => ({ role, marker }))).toEqual([
      { role: 'command_response', marker: 'replay' },
      { role: 'asynchronous', marker: 'snapshot' },
      { role: 'asynchronous', marker: 'reset' },
    ]);
  });

  it('caps protocol summaries without retaining raw envelopes', () => {
    const timeline = createProtocolTimeline();
    for (let index = 0; index < 501; index += 1) {
      timeline.recordOutbound({
        version: 1,
        type: 'ping',
        request_id: `ping-${index}`,
        payload: {},
      });
    }
    expect(timeline.entries).toHaveLength(500);
    expect(timeline.entries[0].requestId).toBe('ping-1');
    expect(timeline.entries.at(-1)?.requestId).toBe('ping-500');
  });

  it('does not expose the mutable protocol timeline owner', () => {
    const timeline = createProtocolTimeline();
    timeline.recordOutbound({ version: 1, type: 'ping', request_id: 'ping-1', payload: {} });
    timeline.entries.push({
      direction: 'inbound',
      type: 'pong',
      requestId: 'forged',
      runId: null,
      seq: null,
      detail: null,
      id: 2,
      role: 'command_response',
      marker: 'response',
      display: {},
    });
    expect(timeline.entries).toHaveLength(1);
    expect(timeline.entries[0].requestId).toBe('ping-1');
  });
});

function projection() {
  return {
    status: 'running' as const,
    model: 'model-a',
    turn: 1,
    text: 'private snapshot output',
    active_tool: null,
    provider_attempts: 1,
    tool_calls: 0,
    output_bytes: 23,
  };
}
