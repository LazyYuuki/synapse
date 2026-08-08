import { expect, test as base } from '@playwright/test';

import { RealSynapseServer, startRealSynapseServer } from './real-synapse-server.js';

export const test = base.extend<{ synapseApi: RealSynapseServer }>({
  // eslint-disable-next-line no-empty-pattern
  synapseApi: async ({}, use) => {
    const server = await startRealSynapseServer();
    try {
      await use(server);
      server.assertHealthy();
    } finally {
      await server.stop();
      server.assertHealthy();
    }
  },
});

export { expect };
