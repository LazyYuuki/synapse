<script lang="ts">
  import { tick } from 'svelte';

  let { text, runId }: { text: string; runId: string | null } = $props();
  let viewport: HTMLDivElement;
  let following = $state(true);
  let observedRunId = $state<string | null>(null);
  let initializedRun = false;
  const bottomThreshold = 48;

  $effect.pre(() => {
    void text;
    if (!viewport) return;
    if (!initializedRun) {
      observedRunId = runId;
      initializedRun = true;
    } else if (runId !== observedRunId) {
      observedRunId = runId;
      following = true;
    }
    const shouldFollow = following || nearBottom();
    const retainedTop = viewport.scrollTop;
    void tick().then(() => {
      if (!viewport) return;
      if (shouldFollow) {
        viewport.scrollTop = viewport.scrollHeight;
        following = true;
      } else {
        viewport.scrollTop = Math.min(
          retainedTop,
          Math.max(0, viewport.scrollHeight - viewport.clientHeight),
        );
      }
    });
  });

  function handleScroll(): void {
    following = nearBottom();
  }

  function jumpToLatest(): void {
    viewport.scrollTop = viewport.scrollHeight;
    following = true;
  }

  function handleKeydown(event: KeyboardEvent): void {
    const page = Math.max(40, viewport.clientHeight * 0.8);
    if (event.key === 'PageDown') viewport.scrollTop += page;
    else if (event.key === 'PageUp') viewport.scrollTop -= page;
    else if (event.key === 'Home') viewport.scrollTop = 0;
    else if (event.key === 'End') jumpToLatest();
    else return;
    event.preventDefault();
    handleScroll();
  }

  function nearBottom(): boolean {
    return viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop <= bottomThreshold;
  }
</script>

<div class="assistant-output-shell">
  <div
    class="assistant-output"
    class:empty={!text}
    bind:this={viewport}
    onscroll={handleScroll}
    onkeydown={handleKeydown}
    tabindex="0"
    role="textbox"
    aria-readonly="true"
    aria-multiline="true"
    aria-label="Assistant output"
    data-following={following}
  >
    {#if text}
      <pre class="assistant-text">{text}</pre>
    {:else}
      <div class="output-empty">
        <span class="empty-glyph" aria-hidden="true">_</span>
        <p>No assistant output has arrived.</p>
        <small>Plain text only. No Markdown, hidden reasoning, or Tool arguments.</small>
      </div>
    {/if}
  </div>
  {#if !following && text}
    <button class="jump-latest" type="button" onclick={jumpToLatest}>Jump to latest</button>
  {/if}
</div>
