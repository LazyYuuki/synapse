import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

import App from '../../src/App.svelte';
import { RUN_ID, serverEnvelope } from '../fixtures/messages';
import { createTestClient } from '../support/test-client';

const hello = helloWith('/synthetic/server-launch');

describe('interactive operator console', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('renders stable regions and creates no socket before explicit connect', async () => {
    const context = createTestClient();
    render(App, { createClient: () => context.client });
    await tick();

    expect(screen.getByRole('banner')).toBeInTheDocument();
    expect(screen.getByRole('main')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Run setup' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Current run' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Activity' })).toBeInTheDocument();
    expect(screen.getByRole('contentinfo')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Connect' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Start run' })).toBeDisabled();
    expect(context.factory.sockets).toHaveLength(0);
  });

  it('connects explicitly, displays hello, and sends one exact minimal start', async () => {
    const context = await readyApp();
    expect(screen.getByText('Protocol 1 / replay memory')).toBeInTheDocument();
    expect(screen.getByLabelText(/Workspace path/)).toHaveValue('/synthetic/server-launch');

    await fillComposer('/tmp/project', 'Inspect the project');
    expect(screen.getByRole('button', { name: 'Start run' })).toBeEnabled();
    await fireEvent.click(screen.getByRole('button', { name: 'Start run' }));

    const command = JSON.parse(context.socket.sent.at(-1) ?? '{}');
    expect(command).toEqual({
      version: 1,
      type: 'run.start',
      request_id: 'request-1',
      payload: { prompt: 'Inspect the project', cwd: '/tmp/project' },
    });
    expect(screen.getByRole('button', { name: 'Starting...' })).toBeDisabled();
    expect(screen.getByLabelText(/Prompt/)).toBeDisabled();
    expect(screen.getByLabelText(/Workspace path/)).toBeDisabled();
  });

  it('updates only an automatically owned Workspace path across ready generations', async () => {
    const context = await readyApp();
    const workspace = screen.getByLabelText(/Workspace path/);
    expect(workspace).toHaveValue('/synthetic/server-launch');

    await reconnectWith(context, '/synthetic/second-launch');
    expect(workspace).toHaveValue('/synthetic/second-launch');

    await fireEvent.input(workspace, { target: { value: '/manual/workspace' } });
    await reconnectWith(context, '/synthetic/third-launch');
    expect(workspace).toHaveValue('/manual/workspace');

    await fireEvent.input(workspace, { target: { value: '' } });
    expect(workspace).toHaveValue('');
    await reconnectWith(context, '/synthetic/fourth-launch');
    expect(workspace).toHaveValue('/synthetic/fourth-launch');

    expect(JSON.stringify([...context.storage.values.entries()])).not.toContain('workspace');
    expect(JSON.stringify([...context.storage.values.entries()])).not.toContain('synthetic');
  });

  it('preserves the complete draft after a retryable pre-admission error', async () => {
    const context = await readyApp();
    await fillComposer('/tmp/project', 'Keep this prompt', 'model-a');
    await fireEvent.click(screen.getByRole('button', { name: 'Start run' }));

    context.socket.emitMessage(
      serverEnvelope('server.error', 'request-1', {
        code: 'runtime_unavailable',
        message: 'Runtime is unavailable',
        retryable: true,
      }),
    );
    await tick();

    expect(screen.getByText(/Admission can be retried/)).toBeInTheDocument();
    expect(screen.getByLabelText(/Workspace path/)).toHaveValue('/tmp/project');
    expect(screen.getByLabelText(/Prompt/)).toHaveValue('Keep this prompt');
    expect(screen.getByLabelText(/Model/)).toHaveValue('model-a');
  });

  it('installs only the accepted run ID, clears only prompt, and focuses Current run', async () => {
    const context = await readyApp();
    await fillComposer('/tmp/project', 'Clear after acceptance', 'model-a');
    await fireEvent.click(screen.getByRole('button', { name: 'Start run' }));
    context.socket.emitMessage(
      serverEnvelope('run.accepted', 'request-1', { run_id: RUN_ID, status: 'starting' }),
    );
    await tick();
    await tick();

    expect(screen.getByLabelText(/Prompt/)).toHaveValue('');
    expect(screen.getByLabelText(/Workspace path/)).toHaveValue('/tmp/project');
    expect(screen.getByLabelText(/Model/)).toHaveValue('model-a');
    expect(screen.getAllByText(RUN_ID)).not.toHaveLength(0);
    expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Current run' }));
    expect(context.storage.values.get('synapse.run_id')).toBe(RUN_ID);
    expect(screen.getByRole('button', { name: 'Start run' })).toBeDisabled();
  });

  it('rejects invalid URL and path before constructing or sending', async () => {
    const invalid = createTestClient();
    const invalidView = render(App, { createClient: () => invalid.client });
    await tick();
    await fireEvent.input(screen.getByLabelText('API socket'), {
      target: { value: 'ws://remote.example:4848/v1/socket' },
    });
    await fireEvent.click(screen.getByRole('button', { name: 'Connect' }));
    expect(invalid.factory.sockets).toHaveLength(0);
    expect(screen.getByText(/explicit local protocol-v1/)).toBeInTheDocument();
    invalidView.unmount();

    const context = await readyApp();
    await fillComposer('relative/path', 'Inspect');
    await fireEvent.click(screen.getByRole('button', { name: 'Start run' }));
    expect(context.socket.sent).toHaveLength(0);
    expect(screen.getAllByText(/absolute POSIX workspace path/)).not.toHaveLength(0);
    expect(document.activeElement).toBe(screen.getByLabelText(/Workspace path/));
  });

  it('sends cancellation once, keeps disconnect separate, and enables New run only after terminal', async () => {
    const context = await acceptedApp();
    const cancelButton = screen.getByRole('button', { name: 'Cancel run' });
    expect(cancelButton).toHaveAttribute('aria-describedby', 'cancel-reason');
    expect(screen.getByText(/terminal message confirms settlement/)).toBeInTheDocument();
    await fireEvent.click(cancelButton);
    expect(JSON.parse(context.socket.sent.at(-1) ?? '{}')).toMatchObject({
      type: 'run.cancel',
      payload: { run_id: RUN_ID },
    });
    expect(screen.getByRole('button', { name: 'Requesting cancellation...' })).toBeDisabled();
    expect(
      context.socket.sent.filter((frame) => JSON.parse(frame).type === 'run.cancel'),
    ).toHaveLength(1);

    context.socket.emitMessage(
      serverEnvelope('run.cancel_requested', 'request-2', {
        run_id: RUN_ID,
        status: 'cancel_requested',
      }),
    );
    await tick();
    expect(screen.getByRole('button', { name: 'Cancellation requested' })).toBeDisabled();
    expect(screen.getByText(/Cancellation acknowledged/)).toBeInTheDocument();
    context.socket.emitMessage(
      serverEnvelope('run.terminal', null, {
        run_id: RUN_ID,
        seq: 1,
        status: 'interrupted',
        result: null,
        error: {
          source: 'runtime',
          reason: 'runtime_lost',
          message: 'Runtime coordinator was lost',
        },
      }),
    );
    await tick();
    expect(screen.getByRole('heading', { name: 'Runtime lost' })).toBeInTheDocument();
    expect(screen.getByRole('alert')).toHaveTextContent('Run interrupted: Runtime lost');
    expect(document.querySelector('.run-state')).toHaveAttribute('aria-live', 'off');
    expect(document.querySelector('.run-sync-state')).toHaveAttribute('aria-live', 'off');
    expect(screen.getAllByText(/final cleanup settlement was not observed/i)).not.toHaveLength(0);
    expect(screen.getByRole('button', { name: 'New run' })).toBeEnabled();
    await fireEvent.click(screen.getByRole('button', { name: 'New run' }));
    expect(screen.getAllByText('Not assigned')).not.toHaveLength(0);
    await tick();
    expect(document.activeElement).toBe(screen.getByLabelText(/Workspace path/));
    expect(context.socket.closes).toEqual([1_000]);
    const replacement = context.factory.sockets[1];
    replacement.emitOpen();
    replacement.emitMessage(hello);
    await tick();
    expect(screen.getByRole('button', { name: 'Start run' })).toBeEnabled();

    await fireEvent.click(screen.getByRole('button', { name: 'Disconnect' }));
    expect(
      context.socket.sent.filter((frame) => JSON.parse(frame).type === 'run.cancel'),
    ).toHaveLength(1);
  });

  it('disconnects an active run without cancel and reconnects from its cursor', async () => {
    const context = await acceptedApp();
    await fireEvent.click(screen.getByRole('button', { name: 'Disconnect' }));
    expect(context.socket.sent.map((frame) => JSON.parse(frame).type)).not.toContain('run.cancel');
    expect(screen.getByRole('button', { name: 'Reconnect' })).toBeEnabled();

    await fireEvent.click(screen.getByRole('button', { name: 'Reconnect' }));
    const replacement = context.factory.sockets[1];
    replacement.emitOpen();
    replacement.emitMessage(hello);
    await tick();
    expect(JSON.parse(replacement.sent.at(-1) ?? '{}')).toMatchObject({
      type: 'run.subscribe',
      payload: { run_id: RUN_ID, after_seq: 0 },
    });
  });

  it('exposes sanitized protocol summaries in the inspector', async () => {
    await readyApp();
    await fireEvent.click(screen.getByText('Protocol inspector'));
    expect(screen.getByText('server.hello')).toBeInTheDocument();
    expect(screen.getByText(/#1 inbound/)).toBeInTheDocument();
    expect(screen.getAllByText('handshake')).toHaveLength(2);
  });

  it('presents streamed plain text, Tool activity, counters, and a successful terminal', async () => {
    const context = await acceptedApp();
    const events = [
      { type: 'run.started', model: 'model-a' },
      { type: 'turn.started', turn: 1, operation_id: 'provider-1' },
      {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-1',
        item_id: 'item-1',
        content_index: 0,
        delta: 'Hello\n  <strong>plain text</strong>',
      },
      {
        type: 'tool.started',
        turn: 1,
        operation_id: 'tool-1',
        call_id: 'call-1',
        name: 'read',
        ordinal: 1,
        arguments: { path: 'mix.exs' },
      },
    ];
    for (const [index, event] of events.entries()) {
      context.socket.emitMessage(
        serverEnvelope('run.event', null, { run_id: RUN_ID, seq: index + 1, event }),
      );
      await tick();
    }

    const output = screen.getByRole('textbox', { name: 'Assistant output' });
    expect(output).toHaveTextContent('Hello\n  <strong>plain text</strong>', {
      normalizeWhitespace: false,
    });
    expect(output.querySelector('strong')).toBeNull();
    const activeTool = screen.getByRole('region', { name: 'Active Tool' });
    expect(within(activeTool).getByText(/Tool call \/ read/)).toBeInTheDocument();
    expect(within(activeTool).getByText(/^Active/)).toBeInTheDocument();
    expect(activeTool).toHaveAttribute('open');
    const runningElapsedValue = screen.getByText('Turn elapsed').nextElementSibling;
    expect(runningElapsedValue).toHaveTextContent(/\d+\.\d s running/);

    context.socket.emitMessage(
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 5,
        event: {
          type: 'tool.completed',
          turn: 1,
          operation_id: 'tool-1',
          call_id: 'call-1',
          name: 'read',
          ordinal: 1,
          status: 'ok',
          metadata: { tool: 'read', outcome: 'completed' },
          content: '{"content":"example"}',
        },
      }),
    );
    await tick();
    expect(screen.queryByRole('region', { name: 'Active Tool' })).not.toBeInTheDocument();
    expect(screen.getByText(/Tool call \/ read/).closest('details')).not.toHaveAttribute('open');
    expect(screen.getByText(/Tool result \/ read \/ ok/).closest('details')).not.toHaveAttribute(
      'open',
    );
    context.socket.emitMessage(
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 6,
        event: {
          type: 'turn.completed',
          turn: 1,
          outcome: 'completed',
          provider_attempts: 1,
          tool_calls: 1,
          output_bytes: 35,
        },
      }),
    );
    await tick();
    expect(screen.getByText(/Turn completed/)).toBeInTheDocument();
    const elapsedValue = screen.getByText('Turn elapsed').nextElementSibling;
    expect(elapsedValue).not.toHaveTextContent('--');
    expect(elapsedValue).toHaveTextContent(/\d+\.\d s/);
    output.focus();

    context.socket.emitMessage(
      serverEnvelope('run.terminal', null, {
        run_id: RUN_ID,
        seq: 7,
        status: 'completed',
        result: {
          text: 'Final <b>plain</b>',
          turns: 1,
          tool_calls: 1,
          provider_retries: 0,
          output_bytes: 18,
        },
        error: null,
      }),
    );
    await tick();
    await tick();
    expect(screen.getByRole('heading', { name: 'Completed' })).toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('Run completed');
    expect(document.activeElement).toBe(output);
    expect(screen.getAllByText('Final <b>plain</b>')).toHaveLength(1);
    expect(screen.getByText(/cleanup and terminal settlement were confirmed/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'New run' })).toBeEnabled();
  });

  it('copies the full run ID only after the explicit copy action', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('navigator', { clipboard: { writeText } });
    await acceptedApp();

    expect(writeText).not.toHaveBeenCalled();
    await fireEvent.click(screen.getByRole('button', { name: 'Copy run ID' }));
    expect(writeText).toHaveBeenCalledOnce();
    expect(writeText).toHaveBeenCalledWith(RUN_ID);
    expect(screen.getByText('Run ID copied.')).toBeInTheDocument();
  });

  it.each([320, 1440])('keeps the same landmarks at a %i pixel viewport', async (width) => {
    window.innerWidth = width;
    window.dispatchEvent(new Event('resize'));
    const context = createTestClient();
    render(App, { createClient: () => context.client });
    await tick();

    expect(screen.getByRole('main')).toHaveAttribute('id', 'main-content');
    expect(screen.getByRole('form', { name: 'Run setup' })).toBeInTheDocument();
    expect(screen.getByRole('region', { name: 'Current run' })).toBeInTheDocument();
    expect(screen.getByRole('region', { name: 'Activity' })).toBeInTheDocument();
  });

  it('removes the browser shell without creating transport resources', () => {
    const webSocket = vi.fn();
    vi.stubGlobal('WebSocket', webSocket);
    const removeDocumentListener = vi.spyOn(document, 'removeEventListener');
    const removeWindowListener = vi.spyOn(window, 'removeEventListener');
    const view = render(App);
    view.unmount();

    expect(webSocket).not.toHaveBeenCalled();
    expect(removeDocumentListener).toHaveBeenCalledWith('visibilitychange', expect.any(Function));
    expect(removeWindowListener).toHaveBeenCalledWith('pagehide', expect.any(Function));
    expect(removeWindowListener).toHaveBeenCalledWith('pageshow', expect.any(Function));
  });

  it('keeps an accepted streaming run usable when every storage operation throws', async () => {
    const context = createTestClient();
    context.storage.throwOnRead = true;
    context.storage.throwOnWrite = true;
    context.storage.throwOnRemove = true;
    render(App, { createClient: () => context.client });
    await tick();
    await fireEvent.click(screen.getByRole('button', { name: 'Connect' }));
    const socket = context.factory.sockets[0];
    socket.emitOpen();
    socket.emitMessage(hello);
    await tick();
    await fillComposer('/tmp/project', 'Storage-independent run');
    await fireEvent.click(screen.getByRole('button', { name: 'Start run' }));
    socket.emitMessage(
      serverEnvelope('run.accepted', 'request-1', { run_id: RUN_ID, status: 'starting' }),
    );
    socket.emitMessage(
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 1,
        event: { type: 'run.started', model: 'model-a' },
      }),
    );
    socket.emitMessage(
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 2,
        event: { type: 'turn.started', turn: 1, operation_id: 'provider-1' },
      }),
    );
    socket.emitMessage(
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 3,
        event: {
          type: 'text.delta',
          turn: 1,
          operation_id: 'provider-1',
          item_id: 'item-1',
          content_index: 0,
          delta: 'Still streaming',
        },
      }),
    );
    await tick();
    expect(screen.getByRole('textbox', { name: 'Assistant output' })).toHaveTextContent(
      'Still streaming',
    );
    expect(screen.getByRole('button', { name: 'Cancel run' })).toBeEnabled();
  });

  it('repeatedly mounts and destroys active clients without retained socket listeners', async () => {
    const addDocument = vi.spyOn(document, 'addEventListener');
    const removeDocument = vi.spyOn(document, 'removeEventListener');
    const addWindow = vi.spyOn(window, 'addEventListener');
    const removeWindow = vi.spyOn(window, 'removeEventListener');
    for (let cycle = 0; cycle < 20; cycle += 1) {
      const context = createTestClient();
      const view = render(App, { createClient: () => context.client });
      await tick();
      await fireEvent.click(screen.getByRole('button', { name: 'Connect' }));
      const socket = context.factory.sockets[0];
      socket.emitOpen();
      socket.emitMessage(hello);
      await tick();
      view.unmount();
      expect(socket.closes).toEqual([1_000]);
      for (const event of ['open', 'message', 'close', 'error'] as const) {
        expect(socket.listenerCount(event)).toBe(0);
      }
      expect(context.timers.size).toBe(0);
    }
    expect(addDocument.mock.calls.filter(([event]) => event === 'visibilitychange').length).toBe(
      removeDocument.mock.calls.filter(([event]) => event === 'visibilitychange').length,
    );
    for (const event of ['pagehide', 'pageshow']) {
      expect(addWindow.mock.calls.filter(([type]) => type === event).length).toBe(
        removeWindow.mock.calls.filter(([type]) => type === event).length,
      );
    }
  });
});

