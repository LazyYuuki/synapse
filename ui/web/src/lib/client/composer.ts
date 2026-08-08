import { BUDGET_LIMITS, HARD_CLIENT_MAX_OUTPUT_BYTES, LIMITS } from '../protocol/constants';
import type { StartCommandInput } from '../protocol/encode';
import type { Budget } from '../protocol/types';
import { hasNonBlankContent, isBoundedString, isIdentifier } from '../protocol/validation';

export type BudgetDraft = Record<keyof Budget, string>;

export type ComposerDraft = {
  prompt: string;
  cwd: string;
  model: string;
  budget: BudgetDraft;
};

export type ComposerErrorCode =
  'invalid_prompt' | 'invalid_workspace_path' | 'invalid_model' | 'invalid_budget';

export type ComposerError = {
  code: ComposerErrorCode;
  field: 'prompt' | 'cwd' | 'model' | keyof Budget;
  message: string;
};

export type ComposerValidation =
  { ok: true; input: Omit<StartCommandInput, 'requestId'> } | { ok: false; error: ComposerError };

const messages = {
  invalid_prompt: 'Enter a prompt within the 262,144-byte protocol limit.',
  invalid_workspace_path: 'Enter an absolute POSIX workspace path within 4,096 bytes.',
  invalid_model: 'Use a blank model or a printable model name within 256 bytes.',
  invalid_budget: 'Use a whole number inside the displayed protocol range.',
} as const satisfies Record<ComposerErrorCode, string>;

export const BUDGET_FIELDS = Object.keys(BUDGET_LIMITS) as (keyof Budget)[];

export function emptyBudgetDraft(): BudgetDraft {
  return {
    max_turns: '',
    max_tool_calls: '',
    max_wall_time_ms: '',
    provider_inactivity_ms: '',
    tool_inactivity_ms: '',
    max_output_bytes: '',
    max_provider_retries: '',
  };
}

export function validateComposerDraft(
  draft: ComposerDraft,
  maxOutputBytes = HARD_CLIENT_MAX_OUTPUT_BYTES,
): ComposerValidation {
  if (!isBoundedString(draft.prompt, LIMITS.promptBytes) || !hasNonBlankContent(draft.prompt)) {
    return failure('invalid_prompt', 'prompt');
  }
  if (
    !isBoundedString(draft.cwd, LIMITS.workspacePathBytes) ||
    !hasNonBlankContent(draft.cwd) ||
    !draft.cwd.startsWith('/') ||
    draft.cwd.includes('\0')
  ) {
    return failure('invalid_workspace_path', 'cwd');
  }

  let model: string | undefined;
  if (hasNonBlankContent(draft.model)) {
    if (!isIdentifier(draft.model, LIMITS.modelBytes)) return failure('invalid_model', 'model');
    model = draft.model;
  }

  const budget: Partial<Budget> = {};
  for (const field of BUDGET_FIELDS) {
    const raw = draft.budget[field];
    if (raw.trim() === '') continue;
    if (!/^(?:0|[1-9]\d*)$/.test(raw)) return failure('invalid_budget', field);
    const value = Number(raw);
    const limits =
      field === 'max_output_bytes'
        ? {
            min: BUDGET_LIMITS.max_output_bytes.min,
            max: Math.min(maxOutputBytes, HARD_CLIENT_MAX_OUTPUT_BYTES),
          }
        : BUDGET_LIMITS[field];
    if (!Number.isSafeInteger(value) || value < limits.min || value > limits.max) {
      return failure('invalid_budget', field);
    }
    budget[field] = value;
  }

  const input: Omit<StartCommandInput, 'requestId'> = { prompt: draft.prompt, cwd: draft.cwd };
  if (model !== undefined) input.model = model;
  if (Object.keys(budget).length > 0) input.budget = budget;
  return { ok: true, input };
}

function failure(code: ComposerErrorCode, field: ComposerError['field']): ComposerValidation {
  return { ok: false, error: { code, field, message: messages[code] } };
}
