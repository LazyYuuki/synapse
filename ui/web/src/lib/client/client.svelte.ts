import {
  createBrowserConnectionController,
  type ConnectionCallbacks,
  type ConnectionController,
  type SendCommandResult,
} from './connection.svelte';
import { createProtocolTimeline } from './protocol-timeline.svelte';
import {
  browserRunStorage,
  createRunController,
  type RunControllerDependencies,
} from './run.svelte';
import { createServerErrorNotices } from './server-errors.svelte';
import type { StartCommandInput } from '../protocol/encode';

export type ClientControllerOptions = {
  createConnection(callbacks: ConnectionCallbacks): ConnectionController;
  run: Omit<RunControllerDependencies, 'transport'>;
};

export function createClientControllers(options: ClientControllerOptions) {
  const protocol = createProtocolTimeline();
  const errors = createServerErrorNotices();
  const connectionRef: { current: ConnectionController | null } = { current: null };
  const run = createRunController({
    ...options.run,
    transport: {
      subscribe(runId, afterSeq) {
        return (
          connectionRef.current?.subscribe(runId, afterSeq) ?? {
            ok: false,
            error: { code: 'not_ready', message: 'Connection is not ready for commands.' },
          }
        );
      },
      failProtocol() {
        connectionRef.current?.failProtocol();
      },
    },
  });

  const connection = options.createConnection({
    onReady(hello, generation) {
      safely(() => protocol.recordInbound(hello));
      run.handleReady(generation, hello.payload.max_output_bytes);
    },
    onMessage(message, context) {
      safely(() => protocol.recordInbound(message));
      safely(() => errors.handleMessage(message, context));
      run.handleMessage(message, context);
    },
    onCommandSent(command, generation) {
      safely(() => protocol.recordOutbound(command));
      run.handleCommandSent(command, generation);
    },
    onGenerationEnd(generation, pending) {
      run.handleGenerationEnd(generation, pending);
    },
  });
  connectionRef.current = connection;

  function startRun(input: Omit<StartCommandInput, 'requestId'>): SendCommandResult {
    if (!canStartRun())
      return actionFailure('run_active', 'A current or restored run blocks start.');
    errors.clear();
    return connection.startRun(input);
  }

  function cancelRun(): SendCommandResult {
    const current = run.current;
    if (!current || current.terminal || current.cancelAcknowledged || !connection.canCancel) {
      return actionFailure('cancel_unavailable', 'Cancellation is not available for this run.');
    }
    errors.clear();
    return connection.cancelRun(current.runId);
  }

  function canStartRun(): boolean {
    return connection.canStart && run.current === null && run.restoredRunId === null;
  }

  return {
    connection,
    run,
    protocol,
    errors,
    get canStartRun() {
      return canStartRun();
    },
    get canCancelRun() {
      const current = run.current;
      return (
        current !== null &&
        current.terminal === null &&
        !current.cancelAcknowledged &&
        connection.canCancel
      );
    },
    get canClearRun() {
      return run.canClear;
    },
    startRun,
    cancelRun,
    clearRun() {
      errors.clear();
      const cleared = run.clear();
      if (cleared && connection.lifecycle === 'ready') connection.connect(connection.apiUrl);
      return cleared;
    },
    destroy() {
      connection.destroy();
    },
  };
}

export type ClientControllers = ReturnType<typeof createClientControllers>;
export type ClientControllerFactory = () => ClientControllers;

export function createBrowserClientControllers(): ClientControllers {
  return createClientControllers({
    createConnection: createBrowserConnectionController,
    run: {
      storage: browserRunStorage(),
      setTimeout(callback, delayMs) {
        return window.setTimeout(callback, delayMs);
      },
      clearTimeout(handle) {
        window.clearTimeout(handle as number);
      },
    },
  });
}

function actionFailure(code: string, message: string): SendCommandResult {
  return { ok: false, error: { code, message } };
}

function safely(callback: () => void): void {
  try {
    callback();
  } catch {
    // Diagnostics and presentation notices cannot alter authoritative run handling.
  }
}
