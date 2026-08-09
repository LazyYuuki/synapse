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
      conversation: [
        { role: 'user', content: 'Earlier question' },
        { role: 'assistant', content: 'Earlier answer' },
      ],
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
          conversation: [
            { role: 'user', content: 'Earlier question' },
            { role: 'assistant', content: 'Earlier answer' },
          ],
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
          conversation: [
            { role: 'user', content: 'Earlier question' },
            { role: 'assistant', content: 'Earlier answer' },
          ],
        },
      }),
    });
    if (result.ok) {
      expect(result.json).not.toMatch(
        /TOKAMAK_API_KEY|capability|credential|authority|"provider":/i,
      );
    }
  });

  it('omits a blank optional model', () => {
    const result = encodeStartCommand({
      requestId: REQUEST_ID,
      prompt: 'Inspect',
      cwd: '/tmp/project',
      model: '   ',
    });

    expect(result.ok).toBe(true);
    if (result.ok)
      expect(result.command.payload).toEqual({ prompt: 'Inspect', cwd: '/tmp/project' });
  });

  it('accepts exactly 16 complete conversation pairs at the aggregate UTF-8 boundary', () => {
    const conversation = Array.from({ length: LIMITS.conversationMessages }, (_, index) => ({
      role: index % 2 === 0 ? ('user' as const) : ('assistant' as const),
      content: 'é'.repeat(LIMITS.conversationBytes / 2 / LIMITS.conversationMessages),
    }));

    const result = encodeStartCommand({
      requestId: REQUEST_ID,
      prompt: 'Continue',
      cwd: '/tmp/project',
      conversation,
    });

    expect(
      conversation.reduce(
        (bytes, message) => bytes + new TextEncoder().encode(message.content).byteLength,
        0,
      ),
    ).toBe(LIMITS.conversationBytes);
    expect(result).toMatchObject({ ok: true, command: { payload: { conversation } } });
  });

  it.each([
    ['an incomplete pair', [{ role: 'user', content: 'question' }]],
    [
      'wrong alternation',
      [
        { role: 'assistant', content: 'answer' },
        { role: 'user', content: 'question' },
      ],
    ],
    [
      'more than 32 messages',
      Array.from({ length: LIMITS.conversationMessages + 2 }, (_, index) => ({
        role: index % 2 === 0 ? 'user' : 'assistant',
        content: 'x',
      })),
    ],
    [
      'aggregate content over the byte limit',
      [
        { role: 'user', content: 'é'.repeat(LIMITS.conversationBytes / 2) },
        { role: 'assistant', content: 'x' },
      ],
    ],
    [
      'an extra message key',
      [
        { role: 'user', content: 'question', name: 'forbidden' },
        { role: 'assistant', content: 'answer' },
      ],
    ],
    [
      'malformed Unicode content',
      [
        { role: 'user', content: '\ud800' },
        { role: 'assistant', content: 'answer' },
      ],
    ],
    [
      'blank content',
      [
        { role: 'user', content: '\u0085' },
        { role: 'assistant', content: 'answer' },
      ],
    ],
    ['a non-array value', { role: 'user', content: 'question' }],
  ])('rejects conversation with %s', (_label, conversation) => {
    expect(
      encodeStartCommand({
        requestId: REQUEST_ID,
        prompt: 'Continue',
        cwd: '/tmp/project',
        conversation: conversation as never,
      }),
    ).toMatchObject({ ok: false, error: { code: 'invalid_conversation' } });
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
