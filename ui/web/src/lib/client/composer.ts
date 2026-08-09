import { LIMITS } from '../protocol/constants';
import type { StartCommandInput } from '../protocol/encode';
import { hasNonBlankContent, isBoundedString, isIdentifier } from '../protocol/validation';

export type ComposerDraft = {
  prompt: string;
  cwd: string;
  model: string;
};

export type ComposerErrorCode = 'invalid_prompt' | 'invalid_workspace_path' | 'invalid_model';

export type ComposerError = {
  code: ComposerErrorCode;
  field: 'prompt' | 'cwd' | 'model';
  message: string;
};

export type ComposerValidation =
  { ok: true; input: Omit<StartCommandInput, 'requestId'> } | { ok: false; error: ComposerError };

const messages = {
  invalid_prompt: 'Enter a prompt within the 262,144-byte protocol limit.',
  invalid_workspace_path: 'Enter an absolute POSIX workspace path within 4,096 bytes.',
  invalid_model: 'Use a blank model or a printable model name within 256 bytes.',
} as const satisfies Record<ComposerErrorCode, string>;

export function validateComposerDraft(draft: ComposerDraft): ComposerValidation {
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

  const input: Omit<StartCommandInput, 'requestId'> = { prompt: draft.prompt, cwd: draft.cwd };
  if (model !== undefined) input.model = model;
  return { ok: true, input };
}

function failure(code: ComposerErrorCode, field: ComposerError['field']): ComposerValidation {
  return { ok: false, error: { code, field, message: messages[code] } };
}
