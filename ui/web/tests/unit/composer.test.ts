import { describe, expect, it } from 'vitest';

import { validateComposerDraft, type ComposerDraft } from '../../src/lib/client/composer';

describe('run composer validation', () => {
  it('constructs exact start input and omits a blank model', () => {
    expect(validateComposerDraft(draft())).toEqual({
      ok: true,
      input: { prompt: 'Inspect the project', cwd: '/tmp/project' },
    });
  });

  it('preserves a nonblank model', () => {
    expect(validateComposerDraft({ ...draft(), model: 'model-a' })).toEqual({
      ok: true,
      input: { prompt: 'Inspect the project', cwd: '/tmp/project', model: 'model-a' },
    });
  });

  it.each([
    ['blank prompt', { prompt: ' \n ' }, 'invalid_prompt', 'prompt'],
    ['oversized prompt', { prompt: 'x'.repeat(262_145) }, 'invalid_prompt', 'prompt'],
    ['relative path', { cwd: 'tmp/project' }, 'invalid_workspace_path', 'cwd'],
    ['NUL path', { cwd: '/tmp\0project' }, 'invalid_workspace_path', 'cwd'],
    ['invalid model', { model: 'model\nname' }, 'invalid_model', 'model'],
  ])('rejects %s before command construction', (_label, override, code, field) => {
    expect(validateComposerDraft({ ...draft(), ...override })).toMatchObject({
      ok: false,
      error: { code, field },
    });
  });
});

function draft(): ComposerDraft {
  return {
    prompt: 'Inspect the project',
    cwd: '/tmp/project',
    model: '   ',
  };
}
