import { expect, test as base } from '@playwright/test';

import {
  startScriptedWebSocketServer,
  type ScriptedWebSocketServer,
} from './scripted-websocket-server.js';

export const test = base.extend<{ socketServer: ScriptedWebSocketServer }>({
  socketServer: async ({ baseURL }, use) => {
    if (!baseURL) throw new Error('Playwright baseURL is required');
    const server = await startScriptedWebSocketServer(new URL(baseURL).origin);
    try {
      await use(server);
      server.assertHealthy();
    } finally {
      await server.stop();
    }
  },
});

export { expect };
