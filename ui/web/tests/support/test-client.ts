import { createClientControllers } from '../../src/lib/client/client.svelte';
import {
  createConnectionController,
  type ConnectionDependencies,
} from '../../src/lib/client/connection.svelte';
import { FakeSocketFactory, MemorySessionStorage } from './fake-socket';

export function createTestClient() {
  const factory = new FakeSocketFactory();
  const storage = new MemorySessionStorage();
  let requestId = 0;
  const timers = new Set<object>();
  const setTimeout = () => {
    const timer = { timer: Symbol('timer') };
    timers.add(timer);
    return timer;
  };
  const clearTimeout = (handle: unknown) => {
    if (typeof handle === 'object' && handle !== null) timers.delete(handle);
  };
  const dependencies: ConnectionDependencies = {
    createSocket: factory.create,
    storage,
    setTimeout,
    clearTimeout,
    now: () => 1_000,
    randomUUID: () => `request-${++requestId}`,
  };
  const client = createClientControllers({
    createConnection: (callbacks) => createConnectionController(dependencies, callbacks),
    run: { storage, setTimeout, clearTimeout },
  });
  return { client, factory, storage, timers };
}
