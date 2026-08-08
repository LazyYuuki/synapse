<script lang="ts">
  import type { RunController } from '../../src/lib/client/run.svelte';

  let { controller }: { controller: RunController } = $props();
</script>

<output data-testid="run-state">
  {controller.syncState}:{controller.current?.projection.status ?? 'none'}:{controller.current
    ?.lastAppliedSeq ?? '-'}
</output>
