<script lang="ts">
  import type { RunState } from '../client/run-types';
  import type { ServerErrorNotice } from '../client/server-errors.svelte';

  type ChatItem = {
    id: string;
    kind: 'user' | 'thinking' | 'tool-call' | 'tool-result' | 'assistant' | 'status' | 'error';
    label: string;
    body: string;
    trace: unknown;
    heading?: string;
    announcement?: string;
    terminal?: boolean;
    activeTool?: boolean;
    collapsible?: boolean;
  };

  let { runs, error = null }: { runs: RunState[]; error?: ServerErrorNotice | null } = $props();
  let items = $derived(projectChat(runs, error));
  let active = $derived(runs.at(-1) ?? null);

  function projectChat(states: RunState[], serverError: ServerErrorNotice | null): ChatItem[] {
    const projected: ChatItem[] = [];
    for (const state of states) {
      if (state.start) {
        projected.push({
          id: `${state.runId}-user`,
          kind: 'user',
          label: 'You',
          body: state.start.payload.prompt,
          trace: state.start,
        });
      } else {
        projected.push({
          id: `${state.runId}-restored`,
          kind: 'status',
          label: 'Restored run',
          body: 'The original start command is not available in this browser session.',
          trace: { run_id: state.runId, trace_incomplete: true },
          collapsible: true,
        });
      }

      if (state.traceIncomplete) {
        projected.push({
          id: `${state.runId}-trace-gap`,
          kind: 'status',
          label: 'Trace boundary',
          body: 'Earlier live events are unavailable; the authoritative run projection is retained.',
          trace: { run_id: state.runId, last_applied_seq: state.lastAppliedSeq },
          collapsible: true,
        });
      }

      let text = '';
      let completeText = state.traceBaseText;
      let textEvents: RunState['events'] = [];
      if (state.traceBaseText !== '') {
        projected.push({
          id: `${state.runId}-trace-base-text`,
          kind: 'assistant',
          label: 'Synapse / prior output',
          body: state.traceBaseText,
          trace: { run_id: state.runId, source: 'bounded projection preceding retained events' },
        });
      }
      const flushText = () => {
        if (text === '') return;
        const first = textEvents[0]?.seq ?? 0;
        projected.push({
          id: `${state.runId}-text-${first}`,
          kind: 'assistant',
          label: 'Synapse',
          body: text,
          trace: textEvents.map(({ seq, event }) => ({
            version: 1,
            type: 'run.event',
            request_id: null,
            payload: { run_id: state.runId, seq, event },
          })),
        });
        completeText += text;
        text = '';
        textEvents = [];
      };

      for (const applied of state.events) {
        const event = applied.event;
        if (event.type === 'text.delta') {
          text += event.delta;
          textEvents.push(applied);
          continue;
        }
        flushText();
        const trace = {
          version: 1,
          type: 'run.event',
          request_id: null,
          payload: { run_id: state.runId, seq: applied.seq, event },
        };
        if (event.type === 'turn.started') {
          projected.push({
            id: `${state.runId}-${applied.seq}`,
            kind: 'thinking',
            label: `Provider / turn ${event.turn}`,
            body: 'Provider processing started. Hidden reasoning is not exposed.',
            trace,
            collapsible: true,
          });
        } else if (event.type === 'tool.started') {
          projected.push({
            id: `${state.runId}-${applied.seq}`,
            kind: 'tool-call',
            label: `Tool call / ${event.name}`,
            body: `Active\n${pretty(event.arguments)}`,
            trace,
            activeTool: state.projection.activeTool?.call_id === event.call_id,
            collapsible: true,
          });
        } else if (event.type === 'tool.completed') {
          projected.push({
            id: `${state.runId}-${applied.seq}`,
            kind: event.status === 'ok' ? 'tool-result' : 'error',
            label: `Tool result / ${event.name} / ${event.status}`,
            body: event.content,
            trace,
            collapsible: true,
          });
        } else if (event.type === 'turn.completed') {
          projected.push({
            id: `${state.runId}-${applied.seq}`,
            kind:
              event.outcome === 'failed' || event.outcome === 'interrupted' ? 'error' : 'status',
            label: `Provider / turn ${event.turn}`,
            body: `Turn ${event.outcome}. ${event.provider_attempts} provider attempt(s), ${event.tool_calls} Tool call(s).`,
            trace,
            collapsible: true,
          });
        }
      }
      flushText();

      if (state.events.length === 0 && state.traceBaseText === '' && state.projection.text !== '') {
        projected.push({
          id: `${state.runId}-snapshot-text`,
          kind: 'assistant',
          label: 'Synapse',
          body: state.projection.text,
          trace: { run_id: state.runId, source: 'authoritative snapshot projection' },
        });
        completeText = state.projection.text;
      }

      if (state.terminal) {
        const terminal = state.terminal;
        if (terminal.status === 'completed' && terminal.result.text !== completeText) {
          projected.push({
            id: `${state.runId}-terminal-answer`,
            kind: 'assistant',
            label: 'Synapse / final answer',
            body: terminal.result.text,
            trace: { version: 1, type: 'run.terminal', request_id: null, payload: terminal },
          });
        }
        projected.push({
          id: `${state.runId}-terminal`,
          kind: terminal.status === 'completed' ? 'status' : 'error',
          label: `Run ${terminal.status}`,
          body:
            terminal.status === 'completed'
              ? `${terminal.result.turns} turn(s), ${terminal.result.tool_calls} Tool call(s), ${terminal.result.provider_retries} Provider retries, ${terminal.result.output_bytes.toLocaleString()} output bytes; cleanup and terminal settlement were confirmed.`
              : terminal.error.source === 'runtime' && terminal.error.reason === 'runtime_lost'
                ? `${terminal.error.source}: ${terminal.error.message}. Final cleanup settlement was not observed.`
                : `${terminal.error.source}: ${terminal.error.message}`,
          trace: { version: 1, type: 'run.terminal', request_id: null, payload: terminal },
          heading:
            terminal.status === 'completed'
              ? 'Completed'
              : terminal.error.source === 'agent' && terminal.error.kind === 'cancelled'
                ? 'Cancelled'
                : terminal.error.reason === 'runtime_lost'
                  ? 'Runtime lost'
                  : `Run ${terminal.status}`,
          announcement:
            terminal.status === 'completed'
              ? 'Run completed. Terminal settlement confirmed.'
              : terminal.error.source === 'runtime' && terminal.error.reason === 'runtime_lost'
                ? 'Run interrupted: Runtime lost. Final cleanup settlement was not observed.'
                : `Run ${terminal.status}: ${terminal.error.message}`,
          terminal: true,
        });
      }
    }
    if (serverError) {
      projected.push({
        id: `server-error-${serverError.trace.request_id ?? serverError.code}`,
        kind: 'error',
        label: `Server error / ${serverError.code}`,
        body: serverError.guidance,
        trace: serverError.trace,
        heading: 'Command rejected',
        announcement: serverError.guidance,
      });
    }
    return projected;
  }

  function providerStatus(state: RunState | null): string {
    if (!state) return 'Ready for a new conversation';
    if (state.terminal) return `Provider ${state.terminal.status}`;
    if (state.projection.activeTool) return `Tool running / ${state.projection.activeTool.name}`;
    if (state.projection.status === 'starting') return 'Waiting for Provider';
    if (state.projection.status === 'cancel_requested') return 'Cancellation requested';
    if (state.projection.status === 'owner_lost') return 'Provider owner lost';
    return `Provider active / turn ${state.projection.turn || 1}`;
  }

  function pretty(value: unknown): string {
    return JSON.stringify(value, null, 2);
  }
