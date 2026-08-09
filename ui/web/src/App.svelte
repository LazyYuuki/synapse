<script lang="ts">
  import { onMount, tick, untrack } from 'svelte';

  import {
    createBrowserClientControllers,
    type ClientControllerFactory,
    type ClientControllers,
  } from './lib/client/client.svelte';
  import {
    BUDGET_FIELDS,
    emptyBudgetDraft,
    validateComposerDraft,
    type ComposerError,
  } from './lib/client/composer';
  import type { ConnectionLifecycle } from './lib/client/connection.svelte';
  import type { RunState } from './lib/client/run-types';
  import ChatTimeline from './lib/components/ChatTimeline.svelte';
  import ProtocolInspector from './lib/components/ProtocolInspector.svelte';
  import {
    BUDGET_LIMITS,
    DEFAULT_API_URL,
    HARD_CLIENT_MAX_OUTPUT_BYTES,
  } from './lib/protocol/constants';
  import type { Budget, RunStatus } from './lib/protocol/types';

  let {
    createClient = createBrowserClientControllers,
  }: { createClient?: ClientControllerFactory } = $props();

  let client = $state<ClientControllers | null>(null);
  let apiUrl = $state(DEFAULT_API_URL);
  let cwd = $state('');
  let model = $state('');
  let prompt = $state('');
  let budget = $state(emptyBudgetDraft());
  let composerError = $state<ComposerError | null>(null);
  let actionNotice = $state<string | null>(null);
  let startRequestId = $state<string | null>(null);
  let cancelRequestId = $state<string | null>(null);
  let runHeading: HTMLHeadingElement;
  let runIdCopyNotice = $state<string | null>(null);
  let current = $derived(currentRun(client));
  let runs = $derived(client ? client.run.runs : []);
  let hasConversationHistory = $derived(
    runs.some((run) => run.start !== null && run.terminal?.status === 'completed'),
  );
  let handledReadyGeneration = 0;
  let workspaceManuallyEdited = false;
  let serverMaxOutputBytes = $state(HARD_CLIENT_MAX_OUTPUT_BYTES);

  const budgetLabels: Record<keyof Budget, string> = {
    max_turns: 'Maximum turns',
    max_tool_calls: 'Maximum Tool calls',
    max_wall_time_ms: 'Wall time',
    provider_inactivity_ms: 'Provider inactivity',
    tool_inactivity_ms: 'Tool inactivity',
    max_output_bytes: 'Output bytes',
    max_provider_retries: 'Provider retries',
  };

  onMount(() => {
    client = createClient();
    apiUrl = client.connection.apiUrl;
    return () => client?.destroy();
  });

  $effect(() => {
    if (startRequestId && current) {
      startRequestId = null;
      prompt = '';
      composerError = null;
      actionNotice = 'Run accepted. Prompt cleared; workspace, model, and Budget remain in memory.';
      void focusCurrentRun();
    } else if (startRequestId && client?.errors.notice?.command === 'start') {
      startRequestId = null;
    }

    if (cancelRequestId && client?.errors.notice?.command === 'cancel') {
      cancelRequestId = null;
      actionNotice = null;
    } else if (cancelRequestId && current?.terminal) {
      cancelRequestId = null;
      actionNotice = null;
    } else if (cancelRequestId && current?.cancelAcknowledged) {
      cancelRequestId = null;
      actionNotice = 'Cancellation acknowledged. Waiting for terminal settlement.';
    } else if (
      cancelRequestId &&
      client &&
      !client.connection.pendingCancel &&
      client.connection.lifecycle !== 'ready'
    ) {
      cancelRequestId = null;
      actionNotice = 'Cancellation outcome is unknown. Reconnect for an authoritative snapshot.';
    }
  });

  $effect(() => {
    const hello = client?.connection.hello;
    const generation = client?.connection.generation ?? 0;
    if (!hello || generation === handledReadyGeneration) return;
    handledReadyGeneration = generation;
    serverMaxOutputBytes = hello.payload.max_output_bytes;
    if (composerError?.field === 'max_output_bytes') composerError = null;

    const currentCwd = untrack(() => cwd);
    if (currentCwd === '' || !workspaceManuallyEdited) {
      cwd = hello.payload.cwd;
      workspaceManuallyEdited = false;
    }
  });

  function connect(event: SubmitEvent): void {
    event.preventDefault();
    if (!client) return;
    client.errors.clear();
    actionNotice = null;
    const result = client.connection.connect(apiUrl);
    if (result.ok) apiUrl = client.connection.apiUrl;
    else if (!client.connection.notice) actionNotice = result.error.message;
  }

  function reconnect(): void {
    if (!client) return;
    client.errors.clear();
    actionNotice = null;
    const result = client.connection.reconnect();
    if (!result.ok) actionNotice = result.error.message;
  }

  function disconnect(): void {
    if (!client) return;
    client.connection.disconnect();
    actionNotice = 'Transport disconnected. Any accepted run continues on the server.';
  }

  function handleWorkspaceInput(): void {
    workspaceManuallyEdited = true;
    clearComposerError('cwd');
  }

  function start(event: SubmitEvent): void {
    event.preventDefault();
    if (!client) return;
    composerError = null;
    actionNotice = null;
    const validated = validateComposerDraft(
      { prompt, cwd, model, budget },
      client.connection.hello?.payload.max_output_bytes ?? serverMaxOutputBytes,
    );
    if (!validated.ok) {
      composerError = validated.error;
      void focusComposerError(validated.error.field);
      return;
    }

    const result = client.startRun(validated.input);
    if (result.ok) startRequestId = result.requestId;
    else actionNotice = result.error.message;
  }

  function cancel(): void {
    if (!client) return;
    const result = client.cancelRun();
    if (result.ok) cancelRequestId = result.requestId;
    actionNotice = result.ok
      ? 'Cancellation command sent. Waiting for the server intent acknowledgement.'
      : result.error.message;
  }

  function clearRun(): void {
    if (!client) return;
    if (client.clearRun()) {
      startRequestId = null;
      cancelRequestId = null;
      runIdCopyNotice = null;
      actionNotice = 'Current run cleared locally. Composer settings were retained.';
      void focusWorkspace();
    }
  }

  async function focusCurrentRun(): Promise<void> {
    await tick();
    focusUnlessTyping(runHeading);
  }

  async function focusWorkspace(): Promise<void> {
    await tick();
    document.getElementById('workspace')?.focus();
  }

  function focusUnlessTyping(target: HTMLElement | undefined): void {
    const active = document.activeElement;
    if (
      active instanceof HTMLInputElement ||
      active instanceof HTMLTextAreaElement ||
      active instanceof HTMLSelectElement ||
      active?.getAttribute('contenteditable') === 'true'
    ) {
      return;
    }
    target?.focus();
  }

  function connectionLabel(lifecycle: ConnectionLifecycle | undefined): string {
    if (!lifecycle) return 'Client initializing';
    return {
      idle: 'Disconnected',
      connecting: 'Connecting',
      awaiting_hello: 'Awaiting server hello',
      ready: 'Protocol ready',
      reconnecting: 'Reconnecting',
      protocol_fault: 'Protocol fault',
      unavailable: 'Unavailable',
      manually_disconnected: 'Disconnected manually',
    }[lifecycle];
  }

  function startReason(): string {
    if (!client) return 'Client controls are initializing.';
    if (client.connection.startAmbiguous)
      return 'A previous start outcome is unknown; it cannot be resent.';
    if (client.run.current && !client.run.current.terminal)
      return 'Wait for the active run to settle.';
    if (client.run.restoredRunId && !client.run.current)
      return 'The retained run must be restored or confirmed missing first.';
    if (client.connection.lifecycle !== 'ready') return 'Start requires a validated server.hello.';
    if (client.connection.pendingStart) return 'Start is waiting for a direct server response.';
    return hasConversationHistory
      ? 'Ready to continue; bounded completed history is included when it fits the command frame.'
      : current?.terminal
        ? 'No complete successful pair is available, so this starts without prior conversation context.'
        : 'Ready for an explicit protocol-v1 start command.';
  }

  function cancelReason(): string {
    if (!client) return 'Client controls are initializing.';
    if (client.connection.pendingCancel)
      return 'Cancellation is waiting for a direct server response.';
    if (current?.cancelAcknowledged)
      return 'Cancellation is acknowledged; waiting for terminal settlement.';
    if (client.connection.lifecycle !== 'ready') return 'Reconnect before requesting cancellation.';
    if (!client.canCancelRun) return 'Cancellation is not available for this run state.';
    return 'Cancellation requests intent only; the terminal message confirms settlement.';
  }

  function budgetDescription(field: keyof Budget): string {
    const limits =
      field === 'max_output_bytes'
        ? { min: BUDGET_LIMITS.max_output_bytes.min, max: serverMaxOutputBytes }
        : BUDGET_LIMITS[field];
    const suffix = field.endsWith('_ms') ? ' ms' : '';
    return `${limits.min.toLocaleString()}-${limits.max.toLocaleString()}${suffix}`;
  }

  function clearComposerError(field: ComposerError['field']): void {
    if (composerError?.field === field) composerError = null;
  }

  async function focusComposerError(field: ComposerError['field']): Promise<void> {
    await tick();
    const id =
      field === 'cwd'
        ? 'workspace'
        : field === 'prompt' || field === 'model'
          ? field
          : `budget-${field}`;
    document.getElementById(id)?.focus();
  }

  function composerFieldLabel(field: ComposerError['field']): string {
    if (field === 'cwd') return 'Workspace path';
    if (field === 'prompt') return 'Prompt';
    if (field === 'model') return 'Model';
    return budgetLabels[field];
  }

  function serverErrorHeading(category: string): string {
    return (
      {
        retryable: 'Admission can be retried.',
        protocol: 'Protocol command rejected.',
        run_state: 'Run state unavailable.',
        internal: 'Local API failure.',
      }[category] ?? 'Server response.'
    );
  }

  async function copyRunId(): Promise<void> {
    if (!current) return;
    try {
      await navigator.clipboard.writeText(current.runId);
      runIdCopyNotice = 'Run ID copied.';
    } catch {
      runIdCopyNotice = 'Run ID could not be copied.';
    }
  }

  function runStatusLabel(status: RunStatus | undefined): string {
    if (!status) return client?.run.restoredRunId ? 'Restoring' : 'No run';
    return {
      starting: 'Starting',
      running: 'Running',
      cancel_requested: 'Cancellation requested',
      owner_lost: 'Run owner lost',
      completed: 'Completed',
      failed: 'Failed',
      interrupted: 'Interrupted',
    }[status];
  }

  function syncLabel(): string {
    const state = client?.run.syncState;
    if (!state) return 'Idle';
    return {
      idle: 'Idle',
      live: 'Live / contiguous',
      detached: 'Detached / view retained',
      awaiting_replay: 'Awaiting replay acknowledgement',
      awaiting_snapshot: 'Awaiting authoritative snapshot',
      catching_up: 'Applying retained replay',
      recovering: 'Recovering from sequence fault',
      terminal: 'Terminal state installed',
      not_found: 'Run no longer retained',
      protocol_fault: 'Run synchronization fault',
    }[state];
  }

  function currentRun(value: ClientControllers | null): RunState | null {
    if (!value) return null;
    return value.run.current as RunState | null;
  }
