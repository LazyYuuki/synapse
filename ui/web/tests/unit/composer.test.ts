import { describe, expect, it } from 'vitest';

import {
  BUDGET_FIELDS,
  emptyBudgetDraft,
  validateComposerDraft,
  type ComposerDraft,
} from '../../src/lib/client/composer';
import { BUDGET_LIMITS } from '../../src/lib/protocol/constants';

describe('run composer validation', () => {
  it('constructs exact start input and omits blank model and Budget', () => {
    expect(validateComposerDraft(draft())).toEqual({
      ok: true,
      input: { prompt: 'Inspect the project', cwd: '/tmp/project' },
    });
  });

  it('preserves nonblank model and parses all Budget fields as safe integers', () => {
    const budget = emptyBudgetDraft();
    for (const field of BUDGET_FIELDS) budget[field] = String(BUDGET_LIMITS[field].max);
    const result = validateComposerDraft({ ...draft(), model: 'model-a', budget });
    expect(result).toEqual({
      ok: true,
      input: {
        prompt: 'Inspect the project',
        cwd: '/tmp/project',
        model: 'model-a',
        budget: Object.fromEntries(BUDGET_FIELDS.map((field) => [field, BUDGET_LIMITS[field].max])),
      },
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

  it.each(['1.5', '-1', '1e2', '01', '9007199254740992'])(
    'rejects noncanonical Budget input %s',
    (value) => {
      const candidate = draft();
      candidate.budget.max_turns = value;
      expect(validateComposerDraft(candidate)).toMatchObject({
        ok: false,
        error: { code: 'invalid_budget', field: 'max_turns' },
      });
    },
  );

  it('accepts every Budget minimum and rejects values outside each range', () => {
    for (const field of BUDGET_FIELDS) {
      const atMinimum = draft();
      atMinimum.budget[field] = String(BUDGET_LIMITS[field].min);
      expect(validateComposerDraft(atMinimum).ok).toBe(true);

      const overMaximum = draft();
      overMaximum.budget[field] = String(BUDGET_LIMITS[field].max + 1);
      expect(validateComposerDraft(overMaximum)).toMatchObject({
        ok: false,
        error: { code: 'invalid_budget', field },
      });
    }
  });

  it('applies the validated server output ceiling without rewriting the draft', () => {
    const candidate = draft();
    candidate.budget.max_output_bytes = '64000';
    expect(validateComposerDraft(candidate, 64_000).ok).toBe(true);

    candidate.budget.max_output_bytes = '64001';
    expect(validateComposerDraft(candidate, 64_000)).toMatchObject({
      ok: false,
      error: { code: 'invalid_budget', field: 'max_output_bytes' },
    });
    expect(candidate.budget.max_output_bytes).toBe('64001');
  });
});

function draft(): ComposerDraft {
  return {
    prompt: 'Inspect the project',
    cwd: '/tmp/project',
    model: '   ',
    budget: emptyBudgetDraft(),
  };
}