</script>

<div class="chat-viewport">
  <div
    class="provider-buffer"
    class:active={active !== null && active.terminal === null}
    aria-live="polite"
  >
    <span class="provider-pulse" aria-hidden="true"></span>
    <strong>{providerStatus(active)}</strong>
    {#if active}
      <span>run {active.runId.slice(0, 12)} / seq {active.lastAppliedSeq}</span>
    {/if}
  </div>

  <div class="chat-timeline" role="region" aria-label="Conversation">
    {#if items.length === 0}
      <div class="chat-empty">
        <p class="eyebrow">One session, many runs</p>
        <h2>Start with a task.</h2>
        <p>Settled answers become bounded context for your next message.</p>
        <a class="chat-empty-action" href="#prompt">Write a prompt</a>
      </div>
    {:else}
      {#each items as item (item.id)}
        {#if item.collapsible}
          <details
            class={`chat-bubble collapsible-bubble ${item.kind}`}
            open={item.activeTool ?? false}
            role={item.activeTool ? 'region' : undefined}
            aria-label={item.activeTool ? 'Active Tool' : undefined}
          >
            <summary class="bubble-summary">
              <span>{item.label}</span>
              <span class="bubble-kind">{item.kind.replace('-', ' ')}</span>
            </summary>
            <pre class="bubble-body">{item.body}</pre>
            <details class="trace-disclosure">
              <summary>API trace</summary>
              <p>Exact validated data retained by this browser for this bubble.</p>
              <pre>{pretty(item.trace)}</pre>
            </details>
          </details>
        {:else}
          <article
            class={`chat-bubble ${item.kind}${item.terminal ? ' terminal-card' : ''}`}
            role={item.terminal ? 'region' : undefined}
            aria-label={item.heading}
          >
            <header>
              <span>{item.label}</span>
              <span class="bubble-kind">{item.kind.replace('-', ' ')}</span>
            </header>
            {#if item.heading}<h3>{item.heading}</h3>{/if}
            {#if item.announcement}
              <p role={item.kind === 'error' ? 'alert' : 'status'}>{item.announcement}</p>
            {/if}
            {#if item.kind === 'assistant'}
              <div
                class="bubble-body assistant-text"
                role="textbox"
                aria-label="Assistant output"
                aria-readonly="true"
                aria-multiline="true"
                tabindex="0"
              >
                {item.body}
              </div>
            {:else}
              <pre class="bubble-body">{item.body}</pre>
            {/if}
            <details class="trace-disclosure">
              <summary>API trace</summary>
              <p>Exact validated data retained by this browser for this bubble.</p>
              <pre>{pretty(item.trace)}</pre>
            </details>
          </article>
        {/if}
      {/each}
    {/if}
  </div>
</div>