async function readyApp() {
  const context = createTestClient();
  render(App, { createClient: () => context.client });
  await tick();
  await fireEvent.click(screen.getByRole('button', { name: 'Connect' }));
  const socket = context.factory.sockets[0];
  socket.emitOpen();
  socket.emitMessage(hello);
  await tick();
  return { ...context, socket };
}

async function acceptedApp() {
  const context = await readyApp();
  await fillComposer('/tmp/project', 'Inspect');
  await fireEvent.click(screen.getByRole('button', { name: 'Start run' }));
  context.socket.emitMessage(
    serverEnvelope('run.accepted', 'request-1', { run_id: RUN_ID, status: 'starting' }),
  );
  await tick();
  return context;
}

async function fillComposer(workspace: string, prompt: string, model = '') {
  await fireEvent.input(screen.getByLabelText(/Workspace path/), { target: { value: workspace } });
  await fireEvent.input(screen.getByLabelText(/Prompt/), { target: { value: prompt } });
  await fireEvent.input(screen.getByLabelText(/Model/), { target: { value: model } });
}

function helloWith(cwd: string, maxOutputBytes = 524_288): string {
  return serverEnvelope('server.hello', null, {
    protocol: 1,
    replay: 'memory',
    max_active_runs: 1,
    cwd,
    max_output_bytes: maxOutputBytes,
  });
}

async function reconnectWith(
  context: ReturnType<typeof createTestClient>,
  cwd: string,
  maxOutputBytes = 524_288,
): Promise<void> {
  await fireEvent.click(screen.getByRole('button', { name: 'Disconnect' }));
  await fireEvent.click(screen.getByRole('button', { name: 'Reconnect' }));
  const replacement = context.factory.sockets.at(-1);
  if (!replacement) throw new Error('Expected replacement socket');
  replacement.emitOpen();
  replacement.emitMessage(helloWith(cwd, maxOutputBytes));
  await tick();
}
