import { describe, expect, it } from 'vitest';

import {
  createServerErrorNotices,
  SERVER_ERROR_GUIDANCE,
} from '../../src/lib/client/server-errors.svelte';
import { SERVER_ERROR_SPECS } from '../../src/lib/protocol/constants';
import type { MessageContext } from '../../src/lib/client/connection.svelte';
import type { ServerErrorCode, ServerErrorMessage } from '../../src/lib/protocol/types';

describe('fixed server error guidance', () => {
  it.each(Object.keys(SERVER_ERROR_SPECS) as ServerErrorCode[])(
    'maps %s and retains the exact validated error envelope',
    (code) => {
      const controller = createServerErrorNotices();
      const spec = SERVER_ERROR_SPECS[code];
      const requestId = spec.requestId === 'null' ? null : 'request-1';
      const message: ServerErrorMessage = {
        version: 1,
        type: 'server.error',
        request_id: requestId,
        payload: { code, message: spec.message, retryable: spec.retryable },
      };
      controller.handleMessage(message, context(requestId));

      expect(controller.notice).toMatchObject({
        code,
        guidance: SERVER_ERROR_GUIDANCE[code].guidance,
        retryable: spec.retryable,
      });
      expect(controller.notice?.trace).toEqual(message);
    },
  );

  it('records the correlated command kind and clears explicitly', () => {
    const controller = createServerErrorNotices();
    controller.handleMessage(
      {
        version: 1,
        type: 'server.error',
        request_id: 'request-1',
        payload: { code: 'run_busy', message: 'A run is already active', retryable: true },
      },
      context('request-1'),
    );
    expect(controller.notice?.command).toBe('start');
    controller.clear();
    expect(controller.notice).toBeNull();
  });
});

function context(requestId: string | null): MessageContext {
  return {
    generation: 1,
    maxOutputBytes: 524_288,
    correlation:
      requestId === null
        ? null
        : {
            requestId,
            kind: 'start',
            expected: 'run.accepted',
            generation: 1,
            runId: null,
            delayed: false,
          },
  };
}
