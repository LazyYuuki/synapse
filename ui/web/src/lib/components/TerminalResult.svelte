<script lang="ts">
  import type { RunProjectionView } from '../client/run-types';
  import type { JsonValue, Terminal } from '../protocol/types';

  let {
    terminal,
    projection,
  }: {
    terminal: Terminal;
    projection: RunProjectionView;
  } = $props();

  function headingText(value: Terminal): string {
    if (value.status === 'completed') return 'Completed';
    if (value.error.source === 'runtime') {
      if (value.error.reason === 'runtime_lost') return 'Runtime lost';
      if (value.error.reason === 'runtime_unavailable') return 'Runtime unavailable';
      if (value.error.reason === 'runtime_busy') return 'Runtime busy';
      if (value.error.reason === 'workspace_open_failed') return 'Workspace open failed';
      return 'Runtime failure';
    }
    if (value.error.source === 'api') return 'API settlement failure';
    if (value.error.kind === 'cancelled') return 'Cancelled';
    return `${capitalize(value.error.kind)} ${value.status === 'failed' ? 'failure' : 'interruption'}`;
  }

  function formatDetail(value: JsonValue): string {
    return typeof value === 'string' ? value : JSON.stringify(value);
  }

  function capitalize(value: string): string {
    return value.charAt(0).toUpperCase() + value.slice(1);
  }
</script>

<section
  class:success={terminal.status === 'completed'}
  class="terminal-card"
  aria-labelledby="terminal-result-heading"
>
  <div class="terminal-heading-row">
    <div>
      <p class="eyebrow">Terminal / sequence {terminal.seq}</p>
      <h3 id="terminal-result-heading">{headingText(terminal)}</h3>
    </div>
    <span class="terminal-status">{terminal.status}</span>
  </div>

  {#if terminal.status === 'completed'}
    <p class="terminal-message">Result text is shown in the assistant output above.</p>
    <dl class="terminal-metrics">
      <div>
        <dt>Turns</dt>
        <dd>{terminal.result.turns}</dd>
      </div>
      <div>
        <dt>Tool calls</dt>
        <dd>{terminal.result.tool_calls}</dd>
      </div>
      <div>
        <dt>Provider retries</dt>
        <dd>{terminal.result.provider_retries}</dd>
      </div>
      <div>
        <dt>Output bytes</dt>
        <dd>{terminal.result.output_bytes}</dd>
      </div>
    </dl>
    <p class="settlement-note">Run cleanup and terminal settlement were confirmed.</p>
  {:else}
    <dl class="terminal-details">
      <div>
        <dt>Source</dt>
        <dd>{terminal.error.source}</dd>
      </div>
      <div>
        <dt>Reason</dt>
        <dd><code>{terminal.error.reason}</code></dd>
      </div>
      {#if terminal.error.source === 'agent'}
        <div>
          <dt>Kind</dt>
          <dd>{terminal.error.kind}</dd>
        </div>
        <div>
          <dt>Turn</dt>
          <dd>{terminal.error.turn}</dd>
        </div>
        {#if terminal.error.operation_id}
          <div>
            <dt>Operation</dt>
            <dd><code>{terminal.error.operation_id}</code></dd>
          </div>
        {/if}
      {/if}
    </dl>
    <p class="terminal-message">{terminal.error.message}</p>
    {#if terminal.error.source === 'agent' && Object.keys(terminal.error.details).length > 0}
      <details class="terminal-detail-disclosure">
        <summary>Validated error details</summary>
        <dl>
          {#each Object.entries(terminal.error.details) as [key, value] (key)}
            <div>
              <dt>{key}</dt>
              <dd>{formatDetail(value)}</dd>
            </div>
          {/each}
        </dl>
      </details>
    {/if}
    <dl class="terminal-metrics progress-metrics">
      <div>
        <dt>Committed attempts</dt>
        <dd>{projection.providerAttempts}</dd>
      </div>
      <div>
        <dt>Committed Tool calls</dt>
        <dd>{projection.toolCalls}</dd>
      </div>
      <div>
        <dt>Committed output bytes</dt>
        <dd>{projection.outputBytes}</dd>
      </div>
      <div>
        <dt>Last turn</dt>
        <dd>{projection.turn}</dd>
      </div>
    </dl>
    {#if terminal.error.source === 'runtime' && terminal.error.reason === 'runtime_lost'}
      <p class="settlement-note caution">
        This interrupted terminal is authoritative, but final cleanup settlement was not observed.
      </p>
    {:else}
      <p class="settlement-note">Run cleanup and terminal settlement were confirmed.</p>
    {/if}
  {/if}
</section>
