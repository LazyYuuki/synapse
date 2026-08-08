<script lang="ts">
  import {
    serializeProtocolEntries,
    type ProtocolTimeline,
  } from '../client/protocol-timeline.svelte';

  let { timeline }: { timeline: ProtocolTimeline } = $props();
  let entries = $derived(timeline.entries);
  let copyNotice = $state<string | null>(null);

  async function copyDiagnostics(): Promise<void> {
    try {
      await navigator.clipboard.writeText(serializeProtocolEntries(entries));
      copyNotice = 'Sanitized diagnostics copied.';
    } catch {
      copyNotice = 'Diagnostics could not be copied.';
    }
  }

  function clearDiagnostics(): void {
    timeline.clear();
    copyNotice = 'Protocol diagnostics cleared from memory.';
  }
</script>

<details class="protocol-disclosure">
  <summary>Protocol inspector</summary>
  <p>{entries.length} bounded sanitized envelopes retained in source order.</p>
  <p class="protocol-warning">
    Copied diagnostics may disclose run IDs, model and Tool names, statuses, operation identifiers,
    and error-detail key names. Review before sharing. Prompt, Workspace path, assistant text,
    error-detail values, and raw frames are omitted.
  </p>
  <div class="protocol-actions">
    <button type="button" onclick={copyDiagnostics} disabled={entries.length === 0}>
      Copy diagnostics
    </button>
    <button type="button" onclick={clearDiagnostics} disabled={entries.length === 0}>
      Clear diagnostics
    </button>
  </div>
  {#if copyNotice}<p class="copy-notice" aria-live="polite">{copyNotice}</p>{/if}
  {#if entries.length}
    <!-- svelte-ignore a11y_no_noninteractive_tabindex (scrollable diagnostics require keyboard access) -->
    <div
      class="protocol-list-viewport"
      role="region"
      tabindex="0"
      aria-label="Validated protocol envelopes"
    >
      <ol class="protocol-list">
        {#each entries as entry (entry.id)}
          <li>
            <div class="protocol-entry-heading">
              <span>#{entry.id} {entry.direction}</span>
              <code>{entry.type}</code>
              <small>{entry.role.replaceAll('_', ' ')}</small>
              <small>{entry.marker}</small>
            </div>
            <!-- svelte-ignore a11y_no_noninteractive_tabindex (scrollable envelopes require keyboard access) -->
            <pre
              role="region"
              tabindex="0"
              aria-label={`Protocol envelope ${entry.id}: ${entry.type}`}>{JSON.stringify(
                entry.display,
                null,
                2,
              )}</pre>
          </li>
        {/each}
      </ol>
    </div>
  {:else}
    <p>No commands or validated server messages retained.</p>
  {/if}
</details>
