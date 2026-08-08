import { describe, expect, it } from 'vitest';

import { LIMITS } from '../../src/lib/protocol/constants';
import {
  encodeCancelCommand,
  encodePingCommand,
  encodeStartCommand,
  encodeSubscribeCommand,
  type StartCommandInput,
} from '../../src/lib/protocol/encode';
import { REQUEST_ID, RUN_ID } from '../fixtures/messages';

describe('protocol command encoding', () => {
  it('constructs the exact start envelope from allowlisted fields', () => {
    const input = {
      requestId: REQUEST_ID,
      prompt: 'Inspect the project',
      cwd: '/tmp/project',
      model: 'model-a',
      budget: { max_turns: 3, max_provider_retries: 0 },
      provider: 'forbidden-provider',
      capability: true,
      TOKAMAK_API_KEY: 'must-not-cross',
    } as StartCommandInput & Record<string, unknown>;

    const result = encodeStartCommand(input);

    expect(result).toEqual({
      ok: true,
      command: {
        version: 1,
        type: 'run.start',
        request_id: REQUEST_ID,
        payload: {
          prompt: 'Inspect the project',
          cwd: '/tmp/project',
          model: 'model-a',
          budget: { max_turns: 3, max_provider_retries: 0 },
        },
      },
      json: JSON.stringify({
        version: 1,
        type: 'run.start',
        request_id: REQUEST_ID,
        payload: {
          prompt: 'Inspect the project',
          cwd: '/tmp/project',
          model: 'model-a',
          budget: { max_turns: 3, max_provider_retries: 0 },
        },
      }),
    });
    if (result.ok) {
      expect(result.json).not.toMatch(
        /TOKAMAK_API_KEY|capability|credential|authority|"provider":/i,
      );
    }
  });

  it('omits blank optional model and empty Budget', () => {
    const result = encodeStartCommand({
      requestId: REQUEST_ID,
      prompt: 'Inspect',
      cwd: '/tmp/project',
      model: '   ',
      budget: {},
    });

    expect(result.ok).toBe(true);
    if (result.ok)
      expect(result.command.payload).toEqual({ prompt: 'Inspect', cwd: '/tmp/project' });
  });

  it('encodes cancel, subscribe, and ping with exact payloads', () => {
    expect(encodeCancelCommand(REQUEST_ID, RUN_ID)).toMatchObject({
      ok: true,
      command: {
        version: 1,
        type: 'run.cancel',
        request_id: REQUEST_ID,
        payload: { run_id: RUN_ID },
      },
    });
    expect(encodeSubscribeCommand(REQUEST_ID, RUN_ID, 7)).toMatchObject({
      ok: true,
      command: {
        version: 1,
        type: 'run.subscribe',
        request_id: REQUEST_ID,
        payload: { run_id: RUN_ID, after_seq: 7 },
      },
    });
    expect(encodeSubscribeCommand(REQUEST_ID, RUN_ID)).toMatchObject({
      ok: true,
      command: {
        payload: { run_id: RUN_ID },
      },
    });
    expect(encodePingCommand(REQUEST_ID)).toEqual({
      ok: true,
      command: { version: 1, type: 'ping', request_id: REQUEST_ID, payload: {} },
      json: JSON.stringify({ version: 1, type: 'ping', request_id: REQUEST_ID, payload: {} }),
    });
  });

  it.each([
    ['empty', ''],
    ['whitespace', '   '],
    ['control', 'request\n1'],
    ['DEL', 'request\u007f1'],
    ['oversized', 'r'.repeat(LIMITS.requestIdBytes + 1)],
    ['malformed Unicode', '\ud800'],
  ])('rejects %s request IDs', (_name, requestId) => {
    expect(encodePingCommand(requestId)).toMatchObject({
      ok: false,
      error: { code: 'invalid_request_id' },
    });
  });

  it('matches Elixir whitespace semantics for identifiers and prompts', () => {
    expect(encodePingCommand('\u0085')).toMatchObject({
      ok: false,
      error: { code: 'invalid_request_id' },
    });
    expect(encodePingCommand('\ufeff').ok).toBe(true);
    expect(
      encodeStartCommand({ requestId: REQUEST_ID, prompt: '\u0085', cwd: '/tmp/project' }),
    ).toMatchObject({ ok: false, error: { code: 'invalid_prompt' } });
    expect(
      encodeStartCommand({ requestId: REQUEST_ID, prompt: '\ufeff', cwd: '/tmp/project' }).ok,
    ).toBe(true);
  });

  it('measures UTF-8 rather than JavaScript string length', () => {
    const accepted = encodeStartCommand({
      requestId: REQUEST_ID,
      prompt: 'Inspect',
      cwd: '/tmp/project',
      model: 'é'.repeat(128),
    });
    const rejected = encodeStartCommand({
      requestId: REQUEST_ID,
      prompt: 'Inspect',
      cwd: '/tmp/project',
      model: 'é'.repeat(129),
    });

    expect(accepted.ok).toBe(true);
    expect(rejected).toMatchObject({ ok: false, error: { code: 'invalid_model' } });
  });

  it.each(['', '   ', 'a'.repeat(LIMITS.promptBytes + 1), '\ud800'])(
    'rejects invalid prompts without reflecting their content',
    (prompt) => {
      const result = encodeStartCommand({ requestId: REQUEST_ID, prompt, cwd: '/tmp/project' });
      expect(result).toMatchObject({ ok: false, error: { code: 'invalid_prompt' } });
      if (!result.ok && prompt !== '') expect(result.error.message).not.toContain(prompt);
    },
  );

  it.each(['relative/path', '', '/tmp/has\0nul', `/${'a'.repeat(LIMITS.workspacePathBytes)}`])(
    'rejects invalid workspace paths',
    (cwd) => {
      expect(encodeStartCommand({ requestId: REQUEST_ID, prompt: 'Inspect', cwd })).toMatchObject({
        ok: false,
        error: { code: 'invalid_workspace_path' },
      });
    },
  );

  it('accepts every Budget boundary and rejects unknown, zero, unsafe, and excessive fields', () => {
    expect(
      encodeStartCommand({
        requestId: REQUEST_ID,
        prompt: 'Inspect',
        cwd: '/tmp/project',
        budget: {
          max_turns: 100,
          max_tool_calls: 500,
          max_wall_time_ms: 3_600_000,
          provider_inactivity_ms: 900_000,
          tool_inactivity_ms: 900_000,
          max_output_bytes: 524_288,
          max_provider_retries: 0,
        },
      }).ok,
    ).toBe(true);

    for (const budget of [
      { max_turns: 0 },
      { max_provider_retries: -1 },
      { max_provider_retries: 6 },
      { max_turns: Number.MAX_SAFE_INTEGER + 1 },
      { max_turns: 1.5 },
      { capabilities: 1 },
    ]) {
      const result = encodeStartCommand({
        requestId: REQUEST_ID,
        prompt: 'Inspect',
        cwd: '/tmp/project',
        budget: budget as never,
      });
      expect(result).toMatchObject({ ok: false, error: { code: 'invalid_budget' } });
    }
  });

  it('never reads inherited Budget values', () => {
    Object.defineProperty(Object.prototype, 'max_turns', {
      configurable: true,
      value: 100,
    });

    try {
      const result = encodeStartCommand({
        requestId: REQUEST_ID,
        prompt: 'Inspect',
        cwd: '/tmp/project',
        budget: {},
      });
      expect(result).toMatchObject({
        ok: true,
        command: { payload: { prompt: 'Inspect', cwd: '/tmp/project' } },
      });
    } finally {
      delete (Object.prototype as { max_turns?: number }).max_turns;
    }
  });

  it.each([
    'run_short',
    `run_${'A'.repeat(21)}B`,
    `run_${'A'.repeat(23)}`,
    `job_${'A'.repeat(22)}`,
  ])('rejects noncanonical run IDs', (runId) => {
    expect(encodeCancelCommand(REQUEST_ID, runId)).toMatchObject({
      ok: false,
      error: { code: 'invalid_run_id' },
    });
  });

  it.each([-1, 1.5, Number.MAX_SAFE_INTEGER + 1])('rejects invalid replay cursors', (cursor) => {
    expect(encodeSubscribeCommand(REQUEST_ID, RUN_ID, cursor)).toMatchObject({
      ok: false,
      error: { code: 'invalid_cursor' },
    });
  });
});
