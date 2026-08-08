<script lang="ts">
  import type { RunActivityEntry, RunState } from '../client/run-types';

  let { state }: { state: RunState | null } = $props();
  let entries = $derived((state?.activity ?? []).filter((entry) => entry.type !== 'text.delta'));

  function activityLabel(entry: RunActivityEntry): string {
    return {
      'run.started': 'Run started',
      'turn.started': 'Turn started',
      'text.delta': 'Assistant text',
      'tool.started': 'Tool started',
      'tool.completed': 'Tool completed',
      'turn.completed': 'Turn completed',
      'run.owner_lost': 'Run owner lost',
    }[entry.type];
  }
</script>

{#if state?.projection.activeTool}
  <section class="active-tool-card" aria-label="Active Tool">
    <div>
      <span class="tool-label">Active Tool</span>
      <strong>{state.projection.activeTool.name}</strong>
    </div>
    <dl>
      <div>
        <dt>Status</dt>
        <dd>Active</dd>
      </div>
      <div>
        <dt>Turn</dt>
        <dd>{state.projection.activeTool.turn}</dd>
      </div>
      <div>
        <dt>Ordinal</dt>
        <dd>{state.projection.activeTool.ordinal}</dd>
      </div>
    </dl>
    <p>Protocol v1 exposes no Tool arguments or command output.</p>
  </section>
{/if}

<ol class="activity-list run-activity-list">
  {#if entries.length === 0}
    <li class="muted-event">
      <span class="activity-seq">--</span>
      <span class="timeline-mark" aria-hidden="true"></span>
      <div>
        <strong>No retained activity</strong>
        <p>Snapshots cannot reconstruct omitted event history.</p>
      </div>
    </li>
  {:else}
    {#each entries as entry (entry.seq)}
      <li>
        <span class="activity-seq">#{entry.seq}</span>
        <span class="timeline-mark" aria-hidden="true"></span>
        <div>
          <strong>{activityLabel(entry)}</strong>
          {#if entry.type === 'run.started'}
            <p>Configured model: <code>{entry.model}</code></p>
          {:else if entry.type === 'turn.started'}
            <p>Turn {entry.turn}</p>
          {:else if entry.type === 'tool.started'}
            <p><code>{entry.name}</code> / turn {entry.turn} / ordinal {entry.ordinal} / active</p>
          {:else if entry.type === 'tool.completed'}
            <p>
              <code>{entry.name}</code> / turn {entry.turn} / ordinal {entry.ordinal} / status
              <strong>{entry.status}</strong>
              {#if entry.metadata.outcome}
                / outcome {entry.metadata.outcome}{/if}
            </p>
          {:else if entry.type === 'turn.completed'}
            <p>Turn {entry.turn} / outcome {entry.outcome}</p>
          {:else if entry.type === 'run.owner_lost'}
            <p>
              {state?.terminal
                ? 'Run ownership was lost before authoritative terminal settlement.'
                : 'Run ownership was lost. Cleanup and settlement remain unproven.'}
            </p>
          {/if}
        </div>
      </li>
    {/each}
  {/if}
</ol>
