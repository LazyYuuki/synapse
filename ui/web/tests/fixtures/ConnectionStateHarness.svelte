<script lang="ts">
  import type { ConnectionController } from '../../src/lib/client/connection.svelte';

  let { controller }: { controller: ConnectionController } = $props();
</script>

<output data-testid="can-start">{controller.canStart ? 'enabled' : 'disabled'}</output>
<output data-testid="pending-count">{controller.pendingCount}</output>
