/** Allowlisted protocol-v1 command construction.
 * @see ../../../../../docs/plan/PLAN-API.md
 */

import { BUDGET_LIMITS, LIMITS, PROTOCOL_VERSION } from './constants';
import type {
  Budget,
  CancelCommand,
  ClientCommand,
  PingCommand,
  StartCommand,
  SubscribeCommand,
} from './types';
import {
  hasNonBlankContent,
  isBoundedString,
  isIdentifier,
  isPlainObject,
  isRunId,
  utf8ByteLength,
} from './validation';

export type EncodeErrorCode =
  | 'invalid_request_id'
  | 'invalid_prompt'
  | 'invalid_workspace_path'
  | 'invalid_model'
  | 'invalid_budget'
  | 'invalid_run_id'
  | 'invalid_cursor'
  | 'message_too_large';

export type EncodeError = {
  code: EncodeErrorCode;
  message: string;
};

export type EncodeResult<TCommand extends ClientCommand> =
  { ok: true; command: TCommand; json: string } | { ok: false; error: EncodeError };

export type StartCommandInput = {
  requestId: string;
  prompt: string;
  cwd: string;
  model?: string;
  budget?: Partial<Budget>;
};

const messages = {
  invalid_request_id: 'Request ID must be a bounded printable identifier.',
  invalid_prompt: 'Prompt must contain text and fit the protocol byte limit.',
  invalid_workspace_path: 'Workspace path must be an absolute bounded path without NUL.',
  invalid_model: 'Model must be blank or a bounded printable identifier.',
  invalid_budget: 'Budget must contain only safe integers within protocol limits.',
  invalid_run_id: 'Run ID must use the canonical protocol-v1 format.',
  invalid_cursor: 'Run cursor must be a non-negative safe integer.',
  message_too_large: 'Command exceeds the protocol byte limit.',
} as const satisfies Record<EncodeErrorCode, string>;

export function encodeStartCommand(input: StartCommandInput): EncodeResult<StartCommand> {
  if (!isIdentifier(input.requestId, LIMITS.requestIdBytes)) {
    return failure('invalid_request_id');
  }

  if (!isBoundedString(input.prompt, LIMITS.promptBytes) || !hasNonBlankContent(input.prompt)) {
    return failure('invalid_prompt');
  }

  if (
    !isBoundedString(input.cwd, LIMITS.workspacePathBytes) ||
    !hasNonBlankContent(input.cwd) ||
    !input.cwd.startsWith('/') ||
    input.cwd.includes('\0')
  ) {
    return failure('invalid_workspace_path');
  }

  let model: string | undefined;
  if (input.model !== undefined) {
    if (typeof input.model !== 'string') return failure('invalid_model');
    if (hasNonBlankContent(input.model)) {
      if (!isIdentifier(input.model, LIMITS.modelBytes)) return failure('invalid_model');
      model = input.model;
    }
  }

  const budget = encodeBudget(input.budget);
  if (budget === false) return failure('invalid_budget');

  const payload: StartCommand['payload'] = {
    prompt: input.prompt,
    cwd: input.cwd,
  };
  if (model !== undefined) payload.model = model;
  if (budget !== undefined) payload.budget = budget;

  const command: StartCommand = {
    version: PROTOCOL_VERSION,
    type: 'run.start',
    request_id: input.requestId,
    payload,
  };

  return finalize(command);
}

export function encodeCancelCommand(requestId: string, runId: string): EncodeResult<CancelCommand> {
  if (!isIdentifier(requestId, LIMITS.requestIdBytes)) return failure('invalid_request_id');
  if (!isRunId(runId)) return failure('invalid_run_id');

  return finalize({
    version: PROTOCOL_VERSION,
    type: 'run.cancel',
    request_id: requestId,
    payload: { run_id: runId },
  });
}

export function encodeSubscribeCommand(
  requestId: string,
  runId: string,
  afterSeq?: number,
): EncodeResult<SubscribeCommand> {
  if (!isIdentifier(requestId, LIMITS.requestIdBytes)) return failure('invalid_request_id');
  if (!isRunId(runId)) return failure('invalid_run_id');
  if (afterSeq !== undefined && (!Number.isSafeInteger(afterSeq) || afterSeq < 0)) {
    return failure('invalid_cursor');
  }

  const payload: SubscribeCommand['payload'] = { run_id: runId };
  if (afterSeq !== undefined) payload.after_seq = afterSeq;

  return finalize({
    version: PROTOCOL_VERSION,
    type: 'run.subscribe',
    request_id: requestId,
    payload,
  });
}

export function encodePingCommand(requestId: string): EncodeResult<PingCommand> {
  if (!isIdentifier(requestId, LIMITS.requestIdBytes)) return failure('invalid_request_id');

  return finalize({
    version: PROTOCOL_VERSION,
    type: 'ping',
    request_id: requestId,
    payload: {},
  });
}

function encodeBudget(input: Partial<Budget> | undefined): Partial<Budget> | undefined | false {
  if (input === undefined) return undefined;
  if (!isPlainObject(input)) return false;

  const allowed = Object.keys(BUDGET_LIMITS) as (keyof Budget)[];
  if (Object.keys(input).some((field) => !allowed.includes(field as keyof Budget))) return false;

  const budget: Partial<Budget> = {};
  for (const field of allowed) {
    if (!Object.hasOwn(input, field)) continue;
    const value = input[field];
    if (value === undefined) continue;

    const limits = BUDGET_LIMITS[field];
    if (!Number.isSafeInteger(value) || value < limits.min || value > limits.max) return false;
    budget[field] = value;
  }

  return Object.keys(budget).length === 0 ? undefined : budget;
}

function finalize<TCommand extends ClientCommand>(command: TCommand): EncodeResult<TCommand> {
  const json = JSON.stringify(command);
  if (utf8ByteLength(json) > LIMITS.clientMessageBytes) return failure('message_too_large');
  return { ok: true, command, json };
}

function failure<TCommand extends ClientCommand>(code: EncodeErrorCode): EncodeResult<TCommand> {
  return { ok: false, error: { code, message: messages[code] } };
}