</script>

<svelte:head>
  <meta name="color-scheme" content="light" />
</svelte:head>

<a class="skip-link" href="#main-content">Skip to operator console</a>

<div class="console-shell">
  <header class="masthead">
    <div class="identity">
      <span class="identity-mark" aria-hidden="true">S</span>
      <div>
        <p class="wordmark">Synapse</p>
        <p class="product-label">Local operator console</p>
      </div>
    </div>

    <div class="connection-summary">
      <span
        class:ready={client?.connection.lifecycle === 'ready'}
        class:fault={client?.connection.lifecycle === 'protocol_fault'}
        class="status-light"
        aria-hidden="true"
      ></span>
      <div class="connection-copy" aria-live="polite">
        <span class="connection-state">{connectionLabel(client?.connection.lifecycle)}</span>
        {#if client?.connection.hello}
          <span class="hello-detail">
            Protocol {client.connection.hello.payload.protocol} / replay {client.connection.hello
              .payload.replay}
          </span>
        {:else}
          <span class="hello-detail">Start separately with <code>mix synapse.server</code></span>
        {/if}
      </div>
      <form class="connection-form" aria-label="API connection" onsubmit={connect}>
        <div class="connection-url-field">
          <label for="api-url">API socket</label>
          <input
            id="api-url"
            name="api-url"
            type="url"
            bind:value={apiUrl}
            spellcheck="false"
            autocomplete="off"
            aria-describedby="api-url-help"
            aria-invalid={client?.connection.notice?.code === 'invalid_url'}
          />
          <small id="api-url-help">Loopback host, explicit port, protocol-v1 path</small>
        </div>
        <div class="connection-actions">
          <button
            type="submit"
            disabled={!client?.connection.canConnect || client.connection.pendingStart}
          >
            Connect
          </button>
          <button
            type="button"
            onclick={reconnect}
            disabled={!client?.connection.canReconnect ||
              client.connection.lifecycle === 'idle' ||
              client.connection.pendingStart}
          >
            Reconnect
          </button>
          <button
            type="button"
            onclick={disconnect}
            disabled={!client ||
              ['idle', 'unavailable', 'protocol_fault', 'manually_disconnected'].includes(
                client.connection.lifecycle,
              ) ||
              client.connection.pendingStart}
          >
            Disconnect
          </button>
        </div>
      </form>
    </div>
  </header>

  <aside class="trust-notice" aria-labelledby="trust-heading">
    <span class="notice-index" aria-hidden="true">LOCAL / 01</span>
    <div>
      <h2 id="trust-heading">Same-user authority boundary</h2>
      <p>
        The API is loopback-only, not sandboxed. A connected run may read, write, and execute
        processes under the separately started server's trusted policy.
      </p>
    </div>
  </aside>

  <div class="status-stack" aria-live="polite" aria-atomic="true">
    {#if client?.connection.notice}
      <p class="status-notice failure">
        <strong>Connection.</strong>
        {client.connection.notice.message}
      </p>
    {/if}
    {#if client?.connection.startAmbiguous}
      <p class="status-notice caution">
        <strong>Start outcome unknown.</strong> This client will not automatically resend the task.
      </p>
    {/if}
    {#if client?.run.notice}
      <p class="status-notice caution">
        <strong>Run synchronization.</strong>
        {client.run.notice.message}
      </p>
    {/if}
    {#if client?.errors.notice}
      <p class:retryable={client.errors.notice.retryable} class="status-notice">
        <strong>{serverErrorHeading(client.errors.notice.category)}</strong>
        {client.errors.notice.guidance}
      </p>
    {/if}
    {#if composerError}
      <p class="status-notice failure">
        <strong>Check {composerFieldLabel(composerError.field)}.</strong>
        {composerError.message}
      </p>
    {/if}
    {#if actionNotice}
      <p class="status-notice info">{actionNotice}</p>
    {/if}
  </div>

  <main id="main-content">
    <div class="workbench">
      <section class="panel setup-panel" aria-labelledby="setup-heading">
        <div class="panel-heading">
          <span class="section-number" aria-hidden="true">01</span>
          <div>
            <p class="eyebrow">Configure</p>
            <h1 id="setup-heading">Run setup</h1>
          </div>
          <span class="phase-tag">Interactive</span>
        </div>

        <form class="run-composer" aria-labelledby="setup-heading" onsubmit={start} novalidate>
          <div class="field-group">
            <label for="workspace">Workspace path <span>Required</span></label>
            <p id="workspace-help">
              Prefilled from the server launch folder; enter another absolute POSIX path to override
              it.
            </p>
            <input
              id="workspace"
              name="workspace"
              type="text"
              bind:value={cwd}
              oninput={handleWorkspaceInput}
              placeholder="/Users/you/Projects/example"
              aria-describedby={composerError?.field === 'cwd'
                ? 'workspace-help composer-error'
                : 'workspace-help'}
              aria-invalid={composerError?.field === 'cwd'}
              autocomplete="off"
              spellcheck="false"
              required
              aria-required="true"
              disabled={client?.connection.pendingStart}
            />
          </div>

          <div class="field-group">
            <label for="model">Model <span>Optional</span></label>
            <p id="model-help">Blank uses the server default; allowlist remains server-owned.</p>
            <input
              id="model"
              name="model"
              type="text"
              bind:value={model}
              oninput={() => clearComposerError('model')}
              placeholder="Use server default"
              aria-describedby={composerError?.field === 'model'
                ? 'model-help composer-error'
                : 'model-help'}
              aria-invalid={composerError?.field === 'model'}
              autocomplete="off"
              spellcheck="false"
              disabled={client?.connection.pendingStart}
            />
          </div>

          <div class="field-group prompt-group">
            <label for="prompt">Prompt <span>Required</span></label>
            <p id="prompt-help">Sent once to the local server; work begins only after admission.</p>
            <textarea
              id="prompt"
              name="prompt"
              rows="8"
              bind:value={prompt}
              oninput={() => clearComposerError('prompt')}
              placeholder="Describe the task and the evidence you expect..."
              aria-describedby={composerError?.field === 'prompt'
                ? 'prompt-help composer-error'
                : 'prompt-help'}
              aria-invalid={composerError?.field === 'prompt'}
              required
              aria-required="true"
              disabled={client?.connection.pendingStart}></textarea>
          </div>

          <details class="budget-disclosure">
            <summary>Advanced budget limits</summary>
            <p>Optional protocol ceilings. The server may enforce lower configured values.</p>
            <div class="budget-grid">
              {#each BUDGET_FIELDS as field (field)}
                <div class="budget-field">
                  <label for={`budget-${field}`}>{budgetLabels[field]}</label>
                  <input
                    id={`budget-${field}`}
                    name={field}
                    type="text"
                    inputmode="numeric"
                    bind:value={budget[field]}
                    oninput={() => clearComposerError(field)}
                    placeholder="Server default"
                    aria-describedby={`budget-${field}-help${composerError?.field === field ? ' composer-error' : ''}`}
                    aria-invalid={composerError?.field === field}
                    autocomplete="off"
                    disabled={client?.connection.pendingStart}
                  />
                  <small id={`budget-${field}-help`}>{budgetDescription(field)}</small>
                </div>
              {/each}
            </div>
          </details>

          {#if composerError}<span id="composer-error" class="visually-hidden"
              >{composerError.message}</span
            >{/if}

          <div class="form-actions">
            <p id="start-reason">{startReason()}</p>
            <button
              class="primary-action"
              type="submit"
              disabled={!client?.canStartRun}
              aria-describedby="start-reason"
            >
              {client?.connection.pendingStart
                ? 'Starting...'
                : current?.terminal && hasConversationHistory
                  ? 'Continue session'
                  : 'Start run'}
            </button>
          </div>
        </form>
      </section>

      <section class="panel run-panel chat-panel" aria-labelledby="run-heading">
        <div class="panel-heading run-heading">
          <span class="section-number" aria-hidden="true">02</span>
          <div>
            <p class="eyebrow">Conversation</p>
            <h2 id="run-heading" bind:this={runHeading} tabindex="-1">Current run</h2>
          </div>
          <div class="run-indicators">
            <span class="run-state" aria-live={current?.terminal ? 'off' : 'polite'}>
              {runStatusLabel(current?.projection.status)}
            </span>
            {#if current?.historyReset}<span class="sync-badge reset">History reset</span>{/if}
          </div>
        </div>

        <div class="chat-toolbar">
          <span>{runs.length} run{runs.length === 1 ? '' : 's'} in memory</span>
          <span class="run-sync-state" aria-live={current?.terminal ? 'off' : 'polite'}
            >{syncLabel()}</span
          >
          <code>{current?.runId ?? 'Not assigned'}</code>
          {#if current}
            <button class="copy-id-action" type="button" onclick={copyRunId}>Copy run ID</button>
            {#if runIdCopyNotice}<span class="copy-notice" aria-live="polite"
                >{runIdCopyNotice}</span
              >{/if}
          {/if}
          {#if client?.canClearRun}
            <button class="secondary-action" type="button" onclick={clearRun}>New run</button>
          {/if}
        </div>

        <dl class="run-metadata compact">
          <div>
            <dt>Run ID</dt>
            <dd>{current?.runId ?? 'Not assigned'}</dd>
          </div>
          <div>
            <dt>Model</dt>
            <dd>{current?.projection.model ?? 'Awaiting admission'}</dd>
          </div>
          <div>
            <dt>Turn</dt>
            <dd>{current?.projection.turn ?? '--'}</dd>
          </div>
          <div>
            <dt>Sequence</dt>
            <dd>{current?.lastAppliedSeq ?? '--'}</dd>
          </div>
          <div>
            <dt>Provider attempts</dt>
            <dd>{current?.projection.providerAttempts ?? '--'}</dd>
          </div>
          <div>
            <dt>Tool calls</dt>
            <dd>{current?.projection.toolCalls ?? '--'}</dd>
          </div>
          <div>
            <dt>Output bytes</dt>
            <dd>{current?.projection.outputBytes ?? '--'}</dd>
          </div>
        </dl>

        {#if current && !current.terminal}
          <div class="run-actions" aria-label="Run actions">
            <button
              class="cancel-action"
              type="button"
              onclick={cancel}
              disabled={!client?.canCancelRun}
              aria-describedby="cancel-reason"
            >
              {client?.connection.pendingCancel
                ? 'Requesting cancellation...'
                : current.cancelAcknowledged
                  ? 'Cancellation requested'
                  : 'Cancel run'}
            </button>
            <p id="cancel-reason">{cancelReason()}</p>
          </div>
        {/if}

        <ChatTimeline {runs} error={client?.errors.notice ?? null} />
      </section>
    </div>

    <section class="activity-panel" aria-labelledby="activity-heading">
      <div class="activity-heading-row">
        <div>
          <p class="eyebrow">Bounded event view</p>
          <h2 id="activity-heading">Activity</h2>
        </div>
        {#if client}<ProtocolInspector timeline={client.protocol} />{/if}
      </div>

      <p class="activity-summary">
        Every visible conversation item exposes its exact retained command, event, or terminal
        payload through an API trace disclosure.
      </p>
    </section>
  </main>

  <footer>
    <span>Run presentation / Phase 6</span>
    <span>Synapse server remains an independent process</span>
  </footer>
</div>
