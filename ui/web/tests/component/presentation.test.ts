import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

import AssistantOutput from '../../src/lib/components/AssistantOutput.svelte';
import ProtocolInspector from '../../src/lib/components/ProtocolInspector.svelte';
import RunActivity from '../../src/lib/components/RunActivity.svelte';
import TerminalResult from '../../src/lib/components/TerminalResult.svelte';
import { createProtocolTimeline } from '../../src/lib/client/protocol-timeline.svelte';
import type { RunProjectionView, RunState } from '../../src/lib/client/run-types';
import type { Terminal } from '../../src/lib/protocol/types';
import {
  agentTerminal,
  apiTerminal,
  runtimeTerminal,
  successfulTerminal,
} from '../fixtures/messages';

const projection: RunProjectionView = {
  status: 'running',
  model: 'model-a',
  turn: 2,
  text: '',
  activeTool: null,
  providerAttempts: 3,
  toolCalls: 1,
  outputBytes: 24,
};

describe('Phase 6 run presentation', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('renders assistant output as one escaped, whitespace-preserving text value', () => {
    const text = 'first line\n  <script>not markup</script>\n' + 'x'.repeat(240);
    render(AssistantOutput, { text, runId: 'run-1' });

    const output = screen.getByRole('textbox', { name: 'Assistant output' });
    const renderedText = output.querySelector('pre');
    expect(renderedText).toHaveTextContent(text, { normalizeWhitespace: false });
    expect(output.querySelectorAll('pre')).toHaveLength(1);
    expect(output.querySelector('script')).toBeNull();
  });

  it('preserves earlier reading position and exposes an explicit jump to latest action', async () => {
    const view = render(AssistantOutput, { text: 'initial output', runId: 'run-1' });
    const output = screen.getByRole('textbox', { name: 'Assistant output' });
    await tick();
    Object.defineProperties(output, {
      clientHeight: { configurable: true, value: 200 },
      scrollHeight: { configurable: true, value: 1_000 },
    });
    output.scrollTop = 100;
    await fireEvent.scroll(output);
    expect(screen.getByRole('button', { name: 'Jump to latest' })).toBeInTheDocument();

    await view.rerender({ text: 'initial output\nnew output', runId: 'run-1' });
    await tick();
    expect(output.scrollTop).toBe(100);

    await fireEvent.click(screen.getByRole('button', { name: 'Jump to latest' }));
    expect(output.scrollTop).toBe(1_000);
  });

  it('auto-follows near the bottom, resets for a new run, and supports output keys', async () => {
    const view = render(AssistantOutput, { text: 'initial output', runId: 'run-1' });
    const output = screen.getByRole('textbox', { name: 'Assistant output' });
    await tick();
    Object.defineProperties(output, {
      clientHeight: { configurable: true, value: 200 },
      scrollHeight: { configurable: true, value: 1_000 },
    });

    output.scrollTop = 770;
    await fireEvent.scroll(output);
    await view.rerender({ text: 'initial output\ncontinued', runId: 'run-1' });
    await tick();
    expect(output.scrollTop).toBe(1_000);

    await fireEvent.keyDown(output, { key: 'Home' });
    expect(output.scrollTop).toBe(0);
    await view.rerender({ text: 'new run output', runId: 'run-2' });
    await tick();
    expect(output.scrollTop).toBe(1_000);
    await fireEvent.keyDown(output, { key: 'PageUp' });
    expect(output.scrollTop).toBe(840);
    await fireEvent.keyDown(output, { key: 'End' });
    expect(output.scrollTop).toBe(1_000);
  });

  it('shows active and completed Tool metadata without inventing arguments or output', () => {
    const state = runState({
      activeTool: {
        turn: 2,
        operation_id: 'operation-2',
        call_id: 'call-2',
        name: 'read',
        ordinal: 1,
      },
    });
    state.activity = [
      { seq: 1, type: 'tool.started', turn: 2, name: 'read', ordinal: 1 },
      {
        seq: 2,
        type: 'tool.completed',
        turn: 2,
        name: 'read',
        ordinal: 1,
        status: 'ok',
        metadata: { tool: 'read', outcome: 'completed' },
      },
    ];
    render(RunActivity, { state });

    const active = screen.getByRole('region', { name: 'Active Tool' });
    expect(within(active).getByText('read')).toBeInTheDocument();
    expect(within(active).getByText('Active')).toBeInTheDocument();
    expect(screen.getByText(/status/)).toHaveTextContent('status ok');
    expect(screen.getByText(/outcome completed/)).toBeInTheDocument();
    expect(document.body).not.toHaveTextContent('arguments:');
    expect(document.body).not.toHaveTextContent('command output:');
  });

  it.each([
    ['successful Result', successfulTerminal, 'Completed'],
    ['Agent failure', agentTerminal, 'Provider failure'],
    ['Runtime loss', runtimeTerminal, 'Runtime lost'],
    ['API interruption', apiTerminal, 'API settlement failure'],
  ] as const)('renders a source-aware %s terminal', (_name, terminal, heading) => {
    render(TerminalResult, { terminal: terminal as Terminal, projection });

    expect(screen.getByRole('heading', { name: heading })).toBeInTheDocument();
    expect(screen.getByRole('region', { name: heading })).toBeInTheDocument();
    if (terminal.status === 'completed') {
      expect(screen.queryByText('Complete')).not.toBeInTheDocument();
      expect(screen.getByText(/Result text is shown/)).toBeInTheDocument();
      expect(screen.getByText('Provider retries')).toBeInTheDocument();
    }
  });

  it('labels runtime loss as settlement-unproven and all other terminals as confirmed', () => {
    const runtimeView = render(TerminalResult, {
      terminal: runtimeTerminal as Terminal,
      projection,
    });
    expect(screen.getByText(/final cleanup settlement was not observed/)).toBeInTheDocument();
    runtimeView.unmount();

    render(TerminalResult, { terminal: apiTerminal as Terminal, projection });
    expect(screen.getByText(/cleanup and terminal settlement were confirmed/)).toBeInTheDocument();
  });

  it('labels an Agent cancellation distinctly', () => {
    const cancelled: Terminal = {
      run_id: 'run-1',
      seq: 4,
      status: 'interrupted',
      result: null,
      error: {
        source: 'agent',
        kind: 'cancelled',
        reason: 'run_cancelled',
        message: 'Run was cancelled',
        turn: 1,
        operation_id: null,
        details: {},
      },
    };
    render(TerminalResult, { terminal: cancelled, projection });
    expect(screen.getByRole('heading', { name: 'Cancelled' })).toBeInTheDocument();
    expect(screen.getByText('run_cancelled')).toBeInTheDocument();
  });

  it('updates owner-loss wording after authoritative terminal settlement', async () => {
    const state = runState();
    state.activity = [{ seq: 1, type: 'run.owner_lost' }];
    const view = render(RunActivity, { state });
    expect(screen.getByText(/settlement remain unproven/)).toBeInTheDocument();

    state.terminal = apiTerminal as Terminal;
    await view.rerender({ state });
    expect(screen.getByText(/before authoritative terminal settlement/)).toBeInTheDocument();
    expect(screen.queryByText(/settlement remain unproven/)).not.toBeInTheDocument();
  });

  it('copies and clears only structured sanitized protocol diagnostics', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('navigator', { clipboard: { writeText } });
    const timeline = createProtocolTimeline();
    timeline.recordOutbound({
      version: 1,
      type: 'run.start',
      request_id: 'request-1',
      payload: { prompt: 'private prompt', cwd: '/private/workspace', model: 'model-a' },
    });
    render(ProtocolInspector, { timeline });

    await fireEvent.click(screen.getByText('Protocol inspector'));
    expect(screen.getByText(/Copied diagnostics may disclose/)).toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Copy diagnostics' }));
    const copied = writeText.mock.calls[0][0] as string;
    expect(copied).toContain('"marker": "command"');
    expect(copied).not.toContain('private prompt');
    expect(copied).not.toContain('/private/workspace');
    expect(screen.getByText('Sanitized diagnostics copied.')).toBeInTheDocument();

    await fireEvent.click(screen.getByRole('button', { name: 'Clear diagnostics' }));
    expect(
      screen.getByText('No commands or validated server messages retained.'),
    ).toBeInTheDocument();
    expect(timeline.entries).toHaveLength(0);
  });

  it('keeps malicious model, Tool, output, and terminal values inert', () => {
    const sentinel = '</script><img src=x onerror=alert(1)><style>body{display:none}</style>';
    const state = runState({
      model: sentinel,
      text: sentinel,
      activeTool: {
        turn: 2,
        operation_id: `javascript:${sentinel}`,
        call_id: sentinel,
        name: sentinel,
        ordinal: 1,
      },
    });
    state.activity = [{ seq: 1, type: 'run.started', model: sentinel }];
    render(AssistantOutput, { text: sentinel, runId: 'run-1' });
    render(RunActivity, { state });
    render(TerminalResult, {
      projection: state.projection,
      terminal: {
        run_id: 'run-1',
        seq: 2,
        status: 'failed',
        result: null,
        error: {
          source: 'agent',
          kind: 'provider',
          reason: 'provider_failed',
          message: sentinel,
          turn: 2,
          operation_id: `javascript:${sentinel}`,
          details: { provider_kind: sentinel },
        },
      },
    });

    expect(document.body).toHaveTextContent(sentinel);
    expect(document.querySelectorAll('script, img, style, a, iframe')).toHaveLength(0);
    expect(
      Array.from(document.querySelectorAll('*')).some((element) =>
        Array.from(element.attributes).some(
          (attribute) =>
            attribute.name.startsWith('on') || attribute.value.startsWith('javascript:'),
        ),
      ),
    ).toBe(false);
  });
});

function runState(overrides: Partial<RunProjectionView> = {}): RunState {
  return {
    runId: 'run-1',
    projection: { ...projection, ...overrides },
    terminal: null,
    cancelAcknowledged: false,
    lastAppliedSeq: 2,
    activity: [],
    activityBytes: 0,
    historyReset: false,
    knowledge: {
      runStarted: true,
      openTurn: true,
      providerOperationId: 'operation-2',
      providerOperationKnown: true,
      lastToolOrdinal: 1,
      lastTurnOutcome: null,
      lastTurnOutcomeKnown: false,
      ownerLostTool: null,
    },
  };
}
