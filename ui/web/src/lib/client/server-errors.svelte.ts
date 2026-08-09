import type { MessageContext } from './connection.svelte';
import type { CommandKind } from './pending';
import type { ServerErrorCode, ServerMessage } from '../protocol/types';

export type ServerErrorCategory = 'retryable' | 'protocol' | 'run_state' | 'internal';

export type ServerErrorNotice = {
  code: ServerErrorCode;
  guidance: string;
  retryable: boolean;
  category: ServerErrorCategory;
  command: CommandKind | null;
  trace: Extract<ServerMessage, { type: 'server.error' }>;
};

export const SERVER_ERROR_GUIDANCE = {
  invalid_json: {
    guidance: 'The server rejected malformed JSON. Reconnect before sending another command.',
    category: 'protocol',
  },
  invalid_envelope: {
    guidance: 'A command envelope did not match protocol v1. Reconnect before retrying.',
    category: 'protocol',
  },
  unsupported_version: {
    guidance: 'This client and server do not support the same protocol version.',
    category: 'protocol',
  },
  unknown_type: {
    guidance: 'The server did not recognize the protocol-v1 command type.',
    category: 'protocol',
  },
  invalid_request_id: {
    guidance: 'The server rejected command correlation. Reconnect before retrying.',
    category: 'protocol',
  },
  invalid_payload: {
    guidance: 'Server policy rejected the submitted fields. Review workspace and model.',
    category: 'protocol',
  },
  token_limit_exceeded: {
    guidance: 'This message would exceed the 272,000-token application context limit.',
    category: 'protocol',
  },
  run_busy: {
    guidance: 'The server already has an active run. Wait for it to settle before trying again.',
    category: 'retryable',
  },
  run_not_found: {
    guidance: 'The server no longer retains this process-lifetime run.',
    category: 'run_state',
  },
  invalid_cursor: {
    guidance: 'Run history could not resume from the retained cursor.',
    category: 'run_state',
  },
  subscription_limit: {
    guidance: 'This connection cannot subscribe to another run.',
    category: 'run_state',
  },
  runtime_unavailable: {
    guidance: 'The local server received the command but did not admit a run. Draft retained.',
    category: 'retryable',
  },
  internal_error: {
    guidance: 'The local API reported an internal failure. Reconnect before retrying.',
    category: 'internal',
  },
} as const satisfies Record<ServerErrorCode, { guidance: string; category: ServerErrorCategory }>;

export function createServerErrorNotices() {
  let notice = $state<ServerErrorNotice | null>(null);

  function handleMessage(message: ServerMessage, context: MessageContext): void {
    if (message.type !== 'server.error') return;
    const fixed = SERVER_ERROR_GUIDANCE[message.payload.code];
    notice = {
      code: message.payload.code,
      guidance: fixed.guidance,
      retryable: message.payload.retryable,
      category: fixed.category,
      command: context.correlation?.kind ?? null,
      trace: message,
    };
  }

  function clear(): void {
    notice = null;
  }

  return {
    get notice() {
      return notice;
    },
    handleMessage,
    clear,
  };
}

export type ServerErrorNotices = ReturnType<typeof createServerErrorNotices>;
